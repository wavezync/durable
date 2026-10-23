# Durable — Roadmap

**Last Updated:** 2026-10-23
**Current release:** `durable` 1.1.0 (2026-10-23) and `durable_dashboard` 1.0.0 (2026-10-21) on Hex
**Reference:** See `arch.md` for technical architecture, `WORKPLAN_ARCHIVED.md` for historical detail

---

## Quick Stats

| Metric | Core (`durable/`) | Dashboard (`durable_dashboard/`) |
|--------|-------------------|----------------------------------|
| Source modules | 77 | 37 |
| Tests | ~483 | ~235 |
| Lines of code | ~18,000 | — |
| Guides | 6 | — |

---

## Completed Work

| Area | Key Features |
|------|-------------|
| **Foundation** | Mix project, Ecto schemas, programmatic migrations, NimbleOptions config, CI (`mix precommit`), Credo strict |
| **Core MVP** | `workflow`/`step`/`decision` macros, context management, executor, retry/backoff, PostgreSQL queue (FOR UPDATE SKIP LOCKED), query API, time helpers |
| **Wait Primitives** | `sleep`, `schedule_at`, `wait_for_event`, `wait_for_any/all`, `wait_for_input`, `wait_for_approval`, `wait_for_choice`, `wait_for_text`, `wait_for_form`, timeouts |
| **Branching** | `branch on:` macro with pattern matching, default clause, multi-step branches |
| **Parallel Execution** | `parallel do` macro, `__results__` model, `into:` merge, `returns:` option, error strategies, resume durability, deterministic block ids |
| **Compensation/Saga** | `compensate` macro, `step :name, compensate:`, reverse-order execution |
| **Cron Scheduling** | `@schedule` decorator, scheduler GenServer, multi-node safety, timezone support, CRUD API, enable/disable, manual trigger, failure tracking + auto-disable, `upcoming_runs/2` |
| **Workflow Orchestration** | `call_workflow/3`, `start_workflow/3`, parallel call_workflow, cascade cancellation, parent notifications, `list_children/2` |
| **Hardening (Apr 2026 audit)** | JSONB sanitization at every write boundary, context survives retries/gotos, `Ecto.Multi` for timeout/child/wait-group transitions, ack retries, `:compensating` zombie recovery — see `docs/bug-reports/2026-04-13-follow-up-audit.md` |
| **Operator Controls** | Retry/rerun, cancel (CAS race fixed), queue pause, workflow `timeout:` (deadline enforced between steps), workflow `queue:`, `trigger` tracking, pruner, node registry |
| **Observability** | Logger handler, IO capture, log buffer, `Durable.Telemetry` events + metrics, `Durable.Stats`, `Durable.Activity` log, queue sampler, `Durable.PubSub` lifecycle broadcasts |
| **Testing ([M03](milestones/M03-testing-framework.md))** | `Durable.Testing`: `run_workflow`, `drain` (runs parallel branches + child workflows, skips sleeps and retry backoff), `assert_status`/`assert_step`/`assert_waiting_for_input`/`assert_waiting_for_event`, `guides/testing.md` |
| **CLI ([M02](milestones/M02-developer-tooling.md))** | `mix durable.*`: status, list, inspect, run, cancel, retry, cleanup, pending, provide_input, send_event, doctor, install, migrations, gen.migration, gen.upgrade |
| **Dashboard ([M06](milestones/M06-phoenix-dashboard.md))** | Separate `durable_dashboard` package: LiveView pages (Overview, Runs, Run, Workflows, Inbox, Queues, Schedules, Telemetry, Settings), ReactFlow graph island, ⌘K palette |
| **Docs & Release ([M04](milestones/M04-documentation-release.md))** | HexDocs, 6 guides, git-cliff changelogs, GitHub Actions release + Hex publish, durable.wavezync.com, exported `locals_without_parens` for the DSL (#10) |

---

## Milestones

| ID | Title | Status | Notes |
|----|-------|--------|-------|
| [M01](milestones/M01-graph-visualization.md) | Graph Visualization | Superseded | Dashboard `GraphBuilder` + ReactFlow covers it. Core DOT/Mermaid export not built → backlog |
| [M02](milestones/M02-developer-tooling.md) | Developer Tooling | Done | Shipped more tasks than planned |
| [M03](milestones/M03-testing-framework.md) | Testing Framework | Done | Shipped as `Durable.Testing` helpers (imported into the user's own case) rather than a `Durable.TestCase` template |
| [M04](milestones/M04-documentation-release.md) | Documentation & Release | Done | 1.0.0 published |
| [M05](milestones/M05-message-bus.md) | Message Bus | Partial | `Durable.PubSub` lifecycle events shipped. Adapter behaviour / pg_notify not built → backlog |
| [M06](milestones/M06-phoenix-dashboard.md) | Phoenix Dashboard | Done | Shipped as its own package |
| [M07](milestones/M07-scalability-adapters.md) | Scalability Adapters | Backlog | No demand for Redis yet |
| [M08](milestones/M08-workflow-versioning.md) | Workflow Versioning | In Progress | Phase 1 (fail on a removed step) done; phase 2 (`version:` pinning) waits on the doc's open questions |

---

## Next Up

In priority order:

1. **Workflow versioning, phase 2** ([M08](milestones/M08-workflow-versioning.md)). Pin each run to the `version:` it started on. Needs the doc's three open questions answered first. Adds a migration.
2. **DSL gaps:** waits inside `parallel` blocks, an `each`/foreach primitive (each iteration needs its own context, see `Durable.DSL.Step` docs), decisions inside `parallel`.
3. **Testing follow-up:** wait timeouts can't be exercised by `Durable.Testing.drain/2` (the timeout worker only runs with the queue on). A helper that fires a run's pending timeouts would close it.

---

## Backlog

| Item | Notes |
|------|-------|
| DOT/Mermaid graph export | Leftover from M01. For docs/READMEs, if requested |
| Message bus adapter behaviour / pg_notify | Leftover from M05. `Phoenix.PubSub` already spans nodes |
| Redis queue adapter | M07. Add when someone needs it |
| RabbitMQ queue adapter | Niche — add if requested |
| Switch/Case macro | Low priority — `branch` covers most use cases |
| Pipe-based API | Functional workflow composition — nice-to-have |

---

## Known Limitations

1. Wait primitives (and child workflows that wait) are not supported inside parallel blocks
2. Decisions are not supported inside parallel blocks
3. No backward jumps in decision steps (forward-only by design)
4. Context is single-level atomized (top-level keys only)
5. No workflow version pinning (M08)
6. No foreach/loop DSL primitive (use Elixir's `Enum` functions)
7. A resumed wait re-runs the step body from the top; side effects before the wait must be idempotent
8. Only one `sleep/1` per step body
9. `Durable.Testing.drain/2` doesn't fire wait timeouts
10. A step with a `timeout:`, or in a workflow with one, runs in its own process (`self()` isn't the worker)
11. In-flight runs resume on the deployed definition; a removed current step fails the run (versioning: M08)
