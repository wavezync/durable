# Building AI Workflows with Durable

Build reliable AI agent workflows with automatic retries, state persistence, and clear flow control.

## Setup

```elixir
# mix.exs
defp deps do
  [
    {:durable, "~> 0.1.0"},
    {:req_llm, "~> 1.1"}
  ]
end
```

## Example: Document Processing Pipeline

```elixir
defmodule MyApp.DocumentProcessor do
  use Durable
  use Durable.Context

  workflow "process_document" do
    step :fetch do
      doc = DocumentStore.get(input()["doc_id"])
      put_context(:doc, doc)
    end

    # AI classification with automatic retry
    step :classify, retry: [max_attempts: 3, backoff: :exponential] do
      content = get_context(:doc).content

      doc_type = ReqLLM.generate_text!(
        "anthropic:claude-sonnet-4-20250514",
        "Classify this document as :invoice, :contract, or :other. Reply with only the atom.\n\n#{content}"
      ) |> String.trim() |> String.to_atom()

      put_context(:doc_type, doc_type)
    end

    # Conditional branching - only ONE path executes
    branch on: get_context(:doc_type) do
      :invoice ->
        step :extract_invoice, retry: [max_attempts: 3] do
          content = get_context(:doc).content

          {:ok, data} = ReqLLM.generate_object(
            "anthropic:claude-sonnet-4-20250514",
            "Extract invoice fields from:\n\n#{content}",
            schema: %{
              invoice_number: :string,
              date: :string,
              total: :number,
              line_items: {:array, %{description: :string, amount: :number}}
            }
          )

          put_context(:extracted, data)
        end

        step :validate_invoice do
          data = get_context(:extracted)
          calculated = Enum.sum(Enum.map(data.line_items, & &1.amount))
          put_context(:valid, abs(calculated - data.total) < 0.01)
        end

      :contract ->
        step :extract_contract, retry: [max_attempts: 3] do
          content = get_context(:doc).content

          {:ok, data} = ReqLLM.generate_object(
            "anthropic:claude-sonnet-4-20250514",
            "Extract contract details:\n\n#{content}",
            schema: %{
              parties: {:array, :string},
              effective_date: :string,
              key_terms: {:array, :string}
            }
          )

          put_context(:extracted, data)
        end

      _ ->
        step :flag_for_review do
          put_context(:needs_review, true)
        end
    end

    # Runs after any branch completes
    step :store do
      doc = get_context(:doc)

      DocumentStore.update(doc.id, %{
        doc_type: get_context(:doc_type),
        extracted_data: get_context(:extracted, %{}),
        needs_review: get_context(:needs_review, false)
      })
    end
  end
end

# Start workflow
{:ok, workflow_id} = Durable.start(MyApp.DocumentProcessor, %{"doc_id" => "doc_123"})
```

## Key Patterns

### Retries for API Calls

```elixir
step :ai_call, retry: [max_attempts: 3, backoff: :exponential] do
  ReqLLM.generate_text!("anthropic:claude-sonnet-4-20250514", prompt)
end
```

### Validate AI Outputs

```elixir
step :extract do
  case ReqLLM.generate_object(model, prompt, schema: schema) do
    {:ok, data} -> put_context(:data, data)
    {:error, _} -> raise "Invalid response"  # Triggers retry
  end
end
```

### Human-in-the-Loop

```elixir
use Durable.Wait

step :review do
  if get_context(:confidence) < 0.8 do
    result = wait_for_input("human_review", timeout: hours(24))
    put_context(:human_verified, result)
  end
end
```

### Branch on AI Classification

```elixir
branch on: get_context(:category) do
  :billing -> step :handle_billing do ... end
  :technical -> step :handle_technical do ... end
  _ -> step :handle_default do ... end
end
```

## Monitoring

```elixir
# Get execution status
{:ok, execution} = Durable.get_execution(workflow_id)
execution.status   # :running, :completed, :failed, :waiting
execution.context  # All accumulated context

# With step details
{:ok, execution} = Durable.get_execution(workflow_id, include_steps: true)
Enum.each(execution.steps, fn step ->
  IO.puts("#{step.step_name}: #{step.status} (#{step.duration_ms}ms)")
end)
```
