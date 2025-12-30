# Durable

Durable workflow engine for Elixir - provides resumable, reliable workflows with automatic retries, sleep/wait primitives, and PostgreSQL-backed persistence.

## Quick Reference

```bash
# Build & test
mix deps.get          # Install dependencies
mix compile           # Compile
mix test              # Run tests (creates/migrates DB automatically)

# Database
mix ecto.setup        # Create and migrate database
mix ecto.reset        # Drop and recreate database
mix ecto.migrate      # Run migrations

# Code quality
mix format            # Format code
mix credo             # Lint
mix dialyzer          # Type checking
```

## Architecture

```
lib/durable/
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
├── storage/schemas/        # Ecto schemas
│   ├── workflow_execution.ex
│   ├── step_execution.ex
│   ├── pending_input.ex
│   └── scheduled_workflow.ex
├── repo.ex                 # Ecto repo
└── application.ex          # OTP application
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

### Configuration

```elixir
# config/config.exs
config :durable,
  ecto_repos: [Durable.Repo],
  queue_adapter: Durable.Queue.Adapters.Postgres,
  queues: %{default: [concurrency: 10, poll_interval: 1000]},
  stale_lock_timeout: 300,      # seconds
  heartbeat_interval: 30_000    # milliseconds
```

## Testing

Tests use `Ecto.Adapters.SQL.Sandbox` for isolation. The postgres adapter tests are in `test/durable/queue/adapters/postgres_test.exs`.

```elixir
# Use DataCase for database tests
use Durable.DataCase, async: false
```

## Database

Primary tables: `workflow_executions`, `step_executions`, `pending_inputs`, `scheduled_workflows`

Migrations in `priv/repo/migrations/`. Uses binary UUIDs as primary keys.
