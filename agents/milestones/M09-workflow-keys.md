# M09: Workflow Keys

**Status:** Complete (uncommitted, awaiting review)
**Priority:** High
**Effort:** 2 weeks (core 1 week, dashboard 1 week)
**Dependencies:** None

## Motivation

A producer that sends "process article 42" twice gets two runs today, and the
article is processed twice. Producers retry on timeouts, webhooks arrive more
than once, and a user edits the same article in a burst, so duplicates are
normal. The fix today is a check in the caller's own code, which races.

This milestone lets a start carry a key. Durable creates at most one run per
key, and a second start returns the run that already exists:

```elixir
{:ok, run_id} = Durable.start(ProcessArticle, %{"id" => 42}, key: "article:42")

# The producer sends it again: same run, nothing new is created
{:ok, ^run_id} = Durable.start(ProcessArticle, %{"id" => 42}, key: "article:42")

# Or ask for an error instead
{:error, {:key_taken, ^run_id}} =
  Durable.start(ProcessArticle, %{"id" => 42}, key: "article:42", on_duplicate: :error)
```

Operators also need to see this happen: who holds `article:42`, how often the
producer added it again, which newer inputs were dropped, and how to process
an article again on purpose. The dashboard work in this milestone covers that.

The design was reviewed on three pages:

- [Workflow keys review](https://claude.ai/artifact/CQr6TYpL3LrKx78tRYxdTC)
  has the decisions, the API, storage, the start algorithm and edge cases E1–E36.
- [Workflow key strategies](https://claude.ai/artifact/Db1whcuJFBa6vRduqWwu3R)
  compares Oban, Temporal and Inngest case by case.
- [Workflow keys in the dashboard](https://claude.ai/artifact/2zBj3QBYaAmcwQWuEqhqBm)
  has the dashboard concept. Directions A and C were picked.

## Scope

### In Scope

- `key:` and `on_duplicate:` on `Durable.start/3`; `reuse:` and a default
  `on_duplicate:` on the `workflow` macro.
- The key holder model (below): one migration, the start path, retry, rerun
  and pruning.
- `Durable.release_key/2`, so an operator can let a closed holder's key go.
- A guard on the queue adapter's `reschedule`, so it only moves open runs.
- A `:key` filter in `Durable.Query`.
- Key events in `Durable.Activity`, three telemetry events, and a key query in
  `Durable.Stats`.
- Dashboard direction A, on the run: key chip and badge, facts, a banner when
  newer input was dropped, a Key view, Retry and Rerun sentences, Release key,
  `key:` search, ⌘K key lookup, "Release N keys" in the bulk bar.
- Dashboard direction C, on the workflow page: a Keys section.
- `guides/workflow_keys.md`, the `start/3` docs and the roadmap.

### Out of Scope

- `on_duplicate: :cancel_existing` (Temporal TERMINATE_EXISTING, Inngest
  singleton `cancel`) and the dashboard's "Cancel and run this input", which
  needs it. Next milestone.
- `on_duplicate: {:send_event, name}`, the equivalent of Temporal's
  Signal-With-Start, using `Durable.send_event/3`. Next milestone.
- `debounce: [period:, timeout:]`, as in Inngest. Next milestone.
- A Keys page in the dashboard (concept direction B). Keys are scoped per
  workflow, so it would mostly repeat Runs filtered by `key:`.
- A key built from the input in the DSL, keys for child workflows, keyed cron
  fires, and sending events or input to a run by its key.
- A per-call `reuse:`. `start/3` rejects it.

## Architecture & Design

### Decisions

| ID | Question | Decision |
|----|----------|----------|
| D1 | Does pruning free a key? | Yes. Pruning deletes the run and its key, like Temporal's retention period. |
| D2 | What does a duplicate start return? | `{:ok, holder_id}` by default (`on_duplicate: :use_existing`). `on_duplicate: :error` returns `{:error, {:key_taken, holder_id}}`. |
| D3 | A key's scope | One workflow: module and name. Two workflows can use the same key. |
| D4 | Who decides whether a closed run still holds its key? | The next start, as in Temporal. Status is never part of the unique index. |
| D5 | What if the holder is closed? | The same as an open holder: the caller's `on_duplicate` decides. |
| D6 | Names | `key:`, `reuse:` (`:after_close`, `:after_failure`, `:never`), `on_duplicate:` (`:use_existing`, `:error`), `{:key_taken, id}`. `reuse:` is set on the workflow only. |

### Why the holder model

Oban ties uniqueness to job states: a job is unique among jobs in the listed
`states`. A job leaves those states and comes back (executing, retryable,
available), and when it comes back while another job holds the key, Oban Pro's
unique index raises inside Oban's own code. Open-source Oban has no constraint
at all, and its docs say it can race.

Temporal keeps one `current_executions` row per Workflow ID, a primary key
with no status in it, and swaps it only if it still points at the run the
server checked. Durable copies that:

- Every keyed run keeps its `key`. The one run that holds it has
  `holds_key = true`, and the unique index covers only that flag.
- No status change writes `holds_key`. Worker claims, stale-lock recovery, the
  zombie sweep, cancel and compensation can't raise a unique error or free a
  key.
- A key changes hands only when a new start asks for it. One `UPDATE` on the
  holder's own row checks that it's closed, that `reuse:` allows it, and that
  it still holds the key.
- `reuse:` is read from the workflow at start time, so a policy change reaches
  past runs at the next start.

The cost: reusing a closed holder's key takes three statements instead of
one, and a code path that reopened a closed run without checking would run it
without its key. That's why `reschedule` gets a guard.

### Storage

One migration, `V20261106000000AddWorkflowKeys`:

```sql
ALTER TABLE durable.workflow_executions
  ADD COLUMN key text,
  ADD COLUMN holds_key boolean NOT NULL DEFAULT false;

-- one holder per key
CREATE UNIQUE INDEX workflow_executions_key_holder_index
  ON durable.workflow_executions (workflow_module, workflow_name, key)
  WHERE holds_key;

-- every run with the key, for history and the dashboard
CREATE INDEX workflow_executions_key_lookup_index
  ON durable.workflow_executions (key) WHERE key IS NOT NULL;

-- key events per run, for the run page
CREATE INDEX activity_workflow_id_at_index
  ON durable.activity (workflow_id, at) WHERE workflow_id IS NOT NULL;
```

Runs from before the migration have a `NULL` key and `holds_key = false`, so
they never hold one. Creating the indexes scans the table and blocks inserts
while it runs; `CONCURRENTLY` isn't possible inside the migration transaction.
The upgrade notes say so.

### When is a key taken?

| Holder status | `:after_close` (default) | `:after_failure` | `:never` |
|---------------|--------------------------|------------------|----------|
| Open: pending, running, waiting, compensating | taken | taken | taken |
| Completed | free | taken | taken |
| Failed, cancelled, compensated, compensation_failed | free | free | taken |

"Process each article once" is `:after_failure`. "Free" means the next start
may take the key from the closed holder. The reusable statuses per policy are
written once, in the schema module, and start and retry both read them.

### Start

Only keyed starts take this path. It runs in one transaction:

1. Validate the changeset. A key is a string of 1–255 bytes; `nil` means no
   key. An invalid one returns `{:error, changeset}`.
2. Insert with `holds_key = true` through `Repo.insert_all(... on_conflict:
   :nothing, conflict_target: ..., returning: true)`. `Repo.insert` with
   `on_conflict: :nothing` returns `{:ok, run}` even when nothing was inserted
   (Ecto 3.13.5), so it can't be used here.
3. A row came back: it's a new run. Broadcast, run inline if asked, return
   `{:ok, id}`.
4. No row: read the holder. If it's open, answer by `on_duplicate`.
5. If it's closed and `reuse:` allows its status, release it and go back to
   step 2. If not, answer by `on_duplicate` (D5).
6. If there's no holder, or the release matched no row, another start or a
   retry got there first: go back to step 2. After 3 rounds, return
   `{:error, :key_contended}`.

```sql
-- step 5: release only if the holder is still closed and still holds the key
UPDATE durable.workflow_executions SET holds_key = false
WHERE id = $holder AND holds_key AND status = ANY($reusable);
```

The release and a retry both update the holder's own row, and their `WHERE`
clauses read only that row. Postgres locks the row and re-checks the `WHERE`
against its newest version, so whichever commits second matches no row. Two
inserts meet at the unique index: the second waits for the first to commit,
then hits the conflict. A duplicate raises nothing, so a caller who saves an
article and starts its run in one transaction keeps a usable transaction.

A duplicate doesn't broadcast `:workflow_started` and never runs inline.

### Retry, rerun, release and prune

- **Retry** (`reset_for_retry/2`, `reopen_parallel_block/3`): a run that still
  holds its key, or has none, retries as it does today. A run that lost its
  key takes it back by the start rules, releasing a closed holder that
  `reuse:` allows and setting `holds_key = true` in the same `UPDATE` that
  reopens it, or it returns `{:error, {:key_taken, holder_id}}`. A retry
  inside a parallel block rolls back whole.
- **Rerun** (`rerun_workflow/2`) keeps the key and goes through the start
  rules with `on_duplicate: :error`, so the operator sees why it was refused.
- **Release**: `Durable.release_key(workflow_id, opts \\ [])` sets
  `holds_key = false` on a closed holder and records `key_released`. An open
  run returns `{:error, :not_finished}` (cancel it first); a run that doesn't
  hold a key returns `{:error, :no_key}`.
- **Prune** deletes the holder, and the key goes with it (D1). No code needed.
- **Reschedule**: `do_reschedule/4` in the Postgres adapter can set a run in
  any status to `pending`. Nothing in core calls it today. It gets a
  `status IN (open)` guard so a closed run that lost its key can't come back
  without it (E36).

### Tracking: Activity and telemetry

A key's history needs no new storage: every run keeps its `key`, and
`holds_key` marks the holder. Duplicates are the only thing a run row can't
show, so they go to `Durable.Activity`, which already keeps operator events
for a week.

| Kind | Recorded when | `workflow_id` | `details` |
|------|---------------|---------------|-----------|
| `key_duplicate` | A start found a holder and returned it or `{:key_taken, id}` | the holder | `key`, `outcome` (`use_existing` or `error`), `holder_status`, `input_changed`, and `input` when it changed (at most 16 KB, else `input_truncated: true`) |
| `key_handed_off` | A start released a closed holder and took its key | the new run | `key`, `from`, `from_status`, `reuse` |
| `key_released` | `Durable.release_key/2` | the released run | `key`, `by` |
| `key_retaken` | A retry took its key back from a closed holder | the retried run | `key`, `from` |

- `input_changed` compares the new input with the holder's, both after
  `Durable.Executor.sanitize_for_json/1`, so atom and string keys compare equal.
- `Activity.list/1` gains `:workflow_id` and `:kinds`. The Queues page's
  Operations feed asks for its current kinds only, so key events don't drown it.
- One activity row per duplicate. A producer that re-adds thousands of keys an
  hour is the ceiling; coalescing to one row per holder per minute is the
  upgrade if that shows up.
- Activity is kept for a week, so key numbers cover at most 7 days.

Telemetry, added to `Durable.Telemetry.events/0` and the Telemetry page's
catalog:

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:durable, :key, :duplicate]` | `%{count: 1}` | `:workflow`, `:key`, `:holder_id`, `:outcome`, `:input_changed` |
| `[:durable, :key, :handoff]` | `%{count: 1}` | `:workflow`, `:key`, `:from`, `:to` |
| `[:durable, :key, :release]` | `%{count: 1}` | `:workflow`, `:key`, `:workflow_id`, `:by` |

These replace the review page's single `[:durable, :workflow, :deduplicated]`.

### Dashboard

**Run page, direction A** (`WorkflowLive`):

- Header: a key chip (`key` label, mono value) with a **Holds key** or **Key
  moved** badge.
- Facts strip: `Key` (and the run it took the key from) and `Re-added`
  (count, last time).
- Banner, when the holder dropped newer input: "Added again 3 times while
  running. The newest input differs from this run's and was dropped."
- A **Key** view at `/executions/:id/key`, shown only for keyed runs (as Family
  is shown only with a family), its tab count the number of re-adds:
  - **Added again**: time, outcome, input (same, or "Newer input dropped"),
    node. A dropped input expands to a field diff and Copy input.
  - **Runs with this key**: each run, its status, and how the key moved.
- Retry and Rerun say why they're off, naming the holder: "Retry needs
  `article:42` back. `3f2a91c4` holds it and is still running." When the
  holder is closed and `reuse:` allows it, Retry reads "Retry and take the key
  back". `describe_error/1` covers `{:key_taken, id}`, `:key_contended`,
  `:no_key`.
- **Release key** on a closed holder, with an inline confirmation that says
  what the next start will do. Operator access, through `Access.perform/5`.

**Runs and ⌘K, direction A**:

- `key:` in the search grammar and suggestions. A keyed run shows its key
  under the run id, so no column is added and the fixed widths stay.
- The bulk bar gets "Release N keys", counting only closed runs that hold a key.
- ⌘K looks up a query shaped like a key (it contains `:`) and lists matches in
  a **Keys** group that opens the holder.

**Workflow page, direction C** (`WorkflowDetailLive`): a **Keys** section for
workflows that have started a keyed run:

- A readout: keys held, re-added, newer input dropped (amber when above 0),
  handed off, errors returned.
- Re-adds per bucket, stacked by outcome (returned the holder, returned an
  error).
- **Re-added most**: key, holder status, re-adds, dropped inputs; each key
  links to its holder's Key view.
- The 30-day range shows the last 7 days, and the panel says so.

The Key view, the dropped-input diff, the key chip with its badges and the
Keys section go into `durable_dashboard/DESIGN.md` before any dashboard code.

## Implementation Plan

Core paths are under `durable/lib/durable/` unless noted.

1. **Migration** — `migration/migrations/v20261106000000_add_workflow_keys.ex`
   - The two columns and three indexes above; `down` drops them.
   - Append it to `@migrations` in `migration/migrator.ex`.
2. **Schema** — `storage/schemas/workflow_execution.ex`
   - `key` and `holds_key` fields, the 1–255 byte length check, a
     `unique_constraint` on the holder index.
   - One module attribute mapping each `reuse:` policy to its reusable statuses.
3. **DSL** — `dsl/workflow.ex`
   - Add `:reuse` and `:on_duplicate` to `@workflow_opts`, checked at compile
     time. Defaults: `:after_close`, `:use_existing`.
4. **Start** — `durable.ex` `start/3`, `executor.ex` `start_workflow/3` and
   `create_execution/5`
   - Validate `key:` and `on_duplicate:`; `reuse:` passed to `start/3` raises
     `ArgumentError`.
   - The keyed insert, holder lookup, release, `on_duplicate` answer, the
     3-round limit, Activity rows and telemetry.
5. **Retry** — `executor.ex` `reset_for_retry/2`, `reopen_parallel_block/3`
   - Take back a lost key or return `{:error, {:key_taken, holder_id}}`;
     record `key_retaken`.
6. **Rerun** — `executor.ex` `rerun_workflow/2`
   - Keep the key and start with `on_duplicate: :error`.
7. **Release** — `durable.ex`
   - `release_key(workflow_id, opts \\ [])` with the errors above; records
     `key_released` (`by` from opts).
8. **Reschedule guard** — `queue/adapters/postgres.ex` `do_reschedule/4`
   - Only move open runs.
9. **Query** — `query.ex`
   - A `:key` filter for `list_executions/1` and `count_executions/1`; the
     results include `holds_key`.
10. **Activity** — `activity.ex`
    - Document the four kinds; `:workflow_id` and `:kinds` options on `list/1`.
11. **Telemetry** — `telemetry.ex`
    - The three events in `@events` and the moduledoc.
12. **Stats** — `stats.ex`
    - `keys/1` (window and workflow opts): the readout numbers, re-adds per
      bucket by outcome, and the most re-added keys.
13. **CLI** — `durable/lib/mix/tasks/durable.retry.ex`
    - Skipped: the task starts a fresh unkeyed run rather than calling
      `Durable.retry/2`, so it never sees `{:key_taken, id}`.
14. **Docs** — `durable/guides/workflow_keys.md`, the `start/3` options, and
    `agents/ROADMAP.md`.
15. **Dashboard: design** — `durable_dashboard/DESIGN.md` (done separately)
16. **Dashboard: run page** — `durable_dashboard/lib/durable_dashboard/live/workflow_live.ex`
    and a new `components/workflow/key_tab.ex` (a LiveComponent, like
    `children_tab.ex` and `logs_tab.ex`)
    - Key chip and badge, facts, banner, the `:key` view, Retry and Rerun
      sentences, Release key with inline confirmation, `describe_error/1`
      clauses.
17. **Dashboard: Runs** — `live/executions_live.ex`, `run_search.ex`,
    `components/data/execution_filters.ex`, `assets/src/hooks/query_suggest.ts`
    - Key under the run id, the `key:` term and its suggestion, and
      `:release_key` in `run_action/3` and `eligible_ids/2` for the bulk bar.
18. **Dashboard: ⌘K** — `components/command/command_palette.ex`
    - Key-shaped queries look up runs by key; a Keys group opens the holder.
19. **Dashboard: workflow page** — `live/workflow_detail_live.ex`
    - The Keys section from `Durable.Stats.keys/1`.
20. **Dashboard: Queues and Telemetry** — `live/queues_live.ex`, `live/telemetry_live.ex`
    - Operations asks Activity for its own kinds only; the catalog lists the
      key events.

## Testing Strategy

Core, in a new `durable/test/durable/workflow_keys_test.exs`:

- Every cell of the key table: 3 policies × 9 statuses, each taken cell with
  both `on_duplicate` values.
- The same key twice returns the same id and one row; the same key on two
  workflows makes two runs; no key behaves as today.
- Retry on both paths takes back a lost key or returns `{:key_taken, id}`; the
  parallel path leaves children untouched.
- Status changes (claim, stale-lock recovery, zombie sweep, cancel,
  compensation) never change `holds_key`, and `reschedule` leaves closed runs
  alone.
- Rerun keeps the key and is refused while another run holds it.
- `release_key`: closed holder, open run, run without a key.
- Caller transaction: a duplicate leaves it usable, and a rollback frees the key.
- A duplicate runs nothing inline, broadcasts nothing, records `key_duplicate`
  with `input_changed`, and fires `[:durable, :key, :duplicate]`.
- Validation, pruning, and migration up and down (`migration_test.exs`).
- Race: 20 concurrent starts make exactly one row. The SQL sandbox shares one
  connection, so this test runs on real connections with
  `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`.
- `Activity.list/1` filters (`activity_test.exs`), `Stats.keys/1`
  (`stats_test.exs`), the `:key` filter (`query_test.exs`).

Dashboard, with `DurableDashboard.LiveCase` and real keyed runs from
`Fixtures`:

- `run_page_live_test.exs`: chip and badge, the Key view's two lists, the
  dropped-input diff, Retry's sentence when another run holds the key, Release
  key for operators and hidden for viewers.
- `runs_live_test.exs`: `key:` search and "Release N keys".
- `command_palette_test.exs`: a key query opens the holder.
- `workflows_live_test.exs`: the Keys section appears only for keyed workflows.
- `run_search_test.exs`: the `key:` token.

## Acceptance Criteria

- [x] A keyed start creates at most one run per key, on any number of nodes (race test).
- [x] Every cell of the key table has a test, with both `on_duplicate` values.
- [x] No status change writes `holds_key`, and `reschedule` can't reopen a closed run.
- [x] Retry and rerun never raise on a taken key; they return `{:error, {:key_taken, id}}`.
- [x] A duplicate inside a caller's transaction leaves the transaction usable.
- [x] `Durable.release_key/2` frees a closed holder's key and is audited in Activity.
- [x] The run page shows the key, its holder, re-adds and dropped inputs, and says why Retry or Rerun is off.
- [x] Runs search, ⌘K and the bulk bar handle keys; the workflow page shows the Keys section.
- [x] DESIGN.md documents the new run-page and workflow-page pieces.
- [x] `guides/workflow_keys.md` covers the documented edge cases.
- [x] `mix precommit` passes in both packages.

## Open Questions

Resolved during implementation:

- **Activity inside the caller's transaction.** Inside a transaction,
  `Activity.record/3` inserts with `mode: :savepoint`, so a failed activity
  insert rolls back only itself and never aborts the caller's transaction.
  Outside one it inserts plainly: Postgrex refuses savepoint mode there, and
  the first version lost every activity row recorded outside a transaction
  (`activity_test.exs` covers both on real connections).
- **Coalescing duplicates.** One Activity row per duplicate for now; coalesce
  per holder per minute if a producer's volume shows up as a problem.

Also fixed on the way: `Durable.Stats` bucketed from the window start
truncated to the second, so events in the window's last fraction of a second
landed one bucket past the end and vanished from `timeline/1`. Both
`timeline/1` and `keys/1` now bucket from the exact start.

## References

- Review page, edge cases E1–E36: https://claude.ai/artifact/CQr6TYpL3LrKx78tRYxdTC
- Strategy comparison: https://claude.ai/artifact/Db1whcuJFBa6vRduqWwu3R
- Dashboard concept (directions A and C): https://claude.ai/artifact/2zBj3QBYaAmcwQWuEqhqBm
- Temporal: [Workflow ID reuse and conflict policies](https://docs.temporal.io/workflow-execution/workflowid-runid), [Postgres schema, `current_executions`](https://github.com/temporalio/temporal/blob/main/schema/postgresql/v12/temporal/schema.sql)
- Oban: [Unique jobs](https://oban.hexdocs.pm/unique_jobs.html), ["Oban unique constraint crashes the queue"](https://elixirforum.com/t/oban-unique-constraint-crashes-the-queue/69648)
- Inngest: [idempotency](https://www.inngest.com/docs/guides/handling-idempotency), [singleton](https://www.inngest.com/docs/guides/singleton), [debounce](https://www.inngest.com/docs/guides/debounce)
- Patterns to follow: `Durable.Activity.record/3`, `Access.perform/5` in the dashboard, `components/workflow/children_tab.ex` for a run-page view
