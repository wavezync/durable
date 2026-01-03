# Durable Development Context Index

This index provides quick access to archived development discussions and implementation plans for the Durable workflow engine.

## Active Topics

| Topic | Last Updated | Sessions | Status |
|-------|--------------|----------|--------|
| [Wait Primitives Complete](./conversations/wait-primitives-complete/) | 2026-01-03 | 1 | Completed |

## Completed Topics

| Topic | Completed | Description |
|-------|-----------|-------------|
| [Wait Primitives Complete](./conversations/wait-primitives-complete/) | 2026-01-03 | Resumability testing, context key bug fix, string key support, documentation |
| [CI Fix Parallel Jobs](./conversations/ci-fix-parallel-jobs/) | 2026-01-03 | Fixed CI failures after parallel jobs feature |
| [Parallel Durability Implementation](./conversations/parallel-durability-implementation/) | 2026-01-03 | Made parallel execution truly durable and resumable |
| [Embeddable Library Transformation](./conversations/embeddable-library-transformation/) | 2026-01-02 | Transformed Durable into an Oban-style embeddable library |

## Topic Quick Reference

### Wait Primitives Complete
**Path**: `agents/conversations/wait-primitives-complete/`

Covers the completion of Phase 3 (Wait Primitives) including resumability testing, context key bug fixes, and documentation updates. Key outcomes:
- Added 4 resumability tests for wait/resume cycles
- Fixed atom/string key mismatch via `atomize_keys/1` helper
- All context functions now accept both atom and string keys
- Comprehensive rewrite of `guides/waiting.md`

**Key Files Modified**:
- `lib/durable/context.ex`
- `lib/durable/wait.ex`
- `test/durable/wait_test.exs`
- `guides/waiting.md`

### Embeddable Library Transformation
**Path**: `agents/conversations/embeddable-library-transformation/`

Covers the transformation of Durable from a standalone application to an embeddable library pattern. Key outcomes:
- Dynamic repo via `Durable.Config.repo()`
- Programmatic migrations via `Durable.Migration.up()/down()`
- Supervisor-based integration into host application
- PostgreSQL schema isolation with `durable` prefix

**Key Files Created**:
- `lib/durable/config.ex`
- `lib/durable/migration.ex`
- `lib/durable/supervisor.ex`

### Parallel Durability Implementation
**Path**: `agents/conversations/parallel-durability-implementation/`

Covers making parallel steps truly durable so completed steps are NOT re-executed on resume. Key outcomes:
- Context snapshot storage in `__context__` key for parallel step outputs
- Resume logic checks for completed parallel steps before execution
- Stored contexts merged when resuming workflows
- 11 integration tests covering complex workflow combinations
- Bug fix: Decision/goto converging step pattern

**Key Files Modified**:
- `lib/durable/executor.ex`
- `lib/durable/executor/step_runner.ex`
- `test/durable/integration_test.exs`
- `test/durable/parallel_test.exs`

### CI Fix Parallel Jobs
**Path**: `agents/conversations/ci-fix-parallel-jobs/`

Covers fixing CI failures after the parallel jobs feature. Key outcomes:
- Updated precommit alias to match CI behavior
- Documented Credo strict mode requirements
- Refactored executor.ex to reduce complexity
- Extracted 11 helper functions for better maintainability

**Key Files Modified**:
- `lib/durable/executor.ex`
- `mix.exs`
- `test/durable/integration_test.exs`
- `test/durable/parallel_test.exs`

---

## How to Use This Index

1. **Finding Context**: Search this index when starting work on a feature that may have prior discussion
2. **Adding New Topics**: Use the conversation-archiver agent to add new topics
3. **Updating Existing Topics**: Add new sessions to existing topic folders

## Archive Structure

```
agents/
├── conversations/           # Archived discussion topics
│   └── {topic-slug}/
│       ├── README.md        # Topic overview
│       ├── sessions/        # Individual session records
│       └── implementation-plan.md
├── context-index.md         # This file
├── .archived-topics.json    # Machine-readable metadata
├── arch.md                  # Architecture notes
└── WORKPLAN.md              # Work planning
```

---
*Maintained by conversation-archiver agent*
