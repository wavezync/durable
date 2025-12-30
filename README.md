# Durable

A durable, resumable workflow engine for Elixir, similar to Temporal/Inngest.

## Features

- **Declarative DSL** - Clean macro-based workflow definitions
- **Resumability** - Sleep, wait for events, wait for human input
- **Reliability** - Automatic retries with configurable backoff strategies
- **Observability** - Built-in log capture per step (coming soon)
- **Persistence** - PostgreSQL-backed execution state

## Installation

Add `durable` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:durable, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Configure the Repo

```elixir
# config/config.exs
config :durable,
  ecto_repos: [Durable.Repo]

config :durable, Durable.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "durable_dev"
```

### 2. Run Migrations

```bash
mix ecto.create
mix ecto.migrate
```

### 3. Define a Workflow

```elixir
defmodule MyApp.OrderWorkflow do
  use Durable
  use Durable.Context

  workflow "process_order", timeout: hours(2) do
    step :validate do
      order = input().order
      put_context(:order_id, order.id)
      put_context(:items, order.items)
    end

    step :calculate_total do
      items = get_context(:items)
      total = Enum.sum(Enum.map(items, & &1.price))
      put_context(:total, total)
    end

    step :charge_payment, retry: [max_attempts: 3, backoff: :exponential] do
      total = get_context(:total)
      {:ok, charge} = PaymentService.charge(get_context(:order_id), total)
      put_context(:charge_id, charge.id)
    end

    step :send_confirmation do
      EmailService.send_confirmation(get_context(:order_id))
    end
  end
end
```

### 4. Start a Workflow

```elixir
{:ok, workflow_id} = Durable.start(MyApp.OrderWorkflow, %{order: order})
```

### 5. Query Execution Status

```elixir
{:ok, execution} = Durable.get_execution(workflow_id)
execution.status  # => :completed
execution.context # => %{order_id: 123, total: 99.99, charge_id: "ch_xxx"}
```

## DSL Reference

### Workflow Definition

```elixir
workflow "name", timeout: hours(2), max_retries: 3 do
  # steps...
end
```

### Step Definition

```elixir
step :name do
  # step logic
end

step :name, retry: [max_attempts: 3, backoff: :exponential] do
  # step with retry
end

step :name, timeout: minutes(5) do
  # step with timeout
end
```

### Context Management

```elixir
use Durable.Context

# Read
context()                    # Get entire context
get_context(:key)            # Get specific key
get_context(:key, default)   # Get with default
input()                      # Get initial input
workflow_id()                # Get current workflow ID

# Write
put_context(:key, value)     # Set single key
put_context(%{k1: v1})       # Merge map
update_context(:key, &(&1 + 1))
delete_context(:key)

# Accumulators
append_context(:list, value)
increment_context(:counter, 1)
```

### Time Helpers

```elixir
seconds(30)   # 30,000 ms
minutes(5)    # 300,000 ms
hours(2)      # 7,200,000 ms
days(7)       # 604,800,000 ms
```

### Retry Strategies

- `:exponential` - Delay = base^attempt * 1000ms (default)
- `:linear` - Delay = attempt * base * 1000ms
- `:constant` - Fixed delay between retries

```elixir
step :api_call, retry: [
  max_attempts: 5,
  backoff: :exponential,
  base: 2,
  max_backoff: 60_000  # Cap at 1 minute
] do
  ExternalAPI.call()
end
```

## API Reference

### Starting Workflows

```elixir
Durable.start(Module, input)
Durable.start(Module, input,
  workflow: "name",
  queue: :high_priority,
  priority: 10,
  scheduled_at: ~U[2025-01-01 00:00:00Z]
)
```

### Querying Executions

```elixir
Durable.get_execution(workflow_id)
Durable.get_execution(workflow_id, include_steps: true)

Durable.list_executions(
  workflow: MyApp.OrderWorkflow,
  status: :running,
  limit: 100
)
```

### Controlling Workflows

```elixir
Durable.cancel(workflow_id)
Durable.cancel(workflow_id, "reason")
```

## Coming Soon

- Wait primitives (`sleep_for`, `wait_for_event`, `wait_for_input`)
- Decision steps and branching
- Parallel execution
- Loop and foreach constructs
- Compensation/Saga patterns
- Cron scheduling
- Graph visualization
- Phoenix LiveView dashboard

## License

MIT
