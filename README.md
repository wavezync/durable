# Durable

[![Build Status](https://github.com/wavezync/durable/actions/workflows/ci.yml/badge.svg)](https://github.com/wavezync/durable/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/durable.svg)](https://hex.pm/packages/durable)

A durable, resumable workflow engine for Elixir, similar to Temporal/Inngest.

## ✨ Features

- 📝 **Declarative DSL** - Clean macro-based workflow definitions
- ⏸️ **Resumability** - Sleep, wait for events, wait for human input
- 🔀 **Conditional Branching** - Intuitive `branch` construct for flow control
- ⚡ **Parallel Execution** - Run steps concurrently with `parallel`
- 🔄 **Reliability** - Automatic retries with configurable backoff strategies
- 🔍 **Observability** - Built-in log capture per step
- 💾 **Persistence** - PostgreSQL-backed execution state

## 📦 Installation

Add `durable` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:durable, "~> 0.0.0-alpha"}
  ]
end
```

## 🚀 Quick Start

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

## 📄 Document Processing Example

Durable shines for multi-step pipelines that need reliability and clear flow control:

```elixir
defmodule MyApp.DocumentProcessor do
  use Durable
  use Durable.Context

  workflow "process_document" do
    step :fetch do
      doc = DocumentStore.get(input()["doc_id"])
      put_context(:doc, doc)
      put_context(:doc_type, doc.type)
    end

    # Conditional branching - only ONE path executes
    branch on: get_context(:doc_type) do
      :invoice ->
        step :process_invoice, retry: [max_attempts: 3] do
          invoice = InvoiceParser.parse(get_context(:doc))
          put_context(:result, invoice)
        end

        step :validate_invoice do
          invoice = get_context(:result)
          put_context(:valid, invoice.total == Enum.sum(invoice.line_items))
        end

      :contract ->
        step :process_contract do
          contract = ContractParser.parse(get_context(:doc))
          put_context(:result, contract)
        end

      _ ->
        step :flag_for_review do
          put_context(:needs_review, true)
        end
    end

    # Runs after any branch completes
    step :store do
      DocumentStore.update(get_context(:doc).id, %{
        doc_type: get_context(:doc_type),
        processed_data: get_context(:result, %{}),
        needs_review: get_context(:needs_review, false)
      })
    end
  end
end
```

**Key benefits:**

- 🔄 **Automatic Retries** - Failed steps retry with configurable backoff
- 💾 **State Persistence** - Workflow resumes from the last step after crashes
- 🔀 **Clear Flow Control** - The `branch` construct makes conditional logic readable
- 🔍 **Observability** - Each step's logs are captured for debugging

## 📖 DSL Reference

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

### 🔀 Branch (Conditional Flow)

The `branch` macro provides intuitive conditional execution. Only ONE branch executes based on the condition, then execution continues after the branch block.

```elixir
branch on: get_context(:status) do
  :approved ->
    step :process_approved do
      # Handle approved case
    end

  :rejected ->
    step :process_rejected do
      # Handle rejected case
    end

  _ ->
    step :process_default do
      # Default case
    end
end
```

Features:
- Pattern matching on atoms, strings, integers, and booleans
- Default clause with `_` wildcard
- Multiple steps per branch
- Execution continues after the branch block

### ⚡ Parallel Execution

Run multiple steps concurrently and wait for all to complete:

```elixir
parallel do
  step :fetch_user do
    put_context(:user, UserService.get(input().user_id))
  end

  step :fetch_orders do
    put_context(:orders, OrderService.list(input().user_id))
  end

  step :fetch_preferences do
    put_context(:prefs, PreferenceService.get(input().user_id))
  end
end

# Continues after all parallel steps complete
step :build_dashboard do
  Dashboard.build(
    get_context(:user),
    get_context(:orders),
    get_context(:prefs)
  )
end
```

#### 🚀 Advanced: Parallel Workflows

Nest `parallel` inside `branch` to run different concurrent tasks based on conditions. This example processes documents differently by type - contracts run 3 extractions in parallel, while invoices use a single step:

```elixir
workflow "process_document" do
  step :fetch do
    doc = DocumentStore.get(input()["doc_id"])
    put_context(:doc, doc)
  end

  step :classify, retry: [max_attempts: 3] do
    result = AI.classify(get_context(:doc).content)
    put_context(:doc_type, result.type)
  end

  branch on: get_context(:doc_type) do
    :contract ->
      # Run multiple AI extractions in parallel
      parallel do
        step :extract_parties do
          put_context(:parties, AI.extract_parties(get_context(:doc)))
        end

        step :extract_terms do
          put_context(:terms, AI.extract_terms(get_context(:doc)))
        end

        step :check_signatures do
          put_context(:signatures, AI.detect_signatures(get_context(:doc)))
        end
      end

      step :merge_results do
        put_context(:extracted, %{
          parties: get_context(:parties),
          terms: get_context(:terms),
          signatures: get_context(:signatures)
        })
      end

    :invoice ->
      step :extract_invoice do
        put_context(:extracted, AI.extract_invoice(get_context(:doc)))
      end

    _ ->
      step :flag_review do
        put_context(:needs_review, true)
      end
  end

  step :store do
    DocumentStore.save(get_context(:doc).id, get_context(:extracted, %{}))
  end
end
```

### 📦 Context Management

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

### ⏰ Time Helpers

```elixir
seconds(30)   # 30,000 ms
minutes(5)    # 300,000 ms
hours(2)      # 7,200,000 ms
days(7)       # 604,800,000 ms
```

### ⏸️ Wait Primitives

```elixir
use Durable.Wait

# Sleep for duration
sleep_for(seconds: 30)
sleep_for(minutes: 5)
sleep_for(hours: 24)

# Sleep until specific time
sleep_until(~U[2025-12-25 00:00:00Z])

# Wait for external event
wait_for_event("payment_confirmed", timeout: minutes(5))

# Wait for human input
wait_for_input("manager_decision", timeout: days(3))
```

### 🔄 Retry Strategies

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

## 🔌 API Reference

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

### Providing Input/Events

```elixir
# Resume a waiting workflow with input
Durable.provide_input(workflow_id, "manager_decision", %{approved: true})

# Send an event to a waiting workflow
Durable.send_event(workflow_id, "payment_confirmed", %{payment_id: "pay_123"})
```

## 🔮 Coming Soon

- 🔁 Collection iteration (`each items, as: :item do ... end`)
- ↩️ Compensation/Saga patterns
- 📅 Cron scheduling
- 📊 Graph visualization
- 🖥️ Phoenix LiveView dashboard

## 📄 License

MIT
