# Durable - Elixir Durable Workflow Engine

## Project Overview

**Durable** is a durable, resumable workflow engine for Elixir, similar to Temporal/Inngest but designed to replace Oban with composable workflows. It provides built-in tracing, observability, resumability (wait for events, sleep), and a clean DSL for defining complex workflows.

### Key Goals
- Replace Oban entirely with composable workflows
- Built-in tracing and observability
- Resumability (wait for event, sleep for duration, wait for human input)
- Declarative workflow DSL with macros
- Graph visualization with real-time execution state
- Pluggable message bus (Redis, PostgreSQL pg_notify, RabbitMQ, NATS)
- Pluggable queue adapters (PostgreSQL default, Redis, RabbitMQ, Kafka, NATS)
- Automatic log capture (Logger + IO.puts/inspect) per step
- Retry logic with exponential backoff per step
- Cron scheduling with decorator syntax
- Compensation/Saga patterns for rollback

---

## Core Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Durable                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐   │
│  │   DSL/      │  │   Executor   │  │  Step Executor  │   │
│  │   Macros    │──│   (GenServer)│──│   (w/ Retries)  │   │
│  └─────────────┘  └──────────────┘  └─────────────────┘   │
│                           │                                 │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐   │
│  │   Queue     │  │   Message    │  │   Scheduler     │   │
│  │   Manager   │  │   Bus        │  │   (Cron)        │   │
│  └─────────────┘  └──────────────┘  └─────────────────┘   │
│         │                 │                                 │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────┐   │
│  │  Postgres/  │  │   PubSub/    │  │   Graph         │   │
│  │  Redis/     │  │   Redis/     │  │   Generator     │   │
│  │  RabbitMQ   │  │   pg_notify  │  │   + Layout      │   │
│  └─────────────┘  └──────────────┘  └─────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │        PostgreSQL Database (Execution State)          │  │
│  │  - workflow_executions                                │  │
│  │  - step_executions (with logs as JSONB)              │  │
│  │  - pending_inputs                                     │  │
│  │  - scheduled_workflows                                │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## DSL & Workflow Definition

### Basic Workflow Syntax

```elixir
defmodule OrderWorkflow do
  use Durable
  use Durable.Context  # context(), get_context(), put_context()
  use Durable.Wait     # wait_for_input(), sleep_for(), wait_for_event()
  
  workflow "process_order", timeout: hours(2), max_retries: 3 do
    
    step :validate_inventory do
      %{order: order} = input()
      Logger.info("Validating inventory")
      
      reserved = InventoryService.check(order.items)
      put_context(:reserved_items, reserved)
    end
    
    step :charge_payment, retry: [max_attempts: 3, backoff: :exponential] do
      order = get_context(:order)
      charge = PaymentService.charge(order.payment_method, order.total)
      put_context(:charge_id, charge.id)
    end
    
    step :send_confirmation do
      EmailService.send_confirmation(get_context(:order))
    end
  end
end
```

### Decision Steps

```elixir
decision :check_order_value do
  order = context().order
  
  cond do
    order.total > 10_000 -> :high_value
    order.total > 1_000 -> :medium_value
    true -> :standard
  end
end

on_decision :check_order_value do
  when_result :high_value do
    step :require_manual_review do
      wait_for_input("review_completed", timeout: days(2))
    end
  end
  
  when_result :medium_value do
    step :charge_with_verification do
      PaymentService.charge_with_3ds(context().order)
    end
  end
  
  when_result :standard do
    step :charge_standard do
      PaymentService.charge(context().order)
    end
  end
end
```

### Loops

```elixir
loop :retry_until_success, 
  while: fn ctx -> !ctx.success && ctx.current_retry < ctx.max_retries end do
  
  step :attempt_api_call do
    case ExternalAPI.call() do
      {:ok, result} -> put_context(:success, true)
      {:error, _} -> update_context(:current_retry, & &1 + 1)
    end
  end
  
  step :backoff do
    unless context().success do
      delay = :math.pow(2, context().current_retry) |> round()
      sleep_for(seconds: delay)
    end
  end
end
```

### Parallel Execution

```elixir
parallel do
  step :send_welcome_email do
    EmailService.send_welcome(state().user.email)
  end
  
  step :provision_workspace do
    WorkspaceService.create(state().user.id)
  end
  
  step :create_stripe_customer do
    StripeService.create_customer(state().user)
  end
end
```

### ForEach

```elixir
foreach :process_items, items: fn -> context().items end do |item|
  step :process_item do
    result = ItemProcessor.process(item)
    append_context(:results, result)
  end
end
```

### Switch/Case

```elixir
switch :route_by_category, on: fn -> context().category end do
  case_match "billing" do
    step :assign_to_billing do
      TicketService.assign(input().ticket, team: :billing)
    end
  end
  
  case_match "technical" do
    step :assign_to_engineering do
      TicketService.assign(input().ticket, team: :engineering)
    end
  end
  
  default do
    step :assign_to_general_support do
      TicketService.assign(input().ticket, team: :general)
    end
  end
end
```

---

## Context Management

### Context API

```elixir
# Get entire context
context()

# Get specific key
get_context(:key)
get_context(:key, default_value)

# Put values
put_context(:key, value)
put_context(%{key1: val1, key2: val2})

# Update existing value
update_context(:key, fn current -> new_value end)

# Merge maps
merge_context(%{new_data: "value"})

# Delete key
delete_context(:key)

# Check existence
has_context?(:key)

# Get initial input
input()

# Get workflow ID
workflow_id()

# Get current step
current_step()

# Accumulators
init_accumulator(:events, [])
append_context(:events, new_event)
increment_context(:counter, 1)
```

---

## Wait Primitives

### Sleep

```elixir
# Sleep for duration
sleep_for(seconds: 30)
sleep_for(minutes: 5)
sleep_for(hours: 24)
sleep_for(days: 7)

# Sleep until specific time
sleep_until(~U[2025-12-25 00:00:00Z])
```

### Wait for Events

```elixir
# Wait for external event
wait_for_event("payment_confirmed", 
  timeout: minutes(5),
  filter: fn event -> event.order_id == context().order_id end
)

# Send event from outside
Durable.send_event(workflow_id, "payment_confirmed", %{
  order_id: 123,
  amount: 99.99
})
```

### Wait for Input (Human-in-the-Loop)

```elixir
# Simple input
result = wait_for_input("manager_decision", 
  timeout: days(3),
  timeout_value: :auto_reject
)

# Form input with schema
preferences = wait_for_input("equipment_preferences",
  type: :form,
  fields: [
    %{name: :laptop, type: :select, options: ["MacBook Pro", "ThinkPad"], required: true},
    %{name: :monitor, type: :select, options: ["Single 27\"", "Dual 24\""]},
    %{name: :notes, type: :text, max_length: 500}
  ],
  timeout: days(7)
)

# Multiple choice
rating = wait_for_input("satisfaction_rating",
  type: :single_choice,
  choices: [
    %{value: 5, label: "Very Satisfied"},
    %{value: 4, label: "Satisfied"},
    %{value: 3, label: "Neutral"}
  ],
  timeout: days(14)
)

# Provide input from API/UI
Durable.provide_input(workflow_id, "manager_decision", %{
  approved: true,
  comments: "Looks good!"
})
```

---

## Automatic Log Capture

### How It Works

Every step automatically captures:
- All `Logger` calls (debug, info, warn, error)
- `IO.puts` and `IO.inspect` output
- Exception stack traces
- Step timing and duration
- Retry attempts

### Implementation

```elixir
# Custom Logger backend
defmodule Durable.LoggerBackend do
  @behaviour :gen_event
  
  def handle_event({level, _gl, {Logger, msg, ts, metadata}}, state) do
    case Process.get(:workflow_context) do
      %{workflow_id: wf_id, step: step, attempt: attempt} ->
        log_entry = %{
          timestamp: format_timestamp(ts),
          level: level,
          message: IO.iodata_to_binary(msg),
          metadata: Map.new(metadata),
          workflow_id: wf_id,
          step: step,
          attempt: attempt
        }
        
        store_log(log_entry)
    end
  end
end

# IO capture via group leader
defmodule Durable.IOCapture do
  # Intercepts IO.puts/IO.inspect and stores as logs
end
```

### Viewing Logs

```elixir
# Get logs for specific step
{:ok, logs} = Durable.get_step_logs(workflow_id, step: :charge_payment)

# Get all logs for workflow
{:ok, all_logs} = Durable.get_execution_logs(workflow_id)

# Real-time log streaming
Durable.stream_logs(workflow_id)

# Logs stored in database
execution.steps
# => [
#   %StepExecution{
#     step: :charge_payment,
#     logs: [
#       %{timestamp: ~U[...], level: :info, message: "Attempting payment"},
#       %{timestamp: ~U[...], level: :error, message: "Payment failed"}
#     ]
#   }
# ]
```

---

## Execution & Retry Logic

### Step Executor with Retries

```elixir
step :charge_payment, 
  retry: [
    max_attempts: 3,
    backoff: :exponential,  # or :linear, :constant
    backoff_base: 2,
    max_backoff: 3600  # 1 hour max
  ],
  timeout: minutes(2),
  compensate: :refund_charge do
  
  PaymentService.charge(context().order)
end
```

### Backoff Strategies

- **Exponential**: `delay = base ^ attempt * 1000ms`
  - Attempt 1: 2s, Attempt 2: 4s, Attempt 3: 8s
- **Linear**: `delay = attempt * base * 1000ms`
  - Attempt 1: 2s, Attempt 2: 4s, Attempt 3: 6s
- **Constant**: Fixed delay between retries

### Compensation (Saga Pattern)

```elixir
workflow "book_travel" do
  step :book_flight, compensate: :cancel_flight do
    FlightAPI.book(input().flight)
  end
  
  step :book_hotel, compensate: :cancel_hotel do
    HotelAPI.book(context().hotel)
  end
  
  step :charge_customer do
    case PaymentService.charge(context().total) do
      {:ok, charge} -> {:ok, charge}
      {:error, reason} -> 
        # Automatically triggers compensations in reverse
        {:error, reason}
    end
  end
end

# Compensation functions
defp cancel_flight(_state) do
  FlightAPI.cancel(state().flight_booking)
end

defp cancel_hotel(_state) do
  HotelAPI.cancel(state().hotel_booking)
end
```

---

## Queue System (Pluggable)

### Queue Adapter Behavior

```elixir
defmodule Durable.Queue.Adapter do
  @callback enqueue(job()) :: :ok | {:error, term()}
  @callback fetch_jobs(queue :: atom(), limit :: integer()) :: [job()]
  @callback ack(job_id :: String.t()) :: :ok
  @callback nack(job_id :: String.t(), reason :: term()) :: :ok
  @callback reschedule(job_id :: String.t(), delay_ms :: integer()) :: :ok
end
```

### Built-in Adapters

1. **PostgreSQL** (default) - Advisory locks + polling
2. **Redis** - Sorted sets with priorities
3. **RabbitMQ** - Priority queues
4. **Kafka** - Topic-based
5. **NATS** - JetStream

### Configuration

```elixir
# config/config.exs
config :durable_workflow,
  # Default: PostgreSQL
  queue_adapter: Durable.Queue.PostgresAdapter,
  queue_adapter_opts: [repo: MyApp.Repo],
  
  # Or Redis
  # queue_adapter: Durable.Queue.RedisAdapter,
  # queue_adapter_opts: [host: "localhost", port: 6379],
  
  # Or RabbitMQ
  # queue_adapter: Durable.Queue.RabbitMQAdapter,
  # queue_adapter_opts: [url: "amqp://guest:guest@localhost"],
  
  queues: %{
    default: [concurrency: 10],
    high_priority: [concurrency: 20],
    background: [concurrency: 5]
  }
```

### Usage

```elixir
# Start workflow with queue options
{:ok, workflow_id} = Durable.start(
  OrderWorkflow,
  %{order_id: 123},
  queue: :high_priority,
  priority: 10,
  scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second)
)

# Queue operations
Durable.Queue.pause(:low_priority)
Durable.Queue.resume(:low_priority)
Durable.Queue.get_stats(:default)
# => %{running: 7, pending: 23, concurrency: 10}
```

---

## Cron Scheduling

### Decorator Syntax (Recommended)

```elixir
defmodule ReportWorkflow do
  use Durable
  use Durable.Cron
  
  # Daily report at 9 AM
  @cron "0 9 * * *"
  @cron_queue :reports
  @cron_input %{type: :daily}
  @cron_timezone "America/New_York"
  workflow "daily_report" do
    step :generate_report do
      ReportService.generate(input().type)
    end
  end
  
  # Every hour
  @cron "0 * * * *"
  workflow "hourly_sync" do
    step :sync_data do
      DataService.sync()
    end
  end
  
  # Every 15 minutes
  @cron "*/15 * * * *"
  workflow "health_check" do
    step :check_services do
      HealthCheckService.check_all()
    end
  end
end

# Auto-register on app start
MyApp.ReportWorkflow.schedule_all_crons()
```

### Manual Scheduling (Alternative)

```elixir
Durable.Scheduler.schedule(
  "daily_report",
  ReportWorkflow,
  "generate_report",
  "0 9 * * *",
  input: %{type: :daily},
  queue: :reports,
  timezone: "America/New_York"
)
```

---

## Message Bus (Pluggable)

### Message Bus Behavior

```elixir
defmodule Durable.MessageBus do
  @callback publish(topic(), message()) :: :ok | {:error, term()}
  @callback subscribe(topic()) :: :ok | {:error, term()}
  @callback unsubscribe(topic()) :: :ok | {:error, term()}
end
```

### Built-in Adapters

1. **PostgreSQL pg_notify**
2. **Redis Pub/Sub**
3. **Phoenix.PubSub**
4. **RabbitMQ**
5. **In-Memory** (testing)

### Configuration

```elixir
# config/config.exs
config :durable_workflow,
  # PostgreSQL pg_notify (default)
  message_bus: Durable.MessageBus.PostgresAdapter,
  message_bus_opts: [repo: MyApp.Repo]
  
  # Or Redis
  # message_bus: Durable.MessageBus.RedisAdapter,
  # message_bus_opts: [host: "localhost", port: 6379]
  
  # Or Phoenix PubSub
  # message_bus: Durable.MessageBus.PhoenixPubSubAdapter,
  # message_bus_opts: [name: MyApp.PubSub]
```

### Usage

```elixir
# Subscribe to workflow events
Durable.Events.subscribe_workflow(workflow_id)

# Receive real-time updates
receive do
  {:workflow_event, %{event: :step_started, step: :charge_payment}} ->
    # Update UI
end

# Publish custom events
Durable.Events.publish_workflow_event(workflow_id, :custom_event, %{data: "..."})
```

---

## Graph Visualization

### Graph Generation

```elixir
# Generate graph from workflow definition
{:ok, graph} = Durable.Graph.generate(OrderWorkflow, "process_order")

graph
# => %{
#   nodes: [
#     %{id: "start", type: :start, label: "Start", position: %{x: 0, y: 0}},
#     %{id: "validate_inventory", type: :step, label: "Validate Inventory", position: %{x: 0, y: 80}},
#     %{id: "decision_check_value", type: :decision, label: "Check Value", position: %{x: 0, y: 160}},
#     ...
#   ],
#   edges: [
#     %{from: "start", to: "validate_inventory", label: nil},
#     %{from: "validate_inventory", to: "decision_check_value", label: nil},
#     ...
#   ]
# }
```

### Real-time Execution State

```elixir
# Get graph with execution overlay
graph_with_state = Durable.Graph.ExecutionState.get_graph_with_execution(
  OrderWorkflow,
  "process_order",
  workflow_id
)

graph_with_state.nodes
# => [
#   %{
#     id: "validate_inventory",
#     type: :step,
#     execution_state: %{
#       status: :completed,
#       duration_ms: 234,
#       started_at: ~U[...],
#       completed_at: ~U[...]
#     }
#   },
#   %{
#     id: "charge_payment",
#     type: :step,
#     execution_state: %{
#       status: :running,
#       progress: 45,
#       attempt: 2,
#       active: true
#     }
#   }
# ]
```

### WebSocket Real-time Updates

```elixir
# Phoenix Channel
defmodule WorkflowWeb.GraphChannel do
  use Phoenix.Channel
  
  def join("workflow:graph:" <> workflow_id, _params, socket) do
    Durable.Events.subscribe_workflow(workflow_id)
    {:ok, assign(socket, :workflow_id, workflow_id)}
  end
  
  def handle_info({:workflow_event, event}, socket) do
    # Get updated graph
    graph = get_updated_graph(socket.assigns.workflow_id)
    
    # Push to client
    push(socket, "graph:update", %{graph: graph, event: event})
    
    {:noreply, socket}
  end
end
```

### Export Formats

```elixir
# DOT (Graphviz)
dot = Durable.Graph.Export.to_dot(graph)

# Mermaid
mermaid = Durable.Graph.Export.to_mermaid(graph)

# Cytoscape.js
cytoscape = Durable.Graph.Export.to_cytoscape(graph)
```

---

## Database Schema

### Core Tables

```elixir
# workflow_executions
create table(:workflow_executions) do
  add :workflow_id, :string, null: false
  add :workflow_module, :string, null: false
  add :workflow_name, :string, null: false
  add :status, :string  # pending, running, waiting, completed, failed, cancelled
  add :queue, :string
  add :priority, :integer
  add :input, :map
  add :context, :map
  add :current_step, :string
  add :error, :map
  add :scheduled_at, :utc_datetime_usec
  add :started_at, :utc_datetime_usec
  add :completed_at, :utc_datetime_usec
  timestamps()
end

# step_executions (with logs)
create table(:step_executions) do
  add :workflow_id, :string
  add :step, :string
  add :attempt, :integer
  add :status, :string  # running, completed, failed, waiting
  add :started_at, :utc_datetime_usec
  add :completed_at, :utc_datetime_usec
  add :duration_ms, :integer
  add :input, :map
  add :output, :map
  add :error, :map
  add :logs, :jsonb  # Array of log entries
  timestamps()
end

# pending_inputs (for human-in-the-loop)
create table(:pending_inputs) do
  add :workflow_id, :string
  add :input_name, :string
  add :step_name, :string
  add :type, :string  # form, single_choice, multi_choice
  add :prompt, :text
  add :schema, :map
  add :fields, :jsonb
  add :status, :string  # pending, completed, timeout
  add :response, :jsonb
  add :timeout_at, :utc_datetime_usec
  add :completed_at, :utc_datetime_usec
  timestamps()
end

# scheduled_workflows (cron)
create table(:scheduled_workflows) do
  add :name, :string
  add :workflow_module, :string
  add :workflow_name, :string
  add :cron_expression, :string
  add :input, :map
  add :queue, :string
  add :enabled, :boolean
  add :last_run_at, :utc_datetime_usec
  add :next_run_at, :utc_datetime_usec
  timestamps()
end
```

---

## API Reference

### Starting Workflows

```elixir
# Basic
{:ok, workflow_id} = Durable.start(
  OrderWorkflow,
  %{order_id: 123}
)

# With options
{:ok, workflow_id} = Durable.start(
  OrderWorkflow,
  %{order_id: 123},
  workflow: "process_order",
  queue: :high_priority,
  priority: 10,
  scheduled_at: ~U[2025-12-25 00:00:00Z]
)
```

### Querying Executions

```elixir
# Get execution
{:ok, execution} = Durable.get_execution(workflow_id)
{:ok, execution} = Durable.get_execution(workflow_id, include_logs: true)

# List executions
executions = Durable.list_executions(
  workflow: OrderWorkflow,
  status: :running,
  limit: 50
)

# Query with filters
executions = Durable.Query.find_executions(
  workflow: OrderWorkflow,
  current_step: :charge_payment,
  status: :running,
  time_range: [from: ~U[2025-01-01 00:00:00Z], to: DateTime.utc_now()]
)

# Get metrics
metrics = Durable.get_metrics(
  OrderWorkflow,
  period: :last_24_hours
)
# => %{
#   total_executions: 1234,
#   successful: 1180,
#   failed: 54,
#   success_rate: 0.956,
#   avg_duration_ms: 2340,
#   p95_duration_ms: 4500
# }
```

### Controlling Workflows

```elixir
# Resume from waiting
Durable.resume(workflow_id, %{additional_data: "..."})

# Cancel
Durable.cancel(workflow_id, :user_cancelled)

# Provide input
Durable.provide_input(workflow_id, "manager_decision", %{
  approved: true,
  comments: "Approved"
})

# Send event
Durable.send_event(workflow_id, "payment_confirmed", %{
  payment_id: "pay_123"
})
```

---

## Example: Document Ingestion Pipeline

Complete real-world example showing all features:

```elixir
defmodule DocumentIngestionWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait
  use Durable.Cron
  
  # Discovery runs every minute
  @cron "* * * * *"
  @cron_queue :discovery
  workflow "discover_financial_news" do
    step :fetch_from_sources do
      # Fetch from multiple sources
      articles = fetch_articles_from_all_sources()
      put_context(:discovered_articles, articles)
    end
    
    step :deduplicate do
      articles = get_context(:discovered_articles)
      new_articles = filter_new_articles(articles)
      put_context(:new_articles, new_articles)
    end
    
    step :enqueue_processing do
      articles = get_context(:new_articles)
      
      Enum.each(articles, fn article ->
        Durable.start(__MODULE__, %{article: article},
          workflow: "process_article",
          queue: :article_processing
        )
      end)
    end
  end
  
  # Process individual article
  workflow "process_article", timeout: minutes(30) do
    step :validate_article do
      put_context(:article, input().article)
    end
    
    # Scrape if needed
    decision :needs_scraping do
      if String.length(context().article.content) < 500 do
        :needs_scraping
      else
        :has_content
      end
    end
    
    on_decision :needs_scraping do
      when_result :needs_scraping do
        step :scrape_content, retry: [max_attempts: 3] do
          {:ok, content} = ScraperAPI.scrape(context().article.url)
          update_context(:article, &Map.put(&1, :content, content))
        end
      end
    end
    
    step :convert_to_markdown do
      markdown = HTMLToMarkdown.convert(context().article.content)
      put_context(:markdown, markdown)
    end
    
    step :insert_article, compensate: :delete_article do
      article = Repo.insert!(%Article{
        url: context().article.url,
        content: context().markdown,
        status: :raw
      })
      put_context(:article_id, article.id)
    end
    
    # Clean with LLM
    step :clean_with_llm, retry: [max_attempts: 3] do
      {:ok, cleaned} = LLMService.clean_content(context().markdown)
      put_context(:cleaned_content, cleaned)
    end
    
    # Parallel: Generate embeddings + analyze
    parallel do
      step :generate_embeddings, queue: :embeddings do
        {:ok, embeddings} = EmbeddingService.generate(context().cleaned_content)
        ArticleEmbedding.insert!(article_id: context().article_id, vector: embeddings)
      end
      
      step :analyze_article, queue: :analysis do
        {:ok, analysis} = LLMService.analyze(context().cleaned_content)
        put_context(:analysis, analysis)
      end
    end
    
    step :generate_analysis_embeddings, queue: :embeddings do
      {:ok, embeddings} = EmbeddingService.generate(context().analysis)
      ArticleEmbedding.insert!(article_id: context().article_id, 
        type: :analysis, vector: embeddings)
    end
    
    step :create_timeline_entry do
      TimelineEntry.create_from_analysis(
        context().article_id,
        context().analysis
      )
    end
    
    step :mark_complete do
      Repo.update!(Article, context().article_id, status: :completed)
    end
  end
end
```

Benefits:
- ✅ Single source of truth
- ✅ Full observability with graph
- ✅ See exactly where each article is
- ✅ Automatic retries per step
- ✅ Real-time monitoring
- ✅ Easy debugging with logs
- ✅ No scattered Oban jobs!

---

## Development Roadmap

### Phase 1: Core (MVP)
- [x] DSL with macros
- [x] Basic workflow execution
- [x] Context management
- [x] Step retry logic
- [x] PostgreSQL queue adapter
- [x] Database schema

### Phase 2: Observability
- [ ] Logger backend for log capture
- [ ] IO capture via group leader
- [ ] Graph generation
- [ ] Real-time graph updates
- [ ] Phoenix LiveView dashboard

### Phase 3: Advanced Features
- [ ] Wait primitives (sleep, wait_for_event, wait_for_input)
- [ ] Decision steps
- [ ] Loops and iterations
- [ ] Parallel execution
- [ ] Compensation/saga
- [ ] Cron scheduling

### Phase 4: Scalability
- [ ] Redis queue adapter
- [ ] RabbitMQ queue adapter
- [ ] Redis message bus adapter
- [ ] Horizontal scaling support

### Phase 5: Developer Experience
- [ ] CLI tools
- [ ] Mix tasks
- [ ] Testing helpers
- [ ] Documentation site
- [ ] Example projects

---

## Testing Strategy

```elixir
# Use in-memory adapters for testing
defmodule MyApp.WorkflowTest do
  use Durable.TestCase  # Sets up in-memory adapters
  
  test "order workflow processes successfully" do
    {:ok, workflow_id} = Durable.start(
      OrderWorkflow,
      %{order_id: 123}
    )
    
    # Wait for completion
    assert_workflow_completed(workflow_id, timeout: 5_000)
    
    # Check results
    {:ok, execution} = Durable.get_execution(workflow_id)
    assert execution.status == :completed
    assert execution.context.charge_id
  end
  
  test "workflow retries on failure" do
    # Mock service to fail twice
    mock_service_failures(PaymentService, :charge, 2)
    
    {:ok, workflow_id} = Durable.start(OrderWorkflow, %{order_id: 123})
    
    assert_workflow_completed(workflow_id)
    
    # Check retry count
    {:ok, execution} = Durable.get_execution(workflow_id)
    step = find_step(execution, :charge_payment)
    assert step.attempt == 3
  end
end
```

---

## Performance Considerations

1. **Database Indexing**: Proper indexes on workflow_executions and step_executions
2. **Log Storage**: Use JSONB with GIN indexes for efficient log queries
3. **Queue Polling**: Configurable poll intervals, use pg_notify for instant wake-up
4. **Connection Pooling**: Separate pools for queue polling vs workflow execution
5. **Horizontal Scaling**: Multiple queue workers can process different queues
6. **Cleanup Jobs**: Periodic cleanup of old completed workflows

---

## Configuration Reference

```elixir
# config/config.exs
config :durable_workflow,
  # Queue adapter
  queue_adapter: Durable.Queue.PostgresAdapter,
  queue_adapter_opts: [repo: MyApp.Repo],
  
  # Queues
  queues: %{
    default: [concurrency: 10],
    high_priority: [concurrency: 20],
    background: [concurrency: 5]
  },
  
  # Message bus
  message_bus: Durable.MessageBus.PostgresAdapter,
  message_bus_opts: [repo: MyApp.Repo],
  
  # Scheduler
  scheduler: [
    enabled: true,
    timezone: "America/New_York"
  ],
  
  # Retention
  retention: [
    completed: [days: 30],
    failed: [days: 90]
  ]
```

---

This project document contains all the key architectural decisions, implementation details, and examples from our discussion. You can add this to Claude Projects for easy reference!