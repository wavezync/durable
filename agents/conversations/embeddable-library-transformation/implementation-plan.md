# Implementation Plan: Embeddable Library Transformation

## Status: COMPLETED

All implementation steps have been completed successfully. This document serves as a reference for the work done and the patterns established.

## Objective

Transform Durable from a standalone application with its own Ecto repo into an embeddable library that:
- Uses the host application's Ecto repo
- Integrates into the host's supervision tree
- Provides programmatic migrations
- Isolates tables in a dedicated PostgreSQL schema

## Implementation Steps

### Phase 1: Configuration System

- [x] **Create `lib/durable/config.ex`**
  - NimbleOptions schema for validation
  - `start_link/1` to validate and store config
  - `repo/0`, `prefix/0`, `name/0` accessors
  - Persistent term storage for fast reads

### Phase 2: Migration System

- [x] **Create `lib/durable/migration.ex`**
  - `up/0` function to create all tables
  - `down/0` function to drop all tables
  - Creates `durable` PostgreSQL schema
  - Tables: `workflow_executions`, `step_executions`, `pending_inputs`, `scheduled_workflows`

### Phase 3: Supervision Tree

- [x] **Create `lib/durable/supervisor.ex`**
  - Main entry point via `child_spec/1`
  - Starts Config, Queue.Manager, StaleJobRecovery
  - Supports `use Durable.Supervisor` for aliasing

### Phase 4: Dynamic Repo Integration

- [x] **Update all Ecto schemas**
  - Add `@schema_prefix "durable"` to all schemas
  - Files: `workflow_execution.ex`, `step_execution.ex`, `pending_input.ex`, `scheduled_workflow.ex`

- [x] **Update all database-accessing modules**
  - Replace `Durable.Repo` with `Durable.Config.repo()`
  - Files: `postgres.ex`, `executor.ex`, `query.ex`, `wait.ex`

### Phase 5: Cleanup

- [x] **Remove hardcoded repo**
  - Delete `lib/durable/repo.ex`
  - Create `test/support/test_repo.ex` for tests

### Phase 6: Documentation

- [x] **Update README.md** - New installation instructions
- [x] **Update CLAUDE.md** - Architecture changes
- [x] **Update guides/ai_workflows.md** - Setup section

## Configuration Reference

```elixir
{Durable,
  # Required: Your application's Ecto repo
  repo: MyApp.Repo,

  # Optional: Instance name (default: Durable)
  name: Durable,

  # Optional: PostgreSQL schema prefix (default: "durable")
  prefix: "durable",

  # Optional: Queue configurations
  queues: %{
    default: [concurrency: 10, poll_interval: 1000],
    high_priority: [concurrency: 5, poll_interval: 500]
  },

  # Optional: Enable/disable queue processing (default: true)
  queue_enabled: true,

  # Optional: Seconds before lock is considered stale (default: 300)
  stale_lock_timeout: 300,

  # Optional: Worker heartbeat interval in ms (default: 30_000)
  heartbeat_interval: 30_000
}
```

## Migration Details

The `Durable.Migration.up/0` function creates:

1. **PostgreSQL Schema**: `durable`

2. **workflow_executions table**
   - `id` (binary_id, primary key)
   - `workflow_name` (string)
   - `status` (string)
   - `input` (map)
   - `result` (map)
   - `error` (map)
   - `metadata` (map)
   - `started_at`, `completed_at` (timestamps)
   - Indexes on `workflow_name`, `status`, composite

3. **step_executions table**
   - `id` (binary_id, primary key)
   - `workflow_execution_id` (foreign key)
   - `step_name` (string)
   - `status` (string)
   - `input`, `output`, `error` (maps)
   - `attempt` (integer)
   - Indexes on workflow_execution_id, step_name, status

4. **pending_inputs table**
   - `id` (binary_id, primary key)
   - `workflow_execution_id` (foreign key)
   - `input_name` (string)
   - `status` (string)
   - `value` (map)
   - Unique index on `[workflow_execution_id, input_name]`

5. **scheduled_workflows table**
   - `id` (binary_id, primary key)
   - `queue` (string)
   - `workflow_name` (string)
   - `input` (map)
   - `status` (string)
   - `scheduled_at`, `locked_at`, `locked_by` (timestamps/strings)
   - `last_heartbeat_at` (timestamp)
   - `attempt`, `max_attempts` (integers)
   - Indexes for queue polling and stale lock recovery

## Architecture Diagram

```
Host Application
├── MyApp.Repo (Ecto)
└── Supervision Tree
    └── {Durable, repo: MyApp.Repo}
        ├── Durable.Config (persistent_term storage)
        ├── Durable.Queue.Manager
        │   └── Queue workers (per queue)
        └── Durable.Queue.StaleJobRecovery
```

## Testing Considerations

- Tests use `Durable.TestRepo` defined in `test/support/test_repo.ex`
- Test config in `config/test.exs` points to test database
- All 80 tests pass with the new architecture
- Use `Ecto.Adapters.SQL.Sandbox` for test isolation

## Rollback Procedure

If needed, the transformation can be rolled back by:
1. Restoring `lib/durable/repo.ex`
2. Removing dynamic repo calls
3. Removing schema prefixes
4. Reverting documentation changes

However, this is not recommended as the embeddable pattern is the intended design.

---
*Maintained by conversation-archiver agent*
