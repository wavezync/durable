# M02: Developer Tooling

**Status:** Not Started
**Priority:** High
**Effort:** 1 week
**Dependencies:** None

## Motivation

Developers need CLI tools to inspect and manage workflows without writing code or opening a database console. Mix tasks provide a familiar Elixir interface for checking queue health, listing workflow executions, and performing common operations. This is the highest-impact DX improvement for day-to-day usage.

## Scope

### In Scope

- `mix durable.status` — queue stats, active/pending/failed counts
- `mix durable.list` — list workflow executions with filters
- `mix durable.run` — manually start a workflow from CLI
- `mix durable.cancel` — cancel a running workflow
- `mix durable.cleanup` — purge old completed/failed executions

### Out of Scope

- Interactive/TUI dashboard (M06 covers web dashboard)
- Graph visualization in terminal (consider in M01 as open question)
- Remote node management

## Architecture & Design

### Module Layout

```
lib/mix/tasks/
├── durable.gen.migration.ex    # Existing
├── durable.install.ex          # Existing
├── durable.status.ex           # NEW
├── durable.list.ex             # NEW
├── durable.run.ex              # NEW
├── durable.cancel.ex           # NEW
└── durable.cleanup.ex          # NEW
```

All tasks follow the same pattern as existing `durable.gen.migration.ex`:
- `use Mix.Task`
- Call `Mix.Task.run("app.start")` to boot the application (needed for Ecto/Durable)
- Parse args with `OptionParser`
- Use `Mix.shell().info/error` for output

### Task Details

#### `mix durable.status`

Displays queue health and workflow summary:

```
$ mix durable.status

Queue Status (Durable)
──────────────────────────────────
  Queue          Workers  Active  Pending
  default        10       3       12
  high_priority  20       8       2

Workflow Summary
──────────────────────────────────
  Status      Count
  running     11
  waiting     5
  completed   1,234
  failed      23
  cancelled   7
```

Implementation:
- Query `Durable.Queue.Manager.stats/2` for queue info
- Query `Durable.Query` with group-by status for workflow counts
- Options: `--name` (Durable instance name, default: `Durable`)

#### `mix durable.list`

Lists workflow executions with filters:

```
$ mix durable.list --status running --limit 20
$ mix durable.list --workflow MyApp.OrderWorkflow --status failed
$ mix durable.list --since "2026-03-01"
```

Implementation:
- Uses `Durable.Query.list_executions/1` with CLI-provided filters
- Options: `--status`, `--workflow`, `--limit` (default 20), `--since`, `--queue`, `--format` (table|json)
- Table output with columns: ID (truncated), Workflow, Status, Queue, Started, Duration

#### `mix durable.run`

Start a workflow from CLI:

```
$ mix durable.run MyApp.OrderWorkflow --input '{"order_id": 123}'
$ mix durable.run MyApp.OrderWorkflow --queue high_priority
```

Implementation:
- Parse module name, decode JSON input
- Call `Durable.start/3`
- Print workflow ID on success

#### `mix durable.cancel`

Cancel a running workflow:

```
$ mix durable.cancel <workflow-id>
$ mix durable.cancel <workflow-id> --reason "duplicate"
```

Implementation:
- Call `Durable.cancel/2`
- Print confirmation or error

#### `mix durable.cleanup`

Purge old completed/failed executions:

```
$ mix durable.cleanup --older-than 30d --status completed
$ mix durable.cleanup --older-than 7d --status failed --dry-run
```

Implementation:
- Build query for executions matching criteria
- `--dry-run` shows count without deleting
- Requires `--older-than` (safety — no accidental purge of recent data)
- Delete in batches to avoid long transactions

### Shared Helpers

Extract a `Durable.CLI` module (or keep inline) for:
- Table formatting (column alignment, truncation)
- Duration formatting (e.g., "2h 15m", "3d")
- ID truncation (first 8 chars of UUID)

## Implementation Plan

1. **`mix durable.status`** — `lib/mix/tasks/durable.status.ex`
   - Query queue stats and workflow summary
   - Format as aligned table output
   - This is the simplest task — start here

2. **`mix durable.list`** — `lib/mix/tasks/durable.list.ex`
   - Parse filter options
   - Call `Durable.Query.list_executions/1`
   - Format as table or JSON

3. **`mix durable.run`** — `lib/mix/tasks/durable.run.ex`
   - Parse module name and JSON input
   - Call `Durable.start/3`
   - Print workflow ID

4. **`mix durable.cancel`** — `lib/mix/tasks/durable.cancel.ex`
   - Parse workflow ID and optional reason
   - Call `Durable.cancel/2`
   - Print result

5. **`mix durable.cleanup`** — `lib/mix/tasks/durable.cleanup.ex`
   - Parse age/status filters
   - Implement batch deletion query
   - Support `--dry-run`

## Testing Strategy

- `test/mix/tasks/durable_status_test.exs` — test with seeded data, verify output format
- `test/mix/tasks/durable_list_test.exs` — test filter parsing, output with various execution states
- `test/mix/tasks/durable_run_test.exs` — test workflow start, invalid module handling
- `test/mix/tasks/durable_cancel_test.exs` — test cancel success/failure
- `test/mix/tasks/durable_cleanup_test.exs` — test dry-run vs actual delete, batch deletion
- All tests use `Durable.DataCase` for DB isolation
- Test arg parsing edge cases (invalid JSON, missing required args)

## Acceptance Criteria

- [ ] `mix durable.status` displays queue and workflow summary
- [ ] `mix durable.list` filters by status, workflow, date, queue
- [ ] `mix durable.list --format json` outputs valid JSON
- [ ] `mix durable.run` starts a workflow and prints ID
- [ ] `mix durable.cancel` cancels a workflow with confirmation
- [ ] `mix durable.cleanup --dry-run` shows count without deleting
- [ ] `mix durable.cleanup` deletes in batches, requires `--older-than`
- [ ] All tasks call `Mix.Task.run("app.start")` before DB access
- [ ] All tasks have `@shortdoc` and `@moduledoc`
- [ ] Error messages are helpful (invalid args, workflow not found, etc.)
- [ ] `mix credo --strict` passes

## Open Questions

- Should `mix durable.list` support `--follow` mode (poll for updates)?
- Should `mix durable.cleanup` cascade-delete step_executions, or rely on DB foreign keys?
- Do we need `mix durable.retry` to retry a failed workflow?

## References

- `lib/mix/tasks/durable.gen.migration.ex` — pattern for Mix task structure
- `lib/mix/tasks/durable.install.ex` — Igniter-based task pattern
- `lib/durable/query.ex` — query functions for list/status
- `lib/durable/queue/manager.ex` — queue stats API
