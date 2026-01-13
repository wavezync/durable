# Durable

Durable workflow engine for Elixir - provides resumable, reliable workflows with automatic retries, sleep/wait primitives, and PostgreSQL-backed persistence.

Durable is an **embeddable library** - users add it to their supervision tree and provide their own Ecto repo.

## Quick Reference

```bash
# Build & test
mix deps.get          # Install dependencies
mix compile           # Compile
mix test              # Run tests (creates/migrates DB automatically)

# Code quality
mix format            # Format code
mix credo --strict    # Lint (strict mode)
mix dialyzer          # Type checking

# Precommit (matches CI)
mix precommit         # Runs: format, compile --warnings-as-errors, credo --strict, test
```

## Architecture

```
lib/durable/
├── config.ex               # Configuration management (NimbleOptions, persistent_term)
├── migration.ex            # Programmatic migrations (up/down)
├── supervisor.ex           # Main supervisor for embedding
├── dsl/                    # Workflow DSL macros
│   ├── workflow.ex         # workflow/2 macro
│   ├── step.ex             # step/2/3, decision/2, each/3 macros
│   └── time_helpers.ex     # seconds/1, minutes/1, hours/1, days/1
├── definition.ex           # Runtime workflow/step definitions
├── executor.ex             # Workflow execution engine
├── executor/
│   ├── step_runner.ex      # Individual step execution
│   └── backoff.ex          # Retry backoff strategies
├── context.ex              # Workflow context (input/get_context/put_context)
├── wait.ex                 # Sleep/wait_for_event/wait_for_input
├── query.ex                # Query API for executions
├── queue/                  # Job queue system
│   ├── adapter.ex          # Queue adapter behaviour
│   ├── adapters/postgres.ex # PostgreSQL implementation (FOR UPDATE SKIP LOCKED)
│   ├── worker.ex           # Job worker with heartbeats
│   ├── poller.ex           # Queue polling
│   ├── manager.ex          # Queue supervisor
│   └── stale_job_recovery.ex # Recovers crashed jobs
├── storage/schemas/        # Ecto schemas (all use @schema_prefix "durable")
│   ├── workflow_execution.ex
│   ├── step_execution.ex
│   ├── pending_input.ex
│   └── scheduled_workflow.ex
└── application.ex          # OTP application (minimal - just log handler)
```

## Key Concepts

### Workflow Definition

```elixir
defmodule MyWorkflow do
  use Durable
  use Durable.Context

  workflow "my_workflow", timeout: hours(2) do
    step :first do
      # Access input with input()
      data = input().data
      # Store in context with put_context/2
      put_context(:key, data)
    end

    step :second, retry: [max_attempts: 3, backoff: :exponential] do
      # Retrieve from context with get_context/1
      get_context(:key)
    end
  end
end
```

### Queue System

- Jobs claimed atomically via `FOR UPDATE SKIP LOCKED`
- Workers send heartbeats to prevent stale lock recovery during long-running jobs
- Each worker runs in isolated process under DynamicSupervisor

### Installation

Durable is added to your application's supervision tree:

```elixir
# 1. Create migration
defmodule MyApp.Repo.Migrations.AddDurable do
  use Ecto.Migration
  def up, do: Durable.Migration.up()
  def down, do: Durable.Migration.down()
end

# 2. Add to supervision tree
children = [
  MyApp.Repo,
  {Durable, repo: MyApp.Repo, queues: %{default: [concurrency: 10]}}
]
```

### Configuration Options

- `:repo` - Your Ecto repo module (required)
- `:name` - Instance name for multi-tenancy (default: `Durable`)
- `:prefix` - PostgreSQL schema name (default: `"durable"`)
- `:queues` - Queue configs (default: `%{default: [concurrency: 10, poll_interval: 1000]}`)
- `:queue_enabled` - Enable queue processing (default: `true`)
- `:stale_lock_timeout` - Seconds before lock is stale (default: `300`)
- `:heartbeat_interval` - Worker heartbeat interval in ms (default: `30_000`)
- `:log_level` - Log level for internal queries, or `false` to disable (default: `false`)

## Testing

Tests use `Ecto.Adapters.SQL.Sandbox` for isolation. The postgres adapter tests are in `test/durable/queue/adapters/postgres_test.exs`.

```elixir
# Use DataCase for database tests
use Durable.DataCase, async: false
```

## Database

All tables live in the `durable` PostgreSQL schema: `durable.workflow_executions`, `durable.step_executions`, `durable.pending_inputs`, `durable.scheduled_workflows`

Uses binary UUIDs as primary keys.

## Code Style (Credo Strict Mode)

This project uses `credo --strict`. Key requirements:

- **Max nesting depth**: 2 levels (use helper functions to reduce nesting)
- **Max function arity**: 8 parameters (use opts maps for more)
- **Max cyclomatic complexity**: ~10 (split complex functions)
- **Numbers**: Use underscores for readability (`10_000` not `10000`)
- **List checks**: Use `list != []` instead of `length(list) > 0` (O(1) vs O(n))
- **Conditionals**: Use `if` instead of `cond` with only a true branch

### Opts Map Pattern

For functions with many parameters, use an opts map:

```elixir
# Instead of many parameters
def my_function(a, b, c, d, e, f, g, h, i)

# Use opts map
def my_function(a, b, opts) do
  %{c: c, d: d, e: e, f: f, g: g, h: h, i: i} = opts
  # ...
end
```
