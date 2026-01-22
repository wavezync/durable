# Building AI Workflows with Durable

Build reliable AI agent workflows with automatic retries, state persistence, and clear flow control.

## Setup

### 1. Add Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:durable, "~> 0.1.0"},
    {:req_llm, "~> 1.1"}
  ]
end
```

### 2. Create Migration

```bash
mix ecto.gen.migration add_durable
```

```elixir
# priv/repo/migrations/XXXXXX_add_durable.exs
defmodule MyApp.Repo.Migrations.AddDurable do
  use Ecto.Migration

  def up, do: Durable.Migration.up()
  def down, do: Durable.Migration.down()
end
```

### 3. Add to Supervision Tree

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Durable,
      repo: MyApp.Repo,
      queues: %{
        default: [concurrency: 10, poll_interval: 1000],
        ai: [concurrency: 5, poll_interval: 2000]  # Separate queue for AI tasks
      }}
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Example: Document Processing Pipeline

```elixir
defmodule MyApp.DocumentProcessor do
  use Durable
  use Durable.Helpers

  workflow "process_document" do
    step :fetch, fn ctx ->
      doc = DocumentStore.get(ctx["doc_id"])
      {:ok, %{doc: doc}}
    end

    # AI classification with automatic retry
    step :classify, [retry: [max_attempts: 3, backoff: :exponential]], fn ctx ->
      content = ctx.doc.content

      doc_type = ReqLLM.generate_text!(
        "anthropic:claude-sonnet-4-20250514",
        "Classify this document as :invoice, :contract, or :other. Reply with only the atom.\n\n#{content}"
      ) |> String.trim() |> String.to_atom()

      {:ok, assign(ctx, :doc_type, doc_type)}
    end

    # Conditional branching - only ONE path executes
    branch on: fn ctx -> ctx.doc_type end do
      :invoice ->
        step :extract_invoice, [retry: [max_attempts: 3]], fn ctx ->
          content = ctx.doc.content

          {:ok, extracted} = ReqLLM.generate_object(
            "anthropic:claude-sonnet-4-20250514",
            "Extract invoice fields from:\n\n#{content}",
            schema: %{
              invoice_number: :string,
              date: :string,
              total: :number,
              line_items: {:array, %{description: :string, amount: :number}}
            }
          )

          {:ok, assign(ctx, :extracted, extracted)}
        end

        step :validate_invoice, fn ctx ->
          extracted = ctx.extracted
          calculated = Enum.sum(Enum.map(extracted.line_items, & &1.amount))
          {:ok, assign(ctx, :valid, abs(calculated - extracted.total) < 0.01)}
        end

      :contract ->
        step :extract_contract, [retry: [max_attempts: 3]], fn ctx ->
          content = ctx.doc.content

          {:ok, extracted} = ReqLLM.generate_object(
            "anthropic:claude-sonnet-4-20250514",
            "Extract contract details:\n\n#{content}",
            schema: %{
              parties: {:array, :string},
              effective_date: :string,
              key_terms: {:array, :string}
            }
          )

          {:ok, assign(ctx, :extracted, extracted)}
        end

      _ ->
        step :flag_for_review, fn ctx ->
          {:ok, assign(ctx, :needs_review, true)}
        end
    end

    # Runs after any branch completes
    step :store, fn ctx ->
      doc = ctx.doc

      DocumentStore.update(doc.id, %{
        doc_type: ctx.doc_type,
        extracted_data: Map.get(ctx, :extracted, %{}),
        needs_review: Map.get(ctx, :needs_review, false)
      })

      {:ok, ctx}
    end
  end
end

# Start workflow
{:ok, workflow_id} = Durable.start(MyApp.DocumentProcessor, %{"doc_id" => "doc_123"})
```

## Key Patterns

### Retries for API Calls

```elixir
step :ai_call, [retry: [max_attempts: 3, backoff: :exponential]], fn ctx ->
  result = ReqLLM.generate_text!("anthropic:claude-sonnet-4-20250514", ctx.prompt)
  {:ok, assign(ctx, :result, result)}
end
```

### Validate AI Outputs

```elixir
step :extract, fn ctx ->
  case ReqLLM.generate_object(model, ctx.prompt, schema: schema) do
    {:ok, extracted} -> {:ok, assign(ctx, :data, extracted)}
    {:error, _} -> raise "Invalid response"  # Triggers retry
  end
end
```

### Human-in-the-Loop

```elixir
use Durable.Wait

step :review, fn ctx ->
  if ctx.confidence < 0.8 do
    result = wait_for_input("human_review", timeout: hours(24))
    {:ok, assign(ctx, :human_verified, result)}
  else
    {:ok, ctx}
  end
end
```

### Branch on AI Classification

```elixir
branch on: fn ctx -> ctx.category end do
  :billing ->
    step :handle_billing, fn ctx -> {:ok, ctx} end
  :technical ->
    step :handle_technical, fn ctx -> {:ok, ctx} end
  _ ->
    step :handle_default, fn ctx -> {:ok, ctx} end
end
```

## Monitoring

```elixir
# Get execution status
{:ok, execution} = Durable.get_execution(workflow_id)
execution.status   # :running, :completed, :failed, :waiting
execution.context  # All accumulated data

# With step details
{:ok, execution} = Durable.get_execution(workflow_id, include_steps: true)
Enum.each(execution.steps, fn step ->
  IO.puts("#{step.step_name}: #{step.status} (#{step.duration_ms}ms)")
end)
```
