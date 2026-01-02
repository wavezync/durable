# Building AI Workflows with Durable

This guide shows how to build reliable AI agent workflows using Durable with the Anthropic Claude API via [Req](https://hex.pm/packages/req).

## Why Durable for AI Workflows?

AI workflows have unique challenges:

1. **API Reliability** - LLM APIs can timeout, rate limit, or fail
2. **Long Running** - Complex AI tasks may take minutes
3. **State Management** - Need to track intermediate results
4. **Conditional Logic** - Different processing based on AI classification
5. **Observability** - Debug why an AI workflow produced unexpected results

Durable solves all of these:

- **Automatic retries** with exponential backoff for flaky APIs
- **State persistence** - workflow resumes if your server restarts
- **Built-in context** - store intermediate results between steps
- **Branch macro** - clean conditional flow based on AI outputs
- **Log capture** - every step's logs saved for debugging

## Basic Setup

Add dependencies to your `mix.exs`:

```elixir
defp deps do
  [
    {:durable, "~> 0.1.0"},
    {:req, "~> 0.5"}
  ]
end
```

Create a helper module for Claude API calls:

```elixir
defmodule MyApp.Claude do
  @api_url "https://api.anthropic.com/v1/messages"

  def chat(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, "claude-sonnet-4-20250514")
    max_tokens = Keyword.get(opts, :max_tokens, 1000)
    system = Keyword.get(opts, :system)

    messages = [%{role: "user", content: prompt}]

    body = %{
      model: model,
      max_tokens: max_tokens,
      messages: messages
    }

    body = if system, do: Map.put(body, :system, system), else: body

    case Req.post(@api_url,
      auth: {:bearer, api_key()},
      json: body,
      receive_timeout: 60_000
    ) do
      {:ok, %{status: 200, body: body}} ->
        text = body["content"] |> hd() |> Map.get("text")
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        {:error, "API error #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  defp api_key do
    System.get_env("ANTHROPIC_API_KEY") ||
      raise "ANTHROPIC_API_KEY environment variable not set"
  end
end
```

## Example 1: Simple Text Classification

Classify customer support tickets:

```elixir
defmodule MyApp.TicketClassifier do
  use Durable
  use Durable.Context

  alias MyApp.Claude

  workflow "classify_ticket" do
    step :classify, retry: [max_attempts: 3, backoff: :exponential] do
      ticket = input()["ticket"]

      {:ok, category} = Claude.chat("""
      Classify this support ticket into exactly one category:
      - billing
      - technical
      - account
      - other

      Reply with only the category name.

      Ticket: #{ticket["subject"]}

      #{ticket["body"]}
      """)

      put_context(:category, String.trim(category) |> String.to_atom())
    end

    branch on: get_context(:category) do
      :billing ->
        step :route_billing do
          TicketService.assign(input()["ticket"]["id"], team: :billing)
          put_context(:routed_to, "billing")
        end

      :technical ->
        step :route_technical do
          TicketService.assign(input()["ticket"]["id"], team: :engineering)
          put_context(:routed_to, "engineering")
        end

      _ ->
        step :route_general do
          TicketService.assign(input()["ticket"]["id"], team: :support)
          put_context(:routed_to, "general_support")
        end
    end

    step :notify do
      Slack.notify("#support", "Ticket routed to #{get_context(:routed_to)}")
    end
  end
end

# Usage
{:ok, workflow_id} = Durable.start(MyApp.TicketClassifier, %{
  "ticket" => %{
    "id" => "ticket_123",
    "subject" => "Can't access my account",
    "body" => "I forgot my password and the reset email isn't arriving..."
  }
})
```

## Example 2: Document Processing Pipeline

Extract structured data from documents:

```elixir
defmodule MyApp.DocumentProcessor do
  use Durable
  use Durable.Context

  alias MyApp.Claude

  workflow "process_document" do
    step :fetch do
      doc = DocumentStore.get(input()["doc_id"])
      put_context(:doc, doc)
      put_context(:content, doc.content)
    end

    # Step 1: Classify document type
    step :classify, retry: [max_attempts: 3] do
      {:ok, doc_type} = Claude.chat("""
      What type of document is this? Reply with exactly one of:
      - invoice
      - contract
      - receipt
      - resume
      - other

      Document:
      #{String.slice(get_context(:content), 0, 3000)}
      """)

      put_context(:doc_type, String.trim(doc_type) |> String.to_atom())
    end

    # Step 2: Extract based on type
    branch on: get_context(:doc_type) do
      :invoice ->
        step :extract_invoice, retry: [max_attempts: 3] do
          {:ok, json} = Claude.chat("""
          Extract invoice data as valid JSON:
          {
            "invoice_number": "string",
            "date": "YYYY-MM-DD",
            "vendor": "string",
            "total": number,
            "currency": "USD/EUR/etc",
            "line_items": [{"description": "string", "quantity": number, "unit_price": number}]
          }

          Return ONLY the JSON, no other text.

          Document:
          #{get_context(:content)}
          """, max_tokens: 2000)

          put_context(:extracted, Jason.decode!(json))
        end

        step :validate_invoice do
          data = get_context(:extracted)
          items_total = data["line_items"]
            |> Enum.map(fn item -> item["quantity"] * item["unit_price"] end)
            |> Enum.sum()

          put_context(:valid, abs(items_total - data["total"]) < 0.01)
        end

      :contract ->
        step :extract_contract, retry: [max_attempts: 3] do
          {:ok, json} = Claude.chat("""
          Extract contract data as valid JSON:
          {
            "parties": ["party name 1", "party name 2"],
            "effective_date": "YYYY-MM-DD",
            "expiration_date": "YYYY-MM-DD or null",
            "contract_value": number or null,
            "key_obligations": ["obligation 1", "obligation 2"]
          }

          Return ONLY the JSON.

          Document:
          #{get_context(:content)}
          """, max_tokens: 2000)

          put_context(:extracted, Jason.decode!(json))
        end

      :resume ->
        step :extract_resume, retry: [max_attempts: 3] do
          {:ok, json} = Claude.chat("""
          Extract resume data as valid JSON:
          {
            "name": "string",
            "email": "string or null",
            "phone": "string or null",
            "skills": ["skill1", "skill2"],
            "experience_years": number,
            "education": [{"degree": "string", "institution": "string", "year": number}]
          }

          Return ONLY the JSON.

          Document:
          #{get_context(:content)}
          """, max_tokens: 2000)

          put_context(:extracted, Jason.decode!(json))
        end

      _ ->
        step :flag_unknown do
          put_context(:needs_review, true)
          put_context(:extracted, %{})
        end
    end

    # Step 3: Store results
    step :store do
      doc = get_context(:doc)

      DocumentStore.update(doc.id, %{
        doc_type: get_context(:doc_type),
        extracted_data: get_context(:extracted),
        valid: get_context(:valid, true),
        needs_review: get_context(:needs_review, false),
        processed_at: DateTime.utc_now()
      })
    end

    # Step 4: Notify
    step :callback do
      if input()["callback_url"] do
        Req.post!(input()["callback_url"], json: %{
          doc_id: get_context(:doc).id,
          doc_type: get_context(:doc_type),
          status: "processed"
        })
      end
    end
  end
end
```

## Example 3: Multi-Step AI Agent

An AI agent that researches and writes content:

```elixir
defmodule MyApp.ContentAgent do
  use Durable
  use Durable.Context
  use Durable.Wait

  alias MyApp.Claude

  workflow "create_blog_post" do
    step :understand_request do
      {:ok, analysis} = Claude.chat("""
      Analyze this blog post request and extract:
      1. Main topic
      2. Target audience
      3. Desired tone (professional, casual, technical)
      4. Key points to cover

      Request: #{input()["request"]}

      Reply as JSON:
      {
        "topic": "string",
        "audience": "string",
        "tone": "string",
        "key_points": ["point1", "point2"]
      }
      """, system: "You are a content strategist.")

      put_context(:analysis, Jason.decode!(analysis))
    end

    step :research, retry: [max_attempts: 3] do
      analysis = get_context(:analysis)

      {:ok, research} = Claude.chat("""
      Research the following topic and provide key facts, statistics,
      and insights that would be valuable for a blog post.

      Topic: #{analysis["topic"]}
      Audience: #{analysis["audience"]}
      Key points to cover: #{Enum.join(analysis["key_points"], ", ")}

      Provide 5-7 research points with sources where applicable.
      """,
        system: "You are a research assistant.",
        max_tokens: 2000
      )

      put_context(:research, research)
    end

    step :create_outline do
      analysis = get_context(:analysis)
      research = get_context(:research)

      {:ok, outline} = Claude.chat("""
      Create a detailed blog post outline based on:

      Topic: #{analysis["topic"]}
      Tone: #{analysis["tone"]}
      Key points: #{Enum.join(analysis["key_points"], ", ")}

      Research findings:
      #{research}

      Create an outline with:
      - Catchy title
      - Introduction hook
      - 3-5 main sections with subpoints
      - Conclusion with call-to-action
      """,
        system: "You are a content strategist.",
        max_tokens: 1500
      )

      put_context(:outline, outline)
    end

    # Optional: Get human approval of outline
    step :request_approval do
      if input()["require_approval"] do
        wait_for_input("outline_approval",
          timeout: hours(24),
          prompt: "Review the outline and approve or request changes"
        )
      end
    end

    branch on: input()["require_approval"] && get_context(:outline_approval, %{})["approved"] == false do
      true ->
        step :revise_outline do
          feedback = get_context(:outline_approval)["feedback"]
          original = get_context(:outline)

          {:ok, revised} = Claude.chat("""
          Revise this outline based on the feedback:

          Original outline:
          #{original}

          Feedback:
          #{feedback}

          Create an improved outline addressing the feedback.
          """)

          put_context(:outline, revised)
        end

      _ ->
        step :proceed do
          # No revision needed
          :ok
        end
    end

    step :write_draft, retry: [max_attempts: 2] do
      analysis = get_context(:analysis)
      outline = get_context(:outline)
      research = get_context(:research)

      {:ok, draft} = Claude.chat("""
      Write a complete blog post based on this outline.

      Outline:
      #{outline}

      Research to incorporate:
      #{research}

      Requirements:
      - Tone: #{analysis["tone"]}
      - Target audience: #{analysis["audience"]}
      - Length: 800-1200 words
      - Include relevant examples
      - End with clear call-to-action
      """,
        system: "You are an expert blog writer.",
        max_tokens: 4000
      )

      put_context(:draft, draft)
    end

    step :polish do
      draft = get_context(:draft)

      {:ok, final} = Claude.chat("""
      Polish this blog post draft:

      #{draft}

      Improvements to make:
      - Fix any grammatical errors
      - Improve transitions between sections
      - Ensure consistent tone throughout
      - Add a compelling meta description (under 160 chars)

      Return the polished post with the meta description at the top.
      """,
        max_tokens: 4500
      )

      put_context(:final_post, final)
    end

    step :save do
      BlogPost.create!(%{
        title: get_context(:analysis)["topic"],
        content: get_context(:final_post),
        status: :draft,
        metadata: %{
          workflow_id: workflow_id(),
          analysis: get_context(:analysis)
        }
      })
    end
  end
end

# Usage
{:ok, workflow_id} = Durable.start(MyApp.ContentAgent, %{
  "request" => "Write a blog post about the benefits of Elixir for building AI applications",
  "require_approval" => true
})

# Later, approve the outline
Durable.provide_input(workflow_id, "outline_approval", %{
  "approved" => true
})
```

## Best Practices

### 1. Always Use Retries for API Calls

```elixir
step :ai_call, retry: [max_attempts: 3, backoff: :exponential] do
  # API call here
end
```

### 2. Set Reasonable Timeouts

```elixir
# In your Req calls
Req.post(url, receive_timeout: 60_000)  # 60 seconds for LLM calls

# For workflow steps
step :long_ai_task, timeout: minutes(5) do
  # Complex AI processing
end
```

### 3. Validate AI Outputs

```elixir
step :extract do
  {:ok, response} = Claude.chat("Extract as JSON...")

  case Jason.decode(response) do
    {:ok, data} ->
      put_context(:data, data)
    {:error, _} ->
      # Re-raise to trigger retry
      raise "Invalid JSON response from AI"
  end
end
```

### 4. Use Context for Intermediate Results

```elixir
# Store intermediate results
put_context(:step1_result, result)

# Access in later steps
previous = get_context(:step1_result)
```

### 5. Handle Human-in-the-Loop

```elixir
step :review do
  if get_context(:confidence) < 0.8 do
    result = wait_for_input("human_review",
      timeout: hours(24),
      prompt: "AI confidence low, please review"
    )
    put_context(:human_verified, result)
  end
end
```

### 6. Log Important Information

```elixir
step :process do
  require Logger

  Logger.info("Processing document: #{get_context(:doc_id)}")
  # ... processing ...
  Logger.info("Classification result: #{result}")
end
```

All logs are automatically captured per step for debugging.

## Monitoring AI Workflows

Query workflow status:

```elixir
# Get execution details
{:ok, execution} = Durable.get_execution(workflow_id)

execution.status      # :running, :completed, :failed, :waiting
execution.current_step # "extract_invoice"
execution.context     # All accumulated context

# Get step-level details
{:ok, execution} = Durable.get_execution(workflow_id, include_steps: true)

Enum.each(execution.steps, fn step ->
  IO.puts("#{step.step_name}: #{step.status} (#{step.duration_ms}ms)")
  IO.puts("Logs: #{inspect(step.logs)}")
end)
```

List executions by status:

```elixir
# Find failed AI workflows
failed = Durable.list_executions(
  workflow: MyApp.DocumentProcessor,
  status: :failed,
  limit: 50
)

# Find waiting for human input
waiting = Durable.list_executions(
  status: :waiting
)
```
