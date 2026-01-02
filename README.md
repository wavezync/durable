# Durable

A durable, resumable workflow engine for Elixir, similar to Temporal/Inngest.

## Features

- **Declarative DSL** - Clean macro-based workflow definitions
- **Resumability** - Sleep, wait for events, wait for human input
- **Conditional Branching** - Intuitive `branch` construct for flow control
- **Reliability** - Automatic retries with configurable backoff strategies
- **Observability** - Built-in log capture per step
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

## AI Workflow Example

Durable is ideal for building AI agent workflows that need reliability, resumability, and clear flow control. Here's a document processing pipeline using [ReqLLM](https://hex.pm/packages/req_llm) for AI calls:

```elixir
defmodule MyApp.DocumentProcessor do
  use Durable
  use Durable.Context

  workflow "process_document" do
    step :fetch_document do
      doc = DocumentStore.get(input()["doc_id"])
      put_context(:document, doc)
      put_context(:content, doc.content)
    end

    step :classify, retry: [max_attempts: 3, backoff: :exponential] do
      content = get_context(:content)

      {:ok, response} = Req.post("https://api.anthropic.com/v1/messages",
        auth: {:bearer, System.get_env("ANTHROPIC_API_KEY")},
        json: %{
          model: "claude-sonnet-4-20250514",
          max_tokens: 100,
          messages: [%{
            role: "user",
            content: "Classify this document as :invoice, :contract, or :other. Reply with only the category atom.\n\n#{content}"
          }]
        }
      )

      doc_type = response.body["content"] |> hd() |> Map.get("text") |> String.trim() |> String.to_atom()
      put_context(:doc_type, doc_type)
    end

    # Conditional branching - only ONE path executes
    branch on: get_context(:doc_type) do
      :invoice ->
        step :extract_invoice do
          content = get_context(:content)

          {:ok, response} = Req.post("https://api.anthropic.com/v1/messages",
            auth: {:bearer, System.get_env("ANTHROPIC_API_KEY")},
            json: %{
              model: "claude-sonnet-4-20250514",
              max_tokens: 1000,
              messages: [%{
                role: "user",
                content: """
                Extract invoice fields from this document as JSON:
                - invoice_number
                - date
                - total
                - line_items (array of {description, amount})

                Document:
                #{content}
                """
              }]
            }
          )

          extracted = response.body["content"] |> hd() |> Map.get("text") |> Jason.decode!()
          put_context(:extracted, extracted)
        end

        step :validate_invoice do
          extracted = get_context(:extracted)
          # Validate totals match line items
          calculated = Enum.sum(Enum.map(extracted["line_items"], & &1["amount"]))
          put_context(:valid, abs(calculated - extracted["total"]) < 0.01)
        end

      :contract ->
        step :extract_contract do
          content = get_context(:content)

          {:ok, response} = Req.post("https://api.anthropic.com/v1/messages",
            auth: {:bearer, System.get_env("ANTHROPIC_API_KEY")},
            json: %{
              model: "claude-sonnet-4-20250514",
              max_tokens: 2000,
              messages: [%{
                role: "user",
                content: """
                Extract contract details as JSON:
                - parties (array of names)
                - effective_date
                - term_length
                - key_terms (array of strings)

                Document:
                #{content}
                """
              }]
            }
          )

          extracted = response.body["content"] |> hd() |> Map.get("text") |> Jason.decode!()
          put_context(:extracted, extracted)
        end

      _ ->
        step :flag_for_review do
          put_context(:needs_review, true)
          put_context(:review_reason, "Unknown document type")
        end
    end

    # This step runs AFTER any branch completes
    step :store_result do
      doc = get_context(:document)
      extracted = get_context(:extracted, %{})

      DocumentStore.update(doc.id, %{
        status: :processed,
        doc_type: get_context(:doc_type),
        extracted_data: extracted,
        needs_review: get_context(:needs_review, false)
      })
    end
  end
end
```

Key benefits for AI workflows:

- **Automatic Retries** - API calls retry with exponential backoff on failure
- **State Persistence** - If the workflow crashes, it resumes from the last step
- **Clear Flow Control** - The `branch` construct makes conditional logic readable
- **Observability** - Each step's logs are captured for debugging

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

### Branch (Conditional Flow)

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

### Decision Steps (Legacy)

For simple conditional jumps, you can also use `decision` steps:

```elixir
decision :check_amount do
  if get_context(:amount) > 1000 do
    {:goto, :manager_approval}
  else
    {:goto, :auto_approve}
  end
end

step :auto_approve do
  # ...
end

step :manager_approval do
  # ...
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

### Wait Primitives

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

### Providing Input/Events

```elixir
# Resume a waiting workflow with input
Durable.provide_input(workflow_id, "manager_decision", %{approved: true})

# Send an event to a waiting workflow
Durable.send_event(workflow_id, "payment_confirmed", %{payment_id: "pay_123"})
```

## Coming Soon

- Parallel execution (`parallel do ... end`)
- Collection iteration (`each items, as: :item do ... end`)
- Compensation/Saga patterns
- Cron scheduling
- Graph visualization
- Phoenix LiveView dashboard

## License

MIT
