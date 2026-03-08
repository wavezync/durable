# Durable — Roadmap

**Last Updated:** 2026-03-09
**Reference:** See `arch.md` for technical architecture, `WORKPLAN_ARCHIVED.md` for historical detail

---

## Quick Stats

| Metric | Value |
|--------|-------|
| Source Modules | 42 |
| Passing Tests | ~291 |
| Documentation Guides | 6 |
| Lines of Code | ~11,000 |

---

## Completed Work

| Area | Key Features | Tests |
|------|-------------|-------|
| **Foundation** | Mix project, Ecto schemas (6), programmatic migrations, NimbleOptions config, CI (`mix precommit`), Credo strict | — |
| **Core MVP** | `workflow`/`step`/`decision` macros, context management, executor, retry/backoff, PostgreSQL queue (FOR UPDATE SKIP LOCKED), query API, time helpers | ~65 |
| **Wait Primitives** | `sleep`, `schedule_at`, `wait_for_event`, `wait_for_any/all`, `wait_for_input`, `wait_for_approval`, `wait_for_choice`, `wait_for_text`, `wait_for_form`, timeouts | 52 |
| **Branching** | `branch on:` macro with pattern matching, default clause, multi-step branches | 19 |
| **Parallel Execution** | `parallel do` macro, `__results__` model, `into:` merge, `returns:` option, error strategies, resume durability | 20 |
| **Compensation/Saga** | `compensate` macro, `step :name, compensate:`, reverse-order execution | 10 |
| **Cron Scheduling** | `@schedule` decorator, scheduler GenServer, multi-node safety, timezone support, CRUD API, enable/disable, manual trigger | 49 |
| **Workflow Orchestration** | `call_workflow/3`, `start_workflow/3`, parallel call_workflow, cascade cancellation, parent notifications, `list_children/2` | 12 |
| **Observability** | Logger handler, IO capture, log buffer | 13 |
| **Developer Experience** | `mix durable.gen.migration`, `mix durable.install`, DataCase, @moduledoc/@doc/@spec, 6 guides | — |

**Total Tests:** ~291

---

## Active Milestones

| ID | Title | Priority | Effort | Status | Dependencies |
|----|-------|----------|--------|--------|--------------|
| [M01](milestones/M01-graph-visualization.md) | Graph Visualization | Medium | 1 week | Not Started | None |
| [M02](milestones/M02-developer-tooling.md) | Developer Tooling | High | 1 week | Not Started | None |
| [M03](milestones/M03-testing-framework.md) | Testing Framework | Medium | 1 week | Not Started | None |
| [M04](milestones/M04-documentation-release.md) | Documentation & Release | High | 1 week | Not Started | M02, M03 (soft) |
| [M05](milestones/M05-message-bus.md) | Message Bus | Medium | 1.5 weeks | Not Started | None |
| [M06](milestones/M06-phoenix-dashboard.md) | Phoenix Dashboard | Low | 2 weeks | Not Started | M01, M05 |
| [M07](milestones/M07-scalability-adapters.md) | Scalability Adapters | Low | 2 weeks | Not Started | M05 (soft) |

### Recommended Execution Order

```
M02 (Developer Tooling)  ─┐
M03 (Testing Framework)  ─┤──→ M04 (Documentation & Release)
M01 (Graph Visualization) ┘
                           ──→ M05 (Message Bus)
                                    ├──→ M06 (Phoenix Dashboard)
                                    └──→ M07 (Scalability Adapters)
```

**Phase A** (parallel, no dependencies): M01, M02, M03
**Phase B** (needs Phase A): M04
**Phase C** (independent): M05
**Phase D** (needs M01 + M05): M06, M07

---

## Backlog

Lower-priority items not warranting standalone milestone documents:

| Item | Notes |
|------|-------|
| Switch/Case macro | Low priority — `branch` covers most use cases |
| Pipe-based API | Functional workflow composition — nice-to-have |
| Example Project | Standalone demo app with common patterns |
| Redis message bus | Quick follow-up after M05 + M07 |
| RabbitMQ queue adapter | Niche — add if requested |

---

## Test Coverage

| Test File | Tests | Area |
|-----------|-------|------|
| wait_test.exs | 52 | Wait primitives |
| scheduler_test.exs | 49 | Cron scheduling |
| parallel_test.exs | 20 | Parallel execution |
| branch_test.exs | 19 | Branch macro |
| postgres_test.exs | 16 | Queue adapter |
| decision_test.exs | 14 | Decision steps |
| log_capture_test.exs | 13 | Log/IO capture |
| orchestration_test.exs | 12 | Workflow orchestration |
| integration_test.exs | 11 | End-to-end flows |
| validation_test.exs | 10 | Input validation |
| context_test.exs | 10 | Context management |
| compensation_test.exs | 10 | Saga pattern |
| durable_test.exs | 10 | Core API |
| handler_test.exs | 8 | Log handler |
| io_server_test.exs | 7 | IO capture |
| resume_edge_cases_test.exs | 5 | Resume edge cases |
| log_capture/integration_test.exs | 5 | Log capture integration |
| Other | ~20 | Misc |
| **Total** | **~291** | |

---

## Known Limitations

1. Wait primitives not supported in parallel blocks
2. Child workflows with waits (`sleep`, `wait_for_event`) not supported in parallel blocks
3. No backward jumps in decision steps (forward-only by design)
4. Context is single-level atomized (top-level keys only)
5. No workflow versioning
6. No foreach/loop DSL primitives (use Elixir's `Enum` functions)
