# DurableWorkflow Implementation Plan

## Executive Summary

This document outlines the complete implementation plan for **Durable**, a durable, resumable workflow engine for Elixir.

**Current State:** ~45% implemented (Phase 0+1 complete, partial Phase 2+3+5)
**Target:** Production-ready workflow engine replacing Oban

### Completed Features (as of Jan 2025)
- Phase 0: Project foundation, database schema, migrations ✅
- Phase 1: Core MVP (DSL, context, executor, retry, queue, worker) ✅
- Phase 2.1-2.2: Log capture (Logger backend, IO capture) ✅
- Phase 3.1-3.3: Wait primitives (sleep, events, human input) ✅
- Phase 3.4: Conditional branching (`branch` macro, `decision` legacy) ✅
- Phase 5 (partial): Query API, time helpers, test DataCase ✅

**Stats:** 25+ modules, 80 passing tests

---

## Phase 0: Project Foundation

### Milestone 0.1: Project Scaffolding

**Objective:** Create the basic Elixir project structure with all necessary configuration.

**Deliverables:**

1. **mix.exs Configuration**
   - Project name: `durable_workflow`
   - Elixir version: ~> 1.15
   - Core dependencies:
     ```elixir
     {:ecto_sql, "~> 3.11"}
     {:postgrex, "~> 0.17"}
     {:jason, "~> 1.4"}
     {:telemetry, "~> 1.2"}
     {:nimble_options, "~> 1.1"}  # For option validation
     {:crontab, "~> 1.1"}  # For cron parsing
     {:ex_doc, "~> 0.31", only: :dev}
     {:dialyxir, "~> 1.4", only: [:dev, :test]}
     {:credo, "~> 1.7", only: [:dev, :test]}
   ```

2. **Directory Structure**
   ```
   lib/
   ├── durable_workflow.ex                    # Main API module
   ├── durable_workflow/
   │   ├── application.ex                     # OTP Application
   │   ├── dsl/                               # DSL & Macros
   │   │   ├── workflow.ex
   │   │   ├── step.ex
   │   │   ├── decision.ex
   │   │   ├── parallel.ex
   │   │   ├── loop.ex
   │   │   ├── foreach.ex
   │   │   └── switch.ex
   │   ├── context.ex                         # Context management
   │   ├── wait.ex                            # Wait primitives
   │   ├── executor/                          # Execution engine
   │   │   ├── executor.ex                    # Main executor GenServer
   │   │   ├── step_executor.ex               # Step execution with retries
   │   │   └── backoff.ex                     # Backoff strategies
   │   ├── queue/                             # Queue system
   │   │   ├── adapter.ex                     # Behaviour definition
   │   │   ├── manager.ex                     # Queue manager
   │   │   └── adapters/
   │   │       ├── postgres.ex
   │   │       ├── redis.ex
   │   │       └── rabbitmq.ex
   │   ├── message_bus/                       # Message bus
   │   │   ├── adapter.ex
   │   │   └── adapters/
   │   │       ├── postgres.ex
   │   │       ├── redis.ex
   │   │       └── phoenix_pubsub.ex
   │   ├── scheduler/                         # Cron scheduling
   │   │   ├── scheduler.ex
   │   │   └── cron.ex
   │   ├── log_capture/                       # Log capture
   │   │   ├── logger_backend.ex
   │   │   └── io_capture.ex
   │   ├── graph/                             # Graph visualization
   │   │   ├── generator.ex
   │   │   ├── layout.ex
   │   │   ├── execution_state.ex
   │   │   └── export/
   │   │       ├── dot.ex
   │   │       ├── mermaid.ex
   │   │       └── cytoscape.ex
   │   ├── storage/                           # Database layer
   │   │   ├── repo.ex
   │   │   └── schemas/
   │   │       ├── workflow_execution.ex
   │   │       ├── step_execution.ex
   │   │       ├── pending_input.ex
   │   │       └── scheduled_workflow.ex
   │   ├── telemetry.ex                       # Telemetry events
   │   └── config.ex                          # Configuration
   test/
   ├── test_helper.exs
   ├── support/
   │   ├── test_case.ex                       # Test helpers
   │   └── fixtures.ex
   └── durable_workflow/
       └── ...                                # Mirrored test structure
   priv/
   └── repo/
       └── migrations/
   config/
   ├── config.exs
   ├── dev.exs
   ├── test.exs
   └── prod.exs
   ```

3. **Configuration Files**
   - `config/config.exs` - Base configuration
   - `config/dev.exs` - Development settings
   - `config/test.exs` - Test settings with in-memory adapters
   - `config/runtime.exs` - Runtime configuration
   - `.formatter.exs` - Code formatting
   - `.credo.exs` - Static analysis

4. **CI/CD Setup**
   - `.github/workflows/ci.yml` - GitHub Actions for tests, formatting, dialyzer
   - `.tool-versions` - asdf version management

**Success Criteria:** ✅ COMPLETE
- [x] `mix compile` succeeds
- [x] `mix test` runs (24 passing tests)
- [x] `mix format --check-formatted` passes
- [x] `mix credo` passes
- [x] `mix dialyzer` passes

---

### Milestone 0.2: Database Schema & Migrations ✅ COMPLETE

**Objective:** Create Ecto schemas and migrations for all core tables.

**Deliverables:**

1. **Migration: Create workflow_executions table**
   ```elixir
   # priv/repo/migrations/xxx_create_workflow_executions.exs
   create table(:workflow_executions, primary_key: false) do
     add :id, :uuid, primary_key: true
     add :workflow_module, :string, null: false
     add :workflow_name, :string, null: false
     add :status, :string, null: false, default: "pending"
     add :queue, :string, null: false, default: "default"
     add :priority, :integer, null: false, default: 0
     add :input, :map, null: false, default: %{}
     add :context, :map, null: false, default: %{}
     add :current_step, :string
     add :error, :map
     add :parent_workflow_id, references(:workflow_executions, type: :uuid)
     add :scheduled_at, :utc_datetime_usec
     add :started_at, :utc_datetime_usec
     add :completed_at, :utc_datetime_usec
     add :locked_by, :string
     add :locked_at, :utc_datetime_usec
     timestamps(type: :utc_datetime_usec)
   end

   create index(:workflow_executions, [:status])
   create index(:workflow_executions, [:queue, :status, :priority, :scheduled_at])
   create index(:workflow_executions, [:workflow_module, :status])
   create index(:workflow_executions, [:locked_by, :locked_at])
   ```

2. **Migration: Create step_executions table**
   ```elixir
   # With JSONB for logs and GIN index for efficient querying
   create table(:step_executions, primary_key: false) do
     add :id, :uuid, primary_key: true
     add :workflow_id, references(:workflow_executions, type: :uuid), null: false
     add :step_name, :string, null: false
     add :step_type, :string, null: false  # step, decision, parallel, etc.
     add :attempt, :integer, null: false, default: 1
     add :status, :string, null: false, default: "pending"
     add :input, :map
     add :output, :map
     add :error, :map
     add :logs, :jsonb, null: false, default: "[]"
     add :started_at, :utc_datetime_usec
     add :completed_at, :utc_datetime_usec
     add :duration_ms, :integer
     timestamps(type: :utc_datetime_usec)
   end

   create index(:step_executions, [:workflow_id, :step_name])
   create index(:step_executions, [:workflow_id, :status])
   execute "CREATE INDEX step_executions_logs_gin ON step_executions USING GIN (logs)"
   ```

3. **Migration: Create pending_inputs table**
   ```elixir
   create table(:pending_inputs, primary_key: false) do
     add :id, :uuid, primary_key: true
     add :workflow_id, references(:workflow_executions, type: :uuid), null: false
     add :input_name, :string, null: false
     add :step_name, :string, null: false
     add :input_type, :string, null: false  # form, single_choice, multi_choice, free_text
     add :prompt, :text
     add :schema, :map
     add :fields, :jsonb
     add :status, :string, null: false, default: "pending"
     add :response, :jsonb
     add :timeout_at, :utc_datetime_usec
     add :completed_at, :utc_datetime_usec
     timestamps(type: :utc_datetime_usec)
   end

   create index(:pending_inputs, [:workflow_id, :input_name])
   create index(:pending_inputs, [:status, :timeout_at])
   create unique_index(:pending_inputs, [:workflow_id, :input_name], where: "status = 'pending'")
   ```

4. **Migration: Create scheduled_workflows table**
   ```elixir
   create table(:scheduled_workflows, primary_key: false) do
     add :id, :uuid, primary_key: true
     add :name, :string, null: false
     add :workflow_module, :string, null: false
     add :workflow_name, :string, null: false
     add :cron_expression, :string, null: false
     add :timezone, :string, null: false, default: "UTC"
     add :input, :map, null: false, default: %{}
     add :queue, :string, null: false, default: "default"
     add :enabled, :boolean, null: false, default: true
     add :last_run_at, :utc_datetime_usec
     add :next_run_at, :utc_datetime_usec
     timestamps(type: :utc_datetime_usec)
   end

   create unique_index(:scheduled_workflows, [:name])
   create index(:scheduled_workflows, [:enabled, :next_run_at])
   ```

5. **Ecto Schemas**
   - `DurableWorkflow.Storage.Schemas.WorkflowExecution`
   - `DurableWorkflow.Storage.Schemas.StepExecution`
   - `DurableWorkflow.Storage.Schemas.PendingInput`
   - `DurableWorkflow.Storage.Schemas.ScheduledWorkflow`

**Success Criteria:**
- [ ] `mix ecto.create` succeeds
- [ ] `mix ecto.migrate` succeeds
- [ ] All schemas compile with proper types
- [ ] Basic CRUD operations work in IEx

---

## Phase 1: Core Workflow Engine (MVP) ✅ COMPLETE

### Milestone 1.1: DSL Foundation - Basic Macros ✅ COMPLETE

**Objective:** Implement the core `use DurableWorkflow` macro and basic `workflow`/`step` DSL.

**Deliverables:**

1. **DurableWorkflow Module (`lib/durable_workflow.ex`)**
   - Main API entry point
   - `__using__/1` macro that injects DSL
   - Public API functions: `start/2`, `start/3`, `get_execution/1`, `get_execution/2`

2. **DSL.Workflow (`lib/durable_workflow/dsl/workflow.ex`)**
   - `workflow/3` macro for defining workflows
   - Compile-time workflow registration
   - Workflow metadata extraction (timeout, max_retries, etc.)
   - `@before_compile` callback to generate `__workflows__/0`

3. **DSL.Step (`lib/durable_workflow/dsl/step.ex`)**
   - `step/3` macro for defining steps
   - Step options: `retry`, `timeout`, `compensate`, `queue`
   - Step metadata storage via module attributes

4. **Internal Representation**
   ```elixir
   # Generated at compile time
   %DurableWorkflow.Definition{
     module: OrderWorkflow,
     name: "process_order",
     timeout: 7200_000,  # 2 hours
     max_retries: 3,
     steps: [
       %DurableWorkflow.Step{
         name: :validate_inventory,
         type: :step,
         options: %{retry: nil, timeout: nil},
         body: fn ctx -> ... end
       },
       %DurableWorkflow.Step{
         name: :charge_payment,
         type: :step,
         options: %{
           retry: %{max_attempts: 3, backoff: :exponential},
           timeout: 120_000
         },
         body: fn ctx -> ... end
       }
     ]
   }
   ```

**Example Usage (must work):**
```elixir
defmodule MyApp.OrderWorkflow do
  use DurableWorkflow

  workflow "process_order", timeout: hours(2) do
    step :validate do
      Logger.info("Validating...")
      {:ok, :validated}
    end

    step :process, retry: [max_attempts: 3] do
      # Process logic
    end
  end
end

# Should compile and register the workflow
MyApp.OrderWorkflow.__workflows__()
# => ["process_order"]

MyApp.OrderWorkflow.__workflow_definition__("process_order")
# => %DurableWorkflow.Definition{...}
```

**Success Criteria:**
- [ ] Module compiles with `use DurableWorkflow`
- [ ] `workflow` and `step` macros work
- [ ] Workflow definitions are extractable at runtime
- [ ] Time helpers (`hours/1`, `minutes/1`, `seconds/1`) work
- [ ] Step options are properly parsed and stored
- [ ] Tests cover basic DSL functionality

---

### Milestone 1.2: Context Management ✅ COMPLETE

**Objective:** Implement the context system for state management within workflows.

**Deliverables:**

1. **DurableWorkflow.Context (`lib/durable_workflow/context.ex`)**
   - Process dictionary-based context during execution
   - `__using__/1` macro to inject context functions
   - Functions:
     ```elixir
     # Read operations
     context()                           # Get entire context
     get_context(key)                    # Get specific key
     get_context(key, default)           # Get with default
     has_context?(key)                   # Check existence

     # Write operations
     put_context(key, value)             # Set single key
     put_context(map)                    # Merge map into context
     update_context(key, fun)            # Update with function
     merge_context(map)                  # Deep merge
     delete_context(key)                 # Remove key

     # Special accessors
     input()                             # Get initial workflow input
     workflow_id()                       # Get current workflow ID
     current_step()                      # Get current step name

     # Accumulators
     init_accumulator(key, initial)      # Initialize list accumulator
     append_context(key, value)          # Append to list
     increment_context(key, amount)      # Increment number
     ```

2. **Context Persistence**
   - Context is persisted to `workflow_executions.context` after each step
   - Context is restored when workflow resumes
   - Serialization via Jason with atom key handling

3. **Context Isolation**
   - Each step execution has isolated context view
   - Parallel steps have snapshot of context at branch point
   - Context merging strategy for parallel completion

**Example Usage:**
```elixir
defmodule MyApp.OrderWorkflow do
  use DurableWorkflow
  use DurableWorkflow.Context

  workflow "process_order" do
    step :init do
      order = input().order
      put_context(:order_id, order.id)
      put_context(:items, order.items)
    end

    step :calculate_total do
      items = get_context(:items)
      total = Enum.sum(Enum.map(items, & &1.price))
      put_context(:total, total)
    end

    step :finalize do
      %{
        order_id: get_context(:order_id),
        total: get_context(:total)
      }
    end
  end
end
```

**Success Criteria:**
- [ ] All context functions work within step execution
- [ ] Context persists across step boundaries
- [ ] Context survives workflow pause/resume
- [ ] Context is properly serialized to database
- [ ] Tests cover all context operations

---

### Milestone 1.3: Basic Executor ✅ COMPLETE

**Objective:** Implement the core workflow executor that runs steps sequentially.

**Deliverables:**

1. **DurableWorkflow.Executor (`lib/durable_workflow/executor/executor.ex`)**
   - GenServer that executes workflows
   - State machine: `pending → running → completed/failed/waiting`
   - Sequential step execution
   - Context initialization and persistence
   - Basic error handling

2. **DurableWorkflow.Executor.StepExecutor (`lib/durable_workflow/executor/step_executor.ex`)**
   - Executes individual steps
   - Captures step output
   - Records timing information
   - Creates `StepExecution` records

3. **Execution Flow:**
   ```
   start(workflow_module, input, opts)
   │
   ├── Create WorkflowExecution record (status: pending)
   │
   ├── For each step in workflow:
   │   ├── Create StepExecution record (status: running)
   │   ├── Initialize context with Process.put
   │   ├── Execute step body
   │   ├── Persist context changes to DB
   │   ├── Update StepExecution (status: completed, output, duration)
   │   └── Continue to next step
   │
   └── Update WorkflowExecution (status: completed)
   ```

4. **Error Handling (Basic)**
   - Catch exceptions in step execution
   - Store error details in `StepExecution.error`
   - Mark workflow as failed
   - (Retry logic comes in Milestone 1.4)

**Example Usage:**
```elixir
# Start a workflow
{:ok, workflow_id} = DurableWorkflow.start(OrderWorkflow, %{order_id: 123})

# Query execution
{:ok, execution} = DurableWorkflow.get_execution(workflow_id)
execution.status  # => :completed
execution.context # => %{order_id: 123, total: 99.99, ...}
```

**Success Criteria:**
- [ ] Workflows execute from start to finish
- [ ] Each step creates a StepExecution record
- [ ] Context flows between steps
- [ ] Final context is persisted
- [ ] Errors are captured and stored
- [ ] Integration tests verify full flow

---

### Milestone 1.4: Retry Logic & Backoff ✅ COMPLETE

**Objective:** Implement step-level retry with configurable backoff strategies.

**Deliverables:**

1. **DurableWorkflow.Executor.Backoff (`lib/durable_workflow/executor/backoff.ex`)**
   - Backoff strategy implementations:
     ```elixir
     # Exponential: delay = base ^ attempt * 1000ms
     def exponential(attempt, opts) do
       base = Keyword.get(opts, :base, 2)
       max = Keyword.get(opts, :max_backoff, 3600_000)
       min(trunc(:math.pow(base, attempt) * 1000), max)
     end

     # Linear: delay = attempt * base * 1000ms
     def linear(attempt, opts) do
       base = Keyword.get(opts, :base, 2)
       max = Keyword.get(opts, :max_backoff, 3600_000)
       min(attempt * base * 1000, max)
     end

     # Constant: fixed delay
     def constant(_attempt, opts) do
       Keyword.get(opts, :delay, 1000)
     end
     ```

2. **Retry Logic in StepExecutor**
   ```elixir
   def execute_with_retry(step, context, retry_opts) do
     max_attempts = Keyword.get(retry_opts, :max_attempts, 1)

     Enum.reduce_while(1..max_attempts, nil, fn attempt, _acc ->
       case execute_step(step, context, attempt) do
         {:ok, result} ->
           {:halt, {:ok, result}}
         {:error, reason} when attempt < max_attempts ->
           delay = calculate_backoff(attempt, retry_opts)
           Process.sleep(delay)
           {:cont, {:error, reason}}
         {:error, reason} ->
           {:halt, {:error, reason}}
       end
     end)
   end
   ```

3. **Retry Persistence**
   - Each retry attempt creates a new StepExecution record
   - Previous attempts retained for debugging
   - Final attempt status determines step outcome

4. **Step Options Enhancement**
   ```elixir
   step :charge_payment,
     retry: [
       max_attempts: 3,
       backoff: :exponential,
       base: 2,
       max_backoff: 3600_000  # 1 hour cap
     ],
     timeout: minutes(2) do

     PaymentService.charge(context())
   end
   ```

**Success Criteria:**
- [ ] Steps retry on failure up to max_attempts
- [ ] Exponential backoff delays correctly
- [ ] Linear backoff delays correctly
- [ ] Constant backoff delays correctly
- [ ] All attempts are recorded in database
- [ ] Successful retry completes workflow
- [ ] Exhausted retries fail workflow
- [ ] Tests cover retry scenarios

---

### Milestone 1.5: PostgreSQL Queue Adapter ✅ COMPLETE

**Objective:** Implement the default PostgreSQL-based job queue.

**Deliverables:**

1. **DurableWorkflow.Queue.Adapter (`lib/durable_workflow/queue/adapter.ex`)**
   - Behaviour definition:
     ```elixir
     @callback enqueue(job :: map()) :: {:ok, job_id} | {:error, term()}
     @callback fetch_jobs(queue :: atom(), limit :: pos_integer()) :: [job()]
     @callback ack(job_id :: String.t()) :: :ok | {:error, term()}
     @callback nack(job_id :: String.t(), reason :: term()) :: :ok | {:error, term()}
     @callback reschedule(job_id :: String.t(), run_at :: DateTime.t()) :: :ok | {:error, term()}
     @callback get_stats(queue :: atom()) :: map()
     ```

2. **DurableWorkflow.Queue.Adapters.Postgres**
   - Uses `workflow_executions` table directly (no separate jobs table)
   - Advisory locks for job claiming
   - Polling with configurable interval
   - Priority-based ordering

3. **Queue Manager (`lib/durable_workflow/queue/manager.ex`)**
   - Supervises queue pollers
   - Configurable concurrency per queue
   - Queue operations: pause, resume, drain

4. **Job Claiming Algorithm:**
   ```sql
   -- Atomic job claim using advisory locks
   WITH claimable AS (
     SELECT id FROM workflow_executions
     WHERE status = 'pending'
       AND queue = $1
       AND (scheduled_at IS NULL OR scheduled_at <= NOW())
       AND (locked_by IS NULL OR locked_at < NOW() - INTERVAL '5 minutes')
     ORDER BY priority DESC, scheduled_at ASC NULLS FIRST, inserted_at ASC
     LIMIT $2
     FOR UPDATE SKIP LOCKED
   )
   UPDATE workflow_executions
   SET locked_by = $3, locked_at = NOW(), status = 'running'
   WHERE id IN (SELECT id FROM claimable)
   RETURNING *;
   ```

5. **Queue Configuration:**
   ```elixir
   config :durable_workflow,
     queue_adapter: DurableWorkflow.Queue.Adapters.Postgres,
     queues: %{
       default: [concurrency: 10, poll_interval: 1000],
       high_priority: [concurrency: 20, poll_interval: 500],
       background: [concurrency: 5, poll_interval: 5000]
     }
   ```

**Success Criteria:**
- [ ] Jobs enqueue correctly
- [ ] Jobs are claimed atomically (no duplicates)
- [ ] Priority ordering works
- [ ] Scheduled jobs wait until scheduled_at
- [ ] Stale locks are recovered
- [ ] Queue stats are accurate
- [ ] Concurrency limits respected
- [ ] Tests cover edge cases

---

### Milestone 1.6: Basic Public API ✅ COMPLETE

**Objective:** Complete the public API for starting, querying, and managing workflows.

**Deliverables:**

1. **DurableWorkflow Main Module API:**
   ```elixir
   # Starting workflows
   DurableWorkflow.start(module, input)
   DurableWorkflow.start(module, input, opts)
   # opts: workflow: name, queue: atom, priority: int, scheduled_at: DateTime

   # Querying
   DurableWorkflow.get_execution(workflow_id)
   DurableWorkflow.get_execution(workflow_id, include_steps: true, include_logs: true)
   DurableWorkflow.list_executions(filters)
   # filters: workflow: module, status: atom, queue: atom, limit: int

   # Control
   DurableWorkflow.cancel(workflow_id)
   DurableWorkflow.cancel(workflow_id, reason)
   ```

2. **DurableWorkflow.Query Module:**
   ```elixir
   DurableWorkflow.Query.find_executions(filters)
   DurableWorkflow.Query.count_executions(filters)
   DurableWorkflow.Query.get_step_executions(workflow_id)
   ```

3. **Telemetry Events:**
   ```elixir
   [:durable_workflow, :workflow, :start]
   [:durable_workflow, :workflow, :complete]
   [:durable_workflow, :workflow, :fail]
   [:durable_workflow, :step, :start]
   [:durable_workflow, :step, :complete]
   [:durable_workflow, :step, :fail]
   [:durable_workflow, :step, :retry]
   [:durable_workflow, :queue, :job_claimed]
   [:durable_workflow, :queue, :job_completed]
   ```

**Success Criteria:**
- [ ] All public API functions work correctly
- [ ] Query functions return expected results
- [ ] Telemetry events fire at correct points
- [ ] API documentation is complete
- [ ] Integration tests cover API

---

## Phase 2: Observability

### Milestone 2.1: Logger Backend for Log Capture

**Objective:** Automatically capture all Logger calls within workflow steps.

**Deliverables:**

1. **DurableWorkflow.LogCapture.LoggerBackend**
   - Custom `:gen_event` handler for Logger
   - Captures logs tagged with workflow context
   - Buffers logs during step execution
   - Flushes to StepExecution.logs on step completion

2. **Implementation:**
   ```elixir
   defmodule DurableWorkflow.LogCapture.LoggerBackend do
     @behaviour :gen_event

     def handle_event({level, _gl, {Logger, msg, ts, metadata}}, state) do
       case Process.get(:durable_workflow_context) do
         %{workflow_id: wf_id, step: step, attempt: attempt} ->
           log_entry = %{
             timestamp: format_timestamp(ts),
             level: level,
             message: IO.iodata_to_binary(msg),
             metadata: filter_metadata(metadata)
           }

           # Store in process dictionary buffer
           logs = Process.get(:durable_workflow_logs, [])
           Process.put(:durable_workflow_logs, [log_entry | logs])

         _ ->
           :ok  # Not in workflow context, ignore
       end
       {:ok, state}
     end
   end
   ```

3. **Log Storage:**
   - Logs stored as JSONB array in `step_executions.logs`
   - Efficient querying via GIN index
   - Log levels: debug, info, warn, error

4. **Configuration:**
   ```elixir
   # In application start
   Logger.add_backend(DurableWorkflow.LogCapture.LoggerBackend)

   config :durable_workflow,
     log_capture: [
       enabled: true,
       levels: [:info, :warn, :error],  # Levels to capture
       max_logs_per_step: 1000
     ]
   ```

**Success Criteria:**
- [ ] Logger.info/warn/error captured within steps
- [ ] Logs include timestamp, level, message
- [ ] Logs are stored per-step with attempt tracking
- [ ] Performance impact is minimal
- [ ] Tests verify log capture

---

### Milestone 2.2: IO Capture

**Objective:** Capture `IO.puts` and `IO.inspect` output within workflow steps.

**Deliverables:**

1. **DurableWorkflow.LogCapture.IOCapture**
   - Group leader replacement during step execution
   - Intercepts IO operations
   - Converts to log entries

2. **Implementation:**
   ```elixir
   defmodule DurableWorkflow.LogCapture.IOCapture do
     def with_capture(fun) do
       original_gl = Process.group_leader()
       {:ok, capture_pid} = StringIO.open("")

       try do
         Process.group_leader(self(), capture_pid)
         result = fun.()
         {result, get_captured_output(capture_pid)}
       after
         Process.group_leader(self(), original_gl)
         StringIO.close(capture_pid)
       end
     end
   end
   ```

3. **Integration with Step Executor:**
   - Wrap step execution with IO capture
   - Convert captured output to log entries
   - Merge with Logger-captured logs

**Success Criteria:**
- [ ] IO.puts output captured
- [ ] IO.inspect output captured
- [ ] Output stored as log entries
- [ ] Original IO restored after step
- [ ] No interference with Logger

---

### Milestone 2.3: Graph Generation

**Objective:** Generate visual graph representation from workflow definitions.

**Deliverables:**

1. **DurableWorkflow.Graph.Generator**
   - Parse workflow definition into graph nodes/edges
   - Handle all step types (step, decision, parallel, loop, foreach, switch)
   - Generate unique node IDs

2. **Graph Data Structure:**
   ```elixir
   %DurableWorkflow.Graph{
     nodes: [
       %{id: "start", type: :start, label: "Start"},
       %{id: "validate_inventory", type: :step, label: "Validate Inventory"},
       %{id: "decision_check_value", type: :decision, label: "Check Value"},
       %{id: "end", type: :end, label: "End"}
     ],
     edges: [
       %{from: "start", to: "validate_inventory"},
       %{from: "validate_inventory", to: "decision_check_value"},
       %{from: "decision_check_value", to: "high_value_branch", label: "high_value"},
       %{from: "decision_check_value", to: "standard_branch", label: "standard"}
     ]
   }
   ```

3. **DurableWorkflow.Graph.Layout**
   - Automatic node positioning
   - Hierarchical layout for sequential flows
   - Horizontal expansion for parallel branches

4. **API:**
   ```elixir
   {:ok, graph} = DurableWorkflow.Graph.generate(OrderWorkflow, "process_order")
   ```

**Success Criteria:**
- [ ] Graph generated from workflow definition
- [ ] All step types represented correctly
- [ ] Edges connect steps properly
- [ ] Decision branches labeled
- [ ] Layout positions calculated

---

### Milestone 2.4: Graph Export Formats

**Objective:** Export graphs to DOT (Graphviz), Mermaid, and Cytoscape.js formats.

**Deliverables:**

1. **DurableWorkflow.Graph.Export.Dot**
   ```elixir
   def to_dot(graph) do
     """
     digraph workflow {
       node [shape=box];
       #{Enum.map_join(graph.nodes, "\n  ", &node_to_dot/1)}
       #{Enum.map_join(graph.edges, "\n  ", &edge_to_dot/1)}
     }
     """
   end
   ```

2. **DurableWorkflow.Graph.Export.Mermaid**
   ```elixir
   def to_mermaid(graph) do
     """
     graph TD
       #{Enum.map_join(graph.nodes, "\n  ", &node_to_mermaid/1)}
       #{Enum.map_join(graph.edges, "\n  ", &edge_to_mermaid/1)}
     """
   end
   ```

3. **DurableWorkflow.Graph.Export.Cytoscape**
   - JSON format for Cytoscape.js
   - Includes position data for nodes

**Success Criteria:**
- [ ] DOT export renders in Graphviz
- [ ] Mermaid export renders in Mermaid Live
- [ ] Cytoscape JSON works with Cytoscape.js
- [ ] All node types styled appropriately

---

### Milestone 2.5: Real-time Execution State

**Objective:** Overlay execution state on workflow graphs.

**Deliverables:**

1. **DurableWorkflow.Graph.ExecutionState**
   ```elixir
   def get_graph_with_execution(module, workflow_name, workflow_id) do
     graph = DurableWorkflow.Graph.generate(module, workflow_name)
     execution = DurableWorkflow.get_execution(workflow_id, include_steps: true)

     nodes_with_state = Enum.map(graph.nodes, fn node ->
       step_exec = find_step_execution(execution.steps, node.id)
       Map.put(node, :execution_state, step_exec_to_state(step_exec))
     end)

     %{graph | nodes: nodes_with_state}
   end
   ```

2. **Execution State Structure:**
   ```elixir
   %{
     status: :completed | :running | :failed | :pending | :waiting,
     attempt: 1,
     duration_ms: 234,
     started_at: ~U[...],
     completed_at: ~U[...],
     error: nil | %{message: "...", type: "..."}
   }
   ```

3. **Real-time Updates via Message Bus**
   - Subscribe to workflow events
   - Push graph updates on step transitions

**Success Criteria:**
- [ ] Graph reflects current execution state
- [ ] Running steps highlighted
- [ ] Completed steps show duration
- [ ] Failed steps show error
- [ ] State updates in real-time

---

### Milestone 2.6: Phoenix LiveView Dashboard (Optional)

**Objective:** Create an optional Phoenix LiveView dashboard for workflow monitoring.

**Deliverables:**

1. **Separate Hex package: `durable_workflow_dashboard`**

2. **Dashboard Components:**
   - Workflow list with filtering
   - Individual workflow detail view
   - Real-time graph visualization
   - Step logs viewer
   - Queue statistics

3. **LiveView Components:**
   - `DurableWorkflowDashboard.WorkflowListLive`
   - `DurableWorkflowDashboard.WorkflowDetailLive`
   - `DurableWorkflowDashboard.GraphLive`
   - `DurableWorkflowDashboard.LogsLive`

4. **Integration:**
   ```elixir
   # In router.ex
   import DurableWorkflowDashboard.Router

   scope "/" do
     pipe_through :browser
     durable_workflow_dashboard "/workflows"
   end
   ```

**Success Criteria:**
- [ ] Dashboard installable as separate package
- [ ] List view shows all workflows
- [ ] Detail view shows execution state
- [ ] Graph renders with execution overlay
- [ ] Logs viewable per step
- [ ] Real-time updates work

---

## Phase 3: Advanced Features (Partial)

### Milestone 3.1: Wait Primitives - Sleep ✅ COMPLETE

**Objective:** Implement `sleep_for` and `sleep_until` functions.

**Deliverables:**

1. **DurableWorkflow.Wait Module**
   ```elixir
   use DurableWorkflow.Wait

   # Sleep for duration
   sleep_for(seconds: 30)
   sleep_for(minutes: 5)
   sleep_for(hours: 24)
   sleep_for(days: 7)

   # Sleep until specific time
   sleep_until(~U[2025-12-25 00:00:00Z])
   ```

2. **Implementation:**
   - Sleep suspends workflow execution
   - Workflow status changes to `waiting`
   - `scheduled_at` set to wake time
   - Queue poller picks up when time arrives

3. **Execution Flow:**
   ```
   step calls sleep_for(minutes: 5)
   │
   ├── Throw {:sleep, wake_at: DateTime}
   │
   ├── Executor catches signal
   │   ├── Update workflow: status = waiting, scheduled_at = wake_at
   │   ├── Save current step progress
   │   └── Release execution
   │
   └── Queue poller picks up when scheduled_at passes
       └── Resume execution from saved step
   ```

**Success Criteria:**
- [x] sleep_for suspends workflow
- [x] Workflow resumes after duration
- [x] sleep_until works with DateTime
- [x] State preserved across sleep
- [x] Tests verify timing

---

### Milestone 3.2: Wait Primitives - Events ✅ COMPLETE

**Objective:** Implement `wait_for_event` and `send_event` for external event handling.

**Deliverables:**

1. **Event Waiting:**
   ```elixir
   # Wait for external event
   result = wait_for_event("payment_confirmed",
     timeout: minutes(5),
     filter: fn event -> event.order_id == get_context(:order_id) end
   )
   ```

2. **Event Sending:**
   ```elixir
   DurableWorkflow.send_event(workflow_id, "payment_confirmed", %{
     order_id: 123,
     amount: 99.99
   })
   ```

3. **Implementation:**
   - Event waiting suspends workflow (status: `waiting`)
   - Pending event stored in `pending_inputs` table with type: `event`
   - `send_event` matches waiting workflows
   - Filter function evaluated against event payload
   - Timeout handling with timeout_value

4. **Database Changes:**
   - Add `event_name` and `event_filter` columns to pending_inputs
   - Or create separate `pending_events` table

**Success Criteria:**
- [x] wait_for_event suspends workflow
- [x] send_event resumes matching workflow
- [x] Filter function works correctly
- [x] Timeout triggers with timeout_value
- [x] Multiple workflows can wait for same event

---

### Milestone 3.3: Wait Primitives - Human Input ✅ COMPLETE

**Objective:** Implement `wait_for_input` for human-in-the-loop workflows.

**Deliverables:**

1. **Input Types:**
   ```elixir
   # Simple approval
   result = wait_for_input("manager_approval",
     timeout: days(3),
     timeout_value: :auto_reject
   )

   # Form input
   preferences = wait_for_input("equipment_preferences",
     type: :form,
     fields: [
       %{name: :laptop, type: :select, options: ["MacBook", "ThinkPad"], required: true},
       %{name: :notes, type: :text, max_length: 500}
     ],
     timeout: days(7)
   )

   # Single choice
   rating = wait_for_input("satisfaction",
     type: :single_choice,
     choices: [
       %{value: 5, label: "Excellent"},
       %{value: 4, label: "Good"},
       %{value: 3, label: "Average"}
     ]
   )
   ```

2. **Providing Input:**
   ```elixir
   DurableWorkflow.provide_input(workflow_id, "manager_approval", %{
     approved: true,
     comments: "Looks good!"
   })
   ```

3. **Querying Pending Inputs:**
   ```elixir
   DurableWorkflow.list_pending_inputs(
     workflow: OrderWorkflow,
     status: :pending,
     timeout_before: DateTime.utc_now()
   )
   ```

4. **Validation:**
   - Validate input against field schema
   - Required field checking
   - Type coercion

**Success Criteria:**
- [x] wait_for_input suspends workflow
- [x] provide_input resumes with data
- [x] Form validation works
- [x] Timeout handling works
- [x] Pending inputs queryable

---

### Milestone 3.4: Conditional Branching ✅ COMPLETE

**Objective:** Implement conditional branching for workflow flow control.

**Implemented Features:**

1. **Branch Macro (Primary - New DSL):**
   ```elixir
   branch on: get_context(:doc_type) do
     :invoice ->
       step :extract_invoice do
         AI.extract(get_context(:content), schema: :invoice)
       end

       step :validate_invoice do
         validate_totals(get_context(:extracted))
       end

     :contract ->
       step :extract_contract do
         AI.extract(get_context(:content), schema: :contract)
       end

     _ ->
       step :manual_review do
         wait_for_input("classification", timeout: hours(24))
       end
   end
   ```

2. **Decision Macro (Legacy):**
   ```elixir
   decision :check_amount do
     if get_context(:amount) > 1000 do
       {:goto, :manager_approval}
     else
       {:goto, :auto_approve}
     end
   end

   step :auto_approve do ... end
   step :manager_approval do ... end
   ```

3. **Implementation Details:**
   - `branch` macro parses case-like clause syntax at macro expansion time
   - Steps inside branches get qualified names: `:branch_<id>__<clause>__<step_name>`
   - Executor evaluates condition and executes only matching clause's steps
   - Supports pattern matching on atoms, strings, integers, booleans
   - Default clause with `_` wildcard
   - Multiple steps per branch
   - Execution continues after branch block

4. **Files Modified:**
   - `lib/durable/dsl/step.ex` - Added `branch` macro with AST parsing
   - `lib/durable/definition.ex` - Added `:branch` step type
   - `lib/durable/executor.ex` - Added branch execution logic

**Success Criteria:**
- [x] `branch` macro compiles correctly
- [x] Only matching clause steps execute
- [x] Default clause (`_`) works as fallback
- [x] Multiple steps per clause work
- [x] Execution continues after branch block
- [x] `decision` macro still works (legacy support)
- [x] Tests cover all branch scenarios (10 tests)

---

### Milestone 3.5: Loops

**Objective:** Implement loop constructs for iterative processing.

**Deliverables:**

1. **DSL:**
   ```elixir
   loop :retry_until_success,
     while: fn ctx -> !ctx.success && ctx.retries < 5 end do

     step :attempt_call do
       case ExternalAPI.call() do
         {:ok, _} -> put_context(:success, true)
         {:error, _} -> increment_context(:retries, 1)
       end
     end

     step :wait_before_retry do
       unless get_context(:success) do
         sleep_for(seconds: get_context(:retries) * 2)
       end
     end
   end
   ```

2. **Implementation:**
   - Condition evaluated before each iteration
   - Loop body executed as nested workflow
   - Context preserved between iterations
   - Loop metadata (iteration count) tracked

3. **Safeguards:**
   - Maximum iteration limit (configurable)
   - Timeout for entire loop
   - Break condition on error

**Success Criteria:**
- [ ] loop macro works
- [ ] while condition evaluated correctly
- [ ] Context flows between iterations
- [ ] Loop terminates on false condition
- [ ] Max iterations enforced

---

### Milestone 3.6: Parallel Execution

**Objective:** Implement parallel step execution.

**Deliverables:**

1. **DSL:**
   ```elixir
   parallel do
     step :send_email do
       EmailService.send(get_context(:user))
     end

     step :provision_workspace do
       WorkspaceService.create(get_context(:user_id))
     end

     step :create_billing do
       BillingService.setup(get_context(:user))
     end
   end
   ```

2. **Implementation:**
   - Spawn Task for each parallel step
   - Each task gets context snapshot
   - Wait for all tasks to complete
   - Merge results into context

3. **Context Merging Strategy:**
   ```elixir
   # Options for parallel context merging
   parallel merge: :last_wins do ... end      # Default: later steps override
   parallel merge: :deep_merge do ... end     # Deep merge maps
   parallel merge: fn results -> ... end do   # Custom merge function
   ```

4. **Error Handling:**
   - Fail-fast: cancel siblings on first failure
   - Complete-all: wait for all, collect errors
   - Configurable via options

**Success Criteria:**
- [ ] parallel macro works
- [ ] Steps execute concurrently
- [ ] All steps complete before continuing
- [ ] Context merging works
- [ ] Error handling configurable

---

### Milestone 3.7: ForEach

**Objective:** Implement foreach for processing collections.

**Deliverables:**

1. **DSL:**
   ```elixir
   foreach :process_items, items: fn -> get_context(:items) end do |item|
     step :process_item do
       result = ItemProcessor.process(item)
       append_context(:results, result)
     end
   end

   # With concurrency
   foreach :process_parallel,
     items: fn -> get_context(:items) end,
     concurrency: 5 do |item|
     step :process do
       process(item)
     end
   end
   ```

2. **Implementation:**
   - Items function evaluated to get collection
   - Sequential or parallel iteration
   - Item injected into step context
   - Index tracking for debugging

3. **Options:**
   - `concurrency: n` - parallel with limit
   - `on_error: :continue | :fail` - error handling
   - `collect: :key` - where to collect results

**Success Criteria:**
- [ ] foreach iterates over collection
- [ ] Item available in step context
- [ ] Sequential mode works
- [ ] Parallel mode with concurrency works
- [ ] Results collected correctly

---

### Milestone 3.8: Switch/Case

**Objective:** Implement switch/case for multi-way branching.

**Deliverables:**

1. **DSL:**
   ```elixir
   switch :route_ticket, on: fn -> get_context(:category) end do
     case_match "billing" do
       step :assign_billing do
         TicketService.assign(team: :billing)
       end
     end

     case_match "technical" do
       step :assign_engineering do
         TicketService.assign(team: :engineering)
       end
     end

     case_match ~r/security.*/ do
       step :assign_security do
         TicketService.assign(team: :security)
       end
     end

     default do
       step :assign_general do
         TicketService.assign(team: :general)
       end
     end
   end
   ```

2. **Implementation:**
   - Evaluate `on` function to get value
   - Match against case_match values
   - Support literal matching and regex
   - Execute matching branch or default

**Success Criteria:**
- [ ] switch macro works
- [ ] Literal matching works
- [ ] Regex matching works
- [ ] Default branch works
- [ ] Graph shows all branches

---

### Milestone 3.9: Compensation/Saga

**Objective:** Implement compensation handlers for rollback scenarios.

**Deliverables:**

1. **DSL:**
   ```elixir
   step :book_flight, compensate: :cancel_flight do
     result = FlightAPI.book(get_context(:flight))
     put_context(:flight_booking, result)
   end

   step :book_hotel, compensate: :cancel_hotel do
     result = HotelAPI.book(get_context(:hotel))
     put_context(:hotel_booking, result)
   end

   step :charge_payment do
     case PaymentService.charge(get_context(:total)) do
       {:ok, charge} -> {:ok, charge}
       {:error, reason} -> {:error, reason}  # Triggers compensation
     end
   end

   # Compensation functions
   compensate :cancel_flight do
     FlightAPI.cancel(get_context(:flight_booking))
   end

   compensate :cancel_hotel do
     HotelAPI.cancel(get_context(:hotel_booking))
   end
   ```

2. **Implementation:**
   - Track completed steps with compensations
   - On failure, execute compensations in reverse order
   - Compensation context includes original step result
   - Compensation failures logged but don't stop rollback

3. **Execution Flow:**
   ```
   step_1 (compensate: :comp_1) -> success
   step_2 (compensate: :comp_2) -> success
   step_3 -> FAILURE

   Compensation triggered:
   comp_2 executed
   comp_1 executed
   workflow marked as compensated/rolled_back
   ```

**Success Criteria:**
- [ ] compensate option registers handler
- [ ] Failure triggers compensation chain
- [ ] Compensations run in reverse order
- [ ] Compensation results recorded
- [ ] Status reflects compensation state

---

### Milestone 3.10: Workflow Orchestration

**Objective:** Enable calling child workflows from parent workflow steps.

**Deliverables:**

1. **DSL:**
   ```elixir
   # Call child workflow and wait for result
   step :process_payment do
     {:ok, result} = call_workflow(MyApp.PaymentWorkflow, %{
       order_id: get_context(:order_id),
       amount: get_context(:total)
     })
     put_context(:payment_result, result)
   end

   # Fire-and-forget (don't wait)
   step :send_notifications do
     start_workflow(MyApp.NotificationWorkflow, %{
       user_id: get_context(:user_id),
       event: :order_completed
     })
   end
   ```

2. **Implementation:**
   - `call_workflow/2,3` - Start child workflow, wait for completion, return result
   - `start_workflow/2,3` - Start child workflow, return immediately (fire-and-forget)
   - Parent-child relationship tracked via `parent_workflow_id` column
   - Child context isolated from parent
   - Child failure can propagate to parent (configurable)

3. **Options:**
   ```elixir
   call_workflow(Module, input,
     timeout: hours(1),          # Max wait time
     on_failure: :propagate,     # :propagate | :ignore | :compensate
     queue: :high_priority       # Override child's default queue
   )
   ```

4. **Querying:**
   ```elixir
   # Get child workflows
   Durable.list_executions(parent_id: workflow_id)

   # Get parent
   {:ok, execution} = Durable.get_execution(child_id)
   execution.parent_workflow_id
   ```

**Success Criteria:**
- [ ] `call_workflow` starts and waits for child
- [ ] `start_workflow` starts child without waiting
- [ ] Parent-child relationship tracked
- [ ] Child result returned to parent
- [ ] Timeout handling works
- [ ] Failure propagation configurable

---

### Milestone 3.11: Cron Scheduling

**Objective:** Implement decorator-based cron scheduling.

**Deliverables:**

1. **DSL:**
   ```elixir
   defmodule ReportWorkflow do
     use DurableWorkflow
     use DurableWorkflow.Cron

     @cron "0 9 * * *"  # Daily at 9 AM
     @cron_queue :reports
     @cron_input %{type: :daily}
     @cron_timezone "America/New_York"
     workflow "daily_report" do
       step :generate do
         ReportService.generate(input().type)
       end
     end
   end
   ```

2. **Scheduler Implementation:**
   - Parse cron expressions (use `crontab` library)
   - Calculate next run time
   - GenServer for scheduling loop
   - Store schedule in `scheduled_workflows` table

3. **Management API:**
   ```elixir
   DurableWorkflow.Scheduler.list_schedules()
   DurableWorkflow.Scheduler.enable(schedule_name)
   DurableWorkflow.Scheduler.disable(schedule_name)
   DurableWorkflow.Scheduler.trigger_now(schedule_name)
   DurableWorkflow.Scheduler.update_schedule(name, cron: "0 */2 * * *")
   ```

4. **Auto-registration:**
   ```elixir
   # On application start
   DurableWorkflow.Scheduler.register_all_crons([
     ReportWorkflow,
     CleanupWorkflow,
     SyncWorkflow
   ])
   ```

**Success Criteria:**
- [ ] @cron decorator works
- [ ] Cron expressions parsed correctly
- [ ] Jobs scheduled at correct times
- [ ] Timezone support works
- [ ] Enable/disable works
- [ ] Manual trigger works

---

## Phase 4: Scalability

### Milestone 4.1: Redis Queue Adapter

**Objective:** Implement Redis-based queue adapter for high-throughput scenarios.

**Deliverables:**

1. **DurableWorkflow.Queue.Adapters.Redis**
   - Uses Redis sorted sets for priority queues
   - BRPOPLPUSH for atomic job claiming
   - Lua scripts for complex operations
   - Requires `redix` dependency

2. **Configuration:**
   ```elixir
   config :durable_workflow,
     queue_adapter: DurableWorkflow.Queue.Adapters.Redis,
     queue_adapter_opts: [
       host: "localhost",
       port: 6379,
       pool_size: 5
     ]
   ```

**Success Criteria:**
- [ ] All queue operations work with Redis
- [ ] Priority ordering correct
- [ ] Atomic job claiming
- [ ] Performance better than Postgres for high throughput

---

### Milestone 4.2: RabbitMQ Queue Adapter

**Objective:** Implement RabbitMQ-based queue adapter.

**Deliverables:**

1. **DurableWorkflow.Queue.Adapters.RabbitMQ**
   - Uses AMQP protocol
   - Priority queues via x-max-priority
   - Message acknowledgment
   - Requires `amqp` dependency

2. **Configuration:**
   ```elixir
   config :durable_workflow,
     queue_adapter: DurableWorkflow.Queue.Adapters.RabbitMQ,
     queue_adapter_opts: [
       url: "amqp://guest:guest@localhost:5672"
     ]
   ```

**Success Criteria:**
- [ ] All queue operations work with RabbitMQ
- [ ] Message acknowledgment works
- [ ] Priority queues work

---

### Milestone 4.3: Redis Message Bus Adapter

**Objective:** Implement Redis Pub/Sub for message bus.

**Deliverables:**

1. **DurableWorkflow.MessageBus.Adapters.Redis**
   - Redis Pub/Sub for real-time events
   - Channel naming conventions
   - Reconnection handling

**Success Criteria:**
- [ ] Publish/subscribe works
- [ ] Event delivery reliable
- [ ] Reconnection handled gracefully

---

### Milestone 4.4: PostgreSQL pg_notify Message Bus

**Objective:** Implement pg_notify for PostgreSQL-only deployments.

**Deliverables:**

1. **DurableWorkflow.MessageBus.Adapters.Postgres**
   - LISTEN/NOTIFY for pub/sub
   - Postgrex notifications
   - Channel per workflow/topic

**Success Criteria:**
- [ ] Publish via NOTIFY works
- [ ] Subscribe via LISTEN works
- [ ] Notifications delivered promptly

---

### Milestone 4.5: Horizontal Scaling Support

**Objective:** Enable multiple nodes to process workflows safely.

**Deliverables:**

1. **Leader Election**
   - For scheduler (only one instance runs crons)
   - Using pg2 or distributed Erlang

2. **Node-aware Job Claiming**
   - Include node identifier in lock
   - Handle node failures gracefully

3. **Distributed Telemetry**
   - Aggregate metrics across nodes

**Success Criteria:**
- [ ] Multiple nodes process different jobs
- [ ] No duplicate processing
- [ ] Single scheduler leader
- [ ] Node failures handled

---

## Phase 5: Developer Experience

### Milestone 5.1: Mix Tasks

**Objective:** Provide helpful Mix tasks for development and operations.

**Deliverables:**

1. **mix durable_workflow.gen.migration** - Generate migrations
2. **mix durable_workflow.list** - List registered workflows
3. **mix durable_workflow.run** - Run a workflow from CLI
4. **mix durable_workflow.status** - Show execution status
5. **mix durable_workflow.cancel** - Cancel a workflow
6. **mix durable_workflow.cleanup** - Clean old executions

**Success Criteria:**
- [ ] All mix tasks work correctly
- [ ] Helpful output and error messages
- [ ] Documentation for each task

---

### Milestone 5.2: Testing Helpers

**Objective:** Provide test utilities for workflow testing.

**Deliverables:**

1. **DurableWorkflow.TestCase**
   ```elixir
   defmodule MyApp.WorkflowTest do
     use DurableWorkflow.TestCase

     test "order workflow completes" do
       {:ok, workflow_id} = start_workflow(OrderWorkflow, %{order_id: 123})

       assert_workflow_completed(workflow_id, timeout: 5000)

       execution = get_execution(workflow_id)
       assert execution.context.processed == true
     end
   end
   ```

2. **Helpers:**
   - `start_workflow/2` - Start workflow synchronously
   - `assert_workflow_completed/2` - Assert completion
   - `assert_step_completed/3` - Assert specific step
   - `provide_test_input/3` - Provide input in tests
   - `send_test_event/3` - Send event in tests
   - `mock_step/3` - Mock step implementations

3. **In-memory Adapters**
   - Queue adapter for tests
   - Message bus adapter for tests

**Success Criteria:**
- [ ] TestCase usable in ExUnit
- [ ] All assertions work
- [ ] Mocking capabilities work
- [ ] Fast test execution

---

### Milestone 5.3: Documentation

**Objective:** Comprehensive documentation for all features.

**Deliverables:**

1. **ExDoc Documentation**
   - Module docs for all public modules
   - Function docs with examples
   - Guides for common use cases

2. **Guides:**
   - Getting Started
   - Workflow DSL Reference
   - Context Management
   - Wait Primitives
   - Error Handling & Retries
   - Compensation & Sagas
   - Testing Workflows
   - Production Deployment
   - Migrating from Oban

3. **Examples:**
   - Order processing workflow
   - User onboarding workflow
   - Document ingestion pipeline
   - Approval workflow with human input

**Success Criteria:**
- [ ] All public APIs documented
- [ ] Guides cover major features
- [ ] Examples are runnable
- [ ] Published to HexDocs

---

### Milestone 5.4: Example Project

**Objective:** Create a reference implementation showing all features.

**Deliverables:**

1. **Example Phoenix Application**
   - Multiple workflow examples
   - Dashboard integration
   - WebSocket real-time updates
   - API endpoints for external events

2. **Workflows Demonstrated:**
   - E-commerce order processing
   - User registration with email verification
   - Document processing pipeline
   - Approval workflow with timeout

**Success Criteria:**
- [ ] Example app runs out of the box
- [ ] All major features demonstrated
- [ ] Well-commented code

---

## Implementation Order Summary

### Critical Path (Recommended Order)

```
Phase 0: Foundation (Required First)
├── 0.1: Project Scaffolding
└── 0.2: Database Schema

Phase 1: Core MVP (Build Sequentially)
├── 1.1: DSL Foundation
├── 1.2: Context Management
├── 1.3: Basic Executor
├── 1.4: Retry Logic
├── 1.5: PostgreSQL Queue
└── 1.6: Public API

Phase 2: Observability (Can Partially Parallelize)
├── 2.1: Logger Backend
├── 2.2: IO Capture
├── 2.3: Graph Generation ─┬─ 2.4: Export Formats
└── 2.5: Execution State ──┴─ 2.6: Dashboard (Optional)

Phase 3: Advanced Features (Most Can Parallelize)
├── 3.1: Sleep ─────────────┐
├── 3.2: Events ────────────┼── Wait Primitives
├── 3.3: Human Input ───────┘
├── 3.4: Decision Steps ────┐
├── 3.5: Loops ─────────────┼── Control Flow
├── 3.6: Parallel ──────────┤
├── 3.7: ForEach ───────────┤
├── 3.8: Switch/Case ───────┘
├── 3.9: Compensation/Saga
└── 3.10: Cron Scheduling

Phase 4: Scalability (Independent)
├── 4.1: Redis Queue
├── 4.2: RabbitMQ Queue
├── 4.3: Redis Message Bus
├── 4.4: pg_notify Message Bus
└── 4.5: Horizontal Scaling

Phase 5: Developer Experience (Independent)
├── 5.1: Mix Tasks
├── 5.2: Testing Helpers
├── 5.3: Documentation
└── 5.4: Example Project
```

---

## Risk Mitigation

### Technical Risks

1. **Macro Complexity**
   - Mitigation: Start simple, iterate. Use `@before_compile` pattern.
   - Test macros extensively with compile-time assertions.

2. **Database Contention**
   - Mitigation: Advisory locks, SKIP LOCKED, proper indexing.
   - Load test queue operations early.

3. **Context Serialization**
   - Mitigation: Strict JSON serialization, no arbitrary terms.
   - Document what can be stored in context.

4. **Log Volume**
   - Mitigation: Log level filtering, retention policies, truncation.
   - Configurable limits per step.

5. **Parallel Execution Bugs**
   - Mitigation: Extensive testing, clear context isolation.
   - Well-defined merge strategies.

### Project Risks

1. **Scope Creep**
   - Mitigation: Strict phase boundaries, MVP first.
   - Feature freeze until core is stable.

2. **Testing Coverage**
   - Mitigation: TDD approach, require tests for all features.
   - CI enforcement of coverage thresholds.

---

## Success Metrics

### Phase 1 (MVP)
- [ ] Can define and execute simple linear workflows
- [ ] Steps retry on failure with backoff
- [ ] Context persists across steps
- [ ] Queue processes jobs reliably
- [ ] Test coverage > 80%

### Phase 2 (Observability)
- [ ] All logs captured per step
- [ ] Graph visualization works
- [ ] Real-time execution visible

### Phase 3 (Advanced)
- [ ] Can replace Oban for complex workflows
- [ ] Human-in-the-loop workflows work
- [ ] Saga/compensation patterns work

### Phase 4 (Scalability)
- [ ] Multiple queue backends work
- [ ] Horizontal scaling demonstrated

### Phase 5 (DX)
- [ ] Comprehensive documentation
- [ ] Testing helpers make TDD easy
- [ ] Example project works end-to-end

---

## Appendix: Dependencies

### Required Dependencies

```elixir
# mix.exs
defp deps do
  [
    # Core
    {:ecto_sql, "~> 3.11"},
    {:postgrex, "~> 0.17"},
    {:jason, "~> 1.4"},
    {:telemetry, "~> 1.2"},
    {:nimble_options, "~> 1.1"},
    {:crontab, "~> 1.1"},

    # Optional - Queue Adapters
    {:redix, "~> 1.3", optional: true},
    {:amqp, "~> 3.3", optional: true},

    # Dev/Test
    {:ex_doc, "~> 0.31", only: :dev},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:mox, "~> 1.1", only: :test}
  ]
end
```

### Optional Dependencies

```elixir
# For Phoenix Dashboard
{:phoenix_live_view, "~> 0.20", optional: true}

# For NATS
{:gnat, "~> 1.7", optional: true}

# For Kafka
{:broadway_kafka, "~> 0.4", optional: true}
```
