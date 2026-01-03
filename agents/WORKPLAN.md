# Durable Workflow Engine - Work Plan

**Last Updated:** 2026-01-03
**Overall Progress:** ~75% Complete
**Reference:** See `IMPLEMENTATION_PLAN.md` for detailed design and code examples

---

## Quick Stats

| Metric | Value |
|--------|-------|
| Source Modules | 41 |
| Passing Tests | 214 |
| Documentation Guides | 6 |
| Lines of Code | ~8,500 |

---

## Phase Overview

| Phase | Description | Status | Progress |
|-------|-------------|--------|----------|
| 0 | Project Foundation | Complete | 100% |
| 1 | Core MVP | Complete | 100% |
| 2 | Observability | Partial | 40% |
| 3 | Advanced Features | Mostly Complete | 85% |
| 4 | Scalability | Not Started | 0% |
| 5 | Developer Experience | Partial | 35% |

---

## Phase 0: Foundation [COMPLETE]

| Component | Status |
|-----------|--------|
| Mix project config | Complete |
| Directory structure | Complete |
| Ecto schemas (6) | Complete |
| Programmatic migrations | Complete |
| NimbleOptions config | Complete |
| CI/CD (`mix precommit`) | Complete |
| Credo strict mode | Complete |

---

## Phase 1: Core MVP [COMPLETE]

| Feature | Status |
|---------|--------|
| `workflow` macro | Complete |
| `step` macro | Complete |
| `decision` macro | Complete |
| Context management | Complete |
| Executor | Complete |
| StepRunner | Complete |
| Retry/Backoff | Complete |
| PostgreSQL Queue | Complete |
| Queue Worker | Complete |
| Stale Job Recovery | Complete |
| Query API | Complete |
| Time Helpers | Complete |

---

## Phase 2: Observability [40%]

### Completed

| Feature | Tests |
|---------|-------|
| Logger Handler | 7 |
| IO Capture | 6 |
| Log Buffer | - |

### Remaining

| Feature | Priority | Complexity |
|---------|----------|------------|
| Graph Generation | Medium | Medium |
| DOT Export | Low | Low |
| Mermaid Export | Low | Low |
| Cytoscape Export | Low | Low |
| Execution State Overlay | Medium | Medium |
| Phoenix Dashboard | Low | High |

---

## Phase 3: Advanced Features [85%]

### 3.1-3.3 Wait Primitives [COMPLETE - 46 tests]

| Feature | Status |
|---------|--------|
| `sleep/1` | Complete |
| `schedule_at/1` | Complete |
| `wait_for_event/1,2` | Complete |
| `wait_for_any/1,2` | Complete |
| `wait_for_all/1,2` | Complete |
| `wait_for_input/1,2` | Complete |
| `wait_for_approval/1,2` | Complete |
| `wait_for_choice/2` | Complete |
| `wait_for_text/1,2` | Complete |
| `wait_for_form/2` | Complete |
| Timeout handling | Complete |
| Context preservation | Complete |

### 3.4 Conditional Branching [COMPLETE - 10 tests]

| Feature | Status |
|---------|--------|
| `branch on:` macro | Complete |
| Pattern matching | Complete |
| Default clause | Complete |
| Multiple steps per branch | Complete |
| `decision` macro (legacy) | Complete |

### 3.5 Loops [SKIPPED]

Intentionally skipped - use step-level retries or `foreach` instead.

### 3.6 Parallel Execution [COMPLETE - 13 tests]

| Feature | Status |
|---------|--------|
| `parallel do` macro | Complete |
| Context merge strategies | Complete |
| Error strategies | Complete |
| Resume durability | Complete |

### 3.7 ForEach [COMPLETE - 13 tests]

| Feature | Status |
|---------|--------|
| `foreach` macro | Complete |
| `current_item/0`, `current_index/0` | Complete |
| Sequential/Concurrent modes | Complete |
| `:collect_as` option | Complete |
| `:on_error` handling | Complete |

### 3.8 Switch/Case [NOT STARTED]

Low priority - `branch` macro covers most cases.

### 3.9 Compensation/Saga [COMPLETE - 6 tests]

| Feature | Status |
|---------|--------|
| `compensate` macro | Complete |
| `step :name, compensate:` | Complete |
| Reverse-order execution | Complete |
| CompensationRunner | Complete |

### 3.10 Cron Scheduling [COMPLETE - 45 tests]

| Feature | Status |
|---------|--------|
| `@schedule` decorator | Complete |
| Scheduler GenServer | Complete |
| Multi-node safety | Complete |
| Cron parsing | Complete |
| Timezone support | Complete |
| CRUD API | Complete |
| Enable/disable | Complete |
| Manual trigger | Complete |
| Telemetry events | Complete |

### Remaining Phase 3 Work

| Feature | Priority | Complexity |
|---------|----------|------------|
| Workflow Orchestration (`call_workflow`) | High | Medium |
| Parent-child tracking | High | Low |
| Switch/Case macro | Low | Low |
| Pipe-based API | Low | Medium |

---

## Phase 4: Scalability [0%]

| Feature | Priority | Complexity |
|---------|----------|------------|
| Queue Adapter Behaviour | Complete | - |
| Redis Queue Adapter | Medium | Medium |
| RabbitMQ Queue Adapter | Low | Medium |
| Message Bus Behaviour | Medium | Low |
| PostgreSQL pg_notify | Medium | Medium |
| Redis Pub/Sub | Low | Medium |
| Phoenix.PubSub | Medium | Low |
| Leader Election | Low | Medium |

Note: Multi-node scheduling already works via `FOR UPDATE SKIP LOCKED`.

---

## Phase 5: Developer Experience [35%]

### Completed

| Feature | Status |
|---------|--------|
| `mix durable.gen.migration` | Complete |
| DataCase | Complete |
| Module docs (@moduledoc) | Complete |
| Function docs (@doc) | Complete |
| Typespecs (@spec) | Complete |
| 6 Documentation Guides | Complete |

### Remaining

| Feature | Priority | Complexity |
|---------|----------|------------|
| Guide: Getting Started | High | Low |
| HexDocs Publishing | High | Low |
| `mix durable.status` | High | Low |
| Guide: Testing | Medium | Low |
| `Durable.TestCase` | Medium | Medium |
| `mix durable.list` | Medium | Low |
| `mix durable.run` | Low | Low |
| `mix durable.cancel` | Low | Low |
| `mix durable.cleanup` | Low | Low |
| Additional Guides | Low | Low |
| Example Project | Low | Medium |

---

## Priority Roadmap

### High Priority

1. Guide: Getting Started
2. Workflow Orchestration (`call_workflow`)
3. HexDocs Publishing
4. `mix durable.status`

### Medium Priority

5. Guide: Testing Workflows
6. `Durable.TestCase`
7. Graph Generation
8. `mix durable.list`
9. pg_notify Message Bus

### Lower Priority

10. Switch/Case macro
11. Redis Queue Adapter
12. Phoenix Dashboard
13. Example Project
14. Pipe-based API

---

## Test Coverage

| Test File | Tests | Area |
|-----------|-------|------|
| scheduler_test.exs | 45 | Cron scheduling |
| wait_test.exs | 46 | Wait primitives |
| decision_test.exs | 13 | Decision steps |
| parallel_test.exs | 13 | Parallel execution |
| foreach_test.exs | 13 | ForEach iteration |
| log_capture_test.exs | 13 | Log/IO capture |
| integration_test.exs | 11 | End-to-end flows |
| branch_test.exs | 10 | Branch macro |
| durable_test.exs | 8 | Core API |
| compensation_test.exs | 6 | Saga pattern |
| Other | ~36 | Queue, handlers, etc. |
| **Total** | **214** | |

---

## Known Limitations

1. Wait primitives not supported in parallel/foreach blocks
2. No backward jumps in decision steps (forward-only by design)
3. Context is single-level atomized (top-level keys only)
4. No workflow versioning

---

## Next Steps

1. **Documentation** - Getting Started guide and HexDocs publishing
2. **Workflow Orchestration** - Child workflow support (`call_workflow`)
3. **Graph Visualization** - Understanding complex workflows

The existing 214 tests provide good confidence in implemented features. Suitable for internal use; additional documentation needed before public release.
