# Durable - Remaining Work Plan

## Executive Summary

**Completed:** Phase 0 (Foundation) + Phase 1 (Core MVP)
**Remaining:** Phases 2-5 (Observability, Advanced Features, Scalability, Developer Experience)

**Current State:** 17 modules, 8 passing tests, core DSL and executor working

---

## Phase 2: Observability

### Overview
Add comprehensive logging, graph visualization, and real-time monitoring capabilities.

---

### 2.1 Logger Backend for Log Capture

**Priority:** High
**Complexity:** Medium
**Dependencies:** None

**Goal:** Automatically capture all `Logger` calls within workflow steps and store them in `step_executions.logs`.

**Files to Create:**
- `lib/durable/log_capture/logger_backend.ex`

**Implementation Details:**

```elixir
defmodule Durable.LogCapture.LoggerBackend do
  @behaviour :gen_event

  # Key insight: Use process dictionary to detect if we're in a workflow context
  # The executor already sets :durable_workflow_id, :durable_current_step

  def handle_event({level, _gl, {Logger, msg, ts, metadata}}, state) do
    case get_workflow_context() do
      nil ->
        # Not in workflow, ignore
        {:ok, state}

      %{workflow_id: wf_id, step: step} ->
        log_entry = %{
          timestamp: format_timestamp(ts),
          level: level,
          message: IO.iodata_to_binary(msg),
          metadata: filter_metadata(metadata)
        }

        # Buffer in process dictionary, flush on step completion
        buffer_log(log_entry)
        {:ok, state}
    end
  end
end
```

**Integration Points:**
- Modify `Durable.Executor.StepRunner` to:
  1. Set workflow context before step execution
  2. Flush logs after step completion
  3. Store logs in `StepExecution` record

**Testing Strategy:**
- Test log capture within step execution
- Test log filtering by level
- Test metadata handling
- Verify logs appear in `step_executions.logs`

**Acceptance Criteria:**
- [ ] `Logger.info/warn/error` calls captured within steps
- [ ] Logs stored with timestamp, level, message
- [ ] Logs retrievable via `Durable.Query.get_step_logs/2`
- [ ] Configurable log levels

---

### 2.2 IO Capture

**Priority:** Medium
**Complexity:** Medium
**Dependencies:** 2.1 (Logger Backend)

**Goal:** Capture `IO.puts` and `IO.inspect` output within workflow steps.

**Files to Create:**
- `lib/durable/log_capture/io_capture.ex`

**Implementation Details:**

```elixir
defmodule Durable.LogCapture.IOCapture do
  @doc """
  Wraps a function to capture all IO output.
  Uses group_leader replacement technique.
  """
  def with_capture(fun) do
    original_gl = Process.group_leader()
    {:ok, capture_pid} = start_capture_process()

    try do
      Process.group_leader(self(), capture_pid)
      result = fun.()
      output = get_captured_output(capture_pid)
      {result, output}
    after
      Process.group_leader(self(), original_gl)
      stop_capture_process(capture_pid)
    end
  end

  defp start_capture_process do
    # Custom process that buffers IO writes
    # Returns captured output on demand
  end
end
```

**Integration Points:**
- Wrap step execution in `IOCapture.with_capture/1`
- Convert captured output to log entries
- Merge with Logger-captured logs

**Testing Strategy:**
- Test `IO.puts` capture
- Test `IO.inspect` capture
- Test mixed Logger + IO capture
- Verify original IO restored after step

**Acceptance Criteria:**
- [ ] `IO.puts` output captured
- [ ] `IO.inspect` output captured
- [ ] Output stored as log entries
- [ ] No interference with normal IO after step

---

### 2.3 Graph Generation

**Priority:** High
**Complexity:** Medium
**Dependencies:** None

**Goal:** Generate visual graph representation from workflow definitions.

**Files to Create:**
- `lib/durable/graph/generator.ex`
- `lib/durable/graph/layout.ex`
- `lib/durable/graph.ex` (main API)

**Data Structure:**

```elixir
defmodule Durable.Graph do
  defstruct [:nodes, :edges, :metadata]

  @type node :: %{
    id: String.t(),
    type: :start | :end | :step | :decision | :parallel | :loop,
    label: String.t(),
    position: %{x: number(), y: number()},
    metadata: map()
  }

  @type edge :: %{
    from: String.t(),
    to: String.t(),
    label: String.t() | nil,
    type: :normal | :conditional | :loop_back
  }
end
```

**Implementation Details:**

```elixir
defmodule Durable.Graph.Generator do
  def generate(module, workflow_name) do
    {:ok, definition} = module.__workflow_definition__(workflow_name)

    nodes = [start_node() | step_nodes(definition.steps)] ++ [end_node()]
    edges = generate_edges(definition.steps)

    %Durable.Graph{
      nodes: nodes,
      edges: edges,
      metadata: %{
        workflow: workflow_name,
        module: module
      }
    }
  end

  defp step_nodes(steps) do
    Enum.with_index(steps)
    |> Enum.map(fn {step, idx} ->
      %{
        id: Atom.to_string(step.name),
        type: step.type,
        label: humanize(step.name),
        position: %{x: 0, y: (idx + 1) * 100},
        metadata: step.opts
      }
    end)
  end
end
```

**Testing Strategy:**
- Test graph generation from simple workflow
- Test node positioning
- Test edge generation
- Test with various step types

**Acceptance Criteria:**
- [ ] Generate graph from any workflow
- [ ] Correct node types and labels
- [ ] Edges connect steps in order
- [ ] Position data for layout

---

### 2.4 Graph Export Formats

**Priority:** Medium
**Complexity:** Low
**Dependencies:** 2.3 (Graph Generation)

**Goal:** Export graphs to DOT, Mermaid, and Cytoscape.js formats.

**Files to Create:**
- `lib/durable/graph/export/dot.ex`
- `lib/durable/graph/export/mermaid.ex`
- `lib/durable/graph/export/cytoscape.ex`

**Implementation Details:**

```elixir
# DOT format
defmodule Durable.Graph.Export.Dot do
  def export(%Durable.Graph{} = graph) do
    """
    digraph #{graph.metadata.workflow} {
      rankdir=TB;
      node [shape=box, style=rounded];

      #{nodes_to_dot(graph.nodes)}
      #{edges_to_dot(graph.edges)}
    }
    """
  end
end

# Mermaid format
defmodule Durable.Graph.Export.Mermaid do
  def export(%Durable.Graph{} = graph) do
    """
    graph TD
      #{nodes_to_mermaid(graph.nodes)}
      #{edges_to_mermaid(graph.edges)}
    """
  end
end

# Cytoscape.js JSON
defmodule Durable.Graph.Export.Cytoscape do
  def export(%Durable.Graph{} = graph) do
    %{
      elements: %{
        nodes: Enum.map(graph.nodes, &node_to_cytoscape/1),
        edges: Enum.map(graph.edges, &edge_to_cytoscape/1)
      }
    }
    |> Jason.encode!()
  end
end
```

**API:**

```elixir
{:ok, graph} = Durable.Graph.generate(OrderWorkflow, "process_order")

Durable.Graph.to_dot(graph)      # => "digraph {...}"
Durable.Graph.to_mermaid(graph)  # => "graph TD..."
Durable.Graph.to_cytoscape(graph) # => JSON string
```

**Acceptance Criteria:**
- [ ] DOT export renders in Graphviz
- [ ] Mermaid export renders correctly
- [ ] Cytoscape JSON valid and usable
- [ ] Node styling based on type

---

### 2.5 Real-time Execution State

**Priority:** High
**Complexity:** Medium
**Dependencies:** 2.3 (Graph Generation)

**Goal:** Overlay execution state on workflow graphs for real-time visualization.

**Files to Create:**
- `lib/durable/graph/execution_state.ex`

**Implementation Details:**

```elixir
defmodule Durable.Graph.ExecutionState do
  def get_graph_with_execution(module, workflow_name, workflow_id) do
    graph = Durable.Graph.generate(module, workflow_name)
    {:ok, execution} = Durable.get_execution(workflow_id, include_steps: true)

    nodes_with_state = Enum.map(graph.nodes, fn node ->
      step_exec = find_step_execution(execution.steps, node.id)

      Map.put(node, :execution_state, %{
        status: step_exec && step_exec.status,
        attempt: step_exec && step_exec.attempt,
        duration_ms: step_exec && step_exec.duration_ms,
        started_at: step_exec && step_exec.started_at,
        completed_at: step_exec && step_exec.completed_at,
        error: step_exec && step_exec.error,
        active: execution.current_step == node.id
      })
    end)

    %{graph | nodes: nodes_with_state}
  end
end
```

**Execution State Values:**

| Status | Color | Description |
|--------|-------|-------------|
| `nil` | Gray | Not yet reached |
| `:pending` | Yellow | About to run |
| `:running` | Blue (animated) | Currently executing |
| `:completed` | Green | Successfully completed |
| `:failed` | Red | Failed (with error) |
| `:waiting` | Orange | Waiting for event/input |

**Acceptance Criteria:**
- [ ] Graph reflects current execution state
- [ ] Running step highlighted
- [ ] Completed steps show duration
- [ ] Failed steps show error info
- [ ] Active step indicated

---

### 2.6 Phoenix LiveView Dashboard (Optional)

**Priority:** Low
**Complexity:** High
**Dependencies:** 2.1-2.5

**Goal:** Create an optional Phoenix LiveView dashboard for workflow monitoring.

**Recommendation:** Create as a separate package `durable_dashboard` to:
- Keep core library lightweight
- Make dashboard optional
- Allow independent versioning

**Package Structure:**

```
durable_dashboard/
├── lib/
│   └── durable_dashboard/
│       ├── router.ex
│       ├── live/
│       │   ├── workflow_list_live.ex
│       │   ├── workflow_detail_live.ex
│       │   ├── graph_live.ex
│       │   └── logs_live.ex
│       └── components/
│           ├── graph_component.ex
│           └── log_viewer_component.ex
└── assets/
    └── js/
        └── graph_renderer.js  # Cytoscape.js integration
```

**Deferred to Phase 5** - Focus on core functionality first.

---

## Phase 3: Advanced Features

### Overview
Implement wait primitives, control flow constructs, and advanced patterns.

---

### 3.1 Sleep Primitives

**Priority:** High
**Complexity:** Medium
**Dependencies:** Core executor

**Goal:** Implement `sleep_for` and `sleep_until` that properly suspend workflows.

**Current State:** Stubs exist in `Durable.Wait`, throwing signals.

**Files to Modify:**
- `lib/durable/wait.ex` - Already has basic structure
- `lib/durable/executor.ex` - Needs sleep handling improvement
- `lib/durable/executor/step_runner.ex` - Needs to propagate sleep signal

**Implementation Details:**

The throw-based approach already works. Need to:

1. **Improve wake-up mechanism:**
   - Currently relies on queue polling
   - Add scheduler GenServer to wake workflows at exact time

2. **Add Scheduler:**

```elixir
defmodule Durable.Scheduler.SleepWatcher do
  use GenServer

  # Polls for sleeping workflows that should wake up
  # More efficient than queue polling for precise timing

  def init(_) do
    schedule_check()
    {:ok, %{}}
  end

  def handle_info(:check_sleepers, state) do
    now = DateTime.utc_now()

    # Find workflows where scheduled_at <= now and status = :waiting
    workflows = Durable.Query.find_sleepers(now)

    Enum.each(workflows, fn wf ->
      Durable.Executor.resume_workflow(wf.id)
    end)

    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check_sleepers, 1000) # Check every second
  end
end
```

**Testing Strategy:**
- Test `sleep_for(seconds: 1)` suspends and resumes
- Test `sleep_until` with future datetime
- Test context preserved across sleep
- Test scheduled_at correctly set

**Acceptance Criteria:**
- [ ] `sleep_for` suspends workflow
- [ ] Workflow resumes after duration
- [ ] `sleep_until` works with DateTime
- [ ] Context preserved across sleep
- [ ] Multiple sleeping workflows handled

---

### 3.2 Wait for Events

**Priority:** High
**Complexity:** Medium
**Dependencies:** 3.1 (Sleep), Message Bus (optional)

**Goal:** Implement `wait_for_event` and `send_event` for external event handling.

**Files to Modify:**
- `lib/durable/wait.ex`
- `lib/durable/executor.ex`

**Files to Create:**
- `lib/durable/events.ex` - Event routing logic

**Implementation Details:**

```elixir
defmodule Durable.Events do
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query

  @doc """
  Registers a workflow as waiting for an event.
  """
  def register_wait(workflow_id, event_name, opts) do
    filter = Keyword.get(opts, :filter)
    timeout = Keyword.get(opts, :timeout)
    timeout_at = if timeout, do: DateTime.add(DateTime.utc_now(), timeout, :millisecond)

    # Store in pending_inputs with type: :event
    %Durable.Storage.Schemas.PendingInput{}
    |> Durable.Storage.Schemas.PendingInput.changeset(%{
      workflow_id: workflow_id,
      input_name: event_name,
      step_name: Durable.Context.current_step() |> Atom.to_string(),
      input_type: :event,
      schema: if(filter, do: %{filter: inspect(filter)}),
      timeout_at: timeout_at
    })
    |> Repo.insert()
  end

  @doc """
  Sends an event, potentially resuming waiting workflows.
  """
  def send_event(event_name, payload, opts \\ []) do
    workflow_id = Keyword.get(opts, :workflow_id)

    # Find matching waiting workflows
    query = from(p in Durable.Storage.Schemas.PendingInput,
      where: p.input_name == ^event_name and p.status == :pending,
      preload: [:workflow]
    )

    query = if workflow_id do
      from(p in query, where: p.workflow_id == ^workflow_id)
    else
      query
    end

    pending = Repo.all(query)

    Enum.each(pending, fn p ->
      # TODO: Apply filter if present
      complete_and_resume(p, payload)
    end)

    {:ok, length(pending)}
  end
end
```

**Event Matching:**
- Simple: Match by event name only
- Advanced: Apply filter function (stored as AST or MFA)

**Testing Strategy:**
- Test basic wait/send cycle
- Test event with payload
- Test timeout handling
- Test multiple waiters for same event
- Test workflow_id scoping

**Acceptance Criteria:**
- [ ] `wait_for_event` suspends workflow
- [ ] `send_event` resumes matching workflow
- [ ] Payload accessible in context
- [ ] Timeout triggers with timeout_value
- [ ] Multiple workflows can wait for same event

---

### 3.3 Wait for Human Input

**Priority:** High
**Complexity:** Medium
**Dependencies:** 3.2 (Events)

**Goal:** Implement `wait_for_input` with form schemas and `provide_input` for human-in-the-loop.

**Current State:** Basic structure exists.

**Enhancements Needed:**

1. **Form Schema Validation:**

```elixir
defmodule Durable.Wait.InputValidator do
  def validate(input_def, response) do
    case input_def.input_type do
      :form -> validate_form(input_def.fields, response)
      :single_choice -> validate_single_choice(input_def.fields, response)
      :multi_choice -> validate_multi_choice(input_def.fields, response)
      :approval -> validate_approval(response)
      :free_text -> {:ok, response}
    end
  end

  defp validate_form(fields, response) do
    errors = Enum.reduce(fields, [], fn field, acc ->
      value = Map.get(response, field.name)

      cond do
        field.required && is_nil(value) ->
          [{field.name, "is required"} | acc]
        field.type == :select && value not in field.options ->
          [{field.name, "invalid option"} | acc]
        field.max_length && String.length(value || "") > field.max_length ->
          [{field.name, "too long"} | acc]
        true ->
          acc
      end
    end)

    if errors == [], do: {:ok, response}, else: {:error, errors}
  end
end
```

2. **Query Pending Inputs:**

```elixir
# Already exists in wait.ex, enhance with more filters
Durable.Wait.list_pending_inputs(
  workflow: OrderWorkflow,
  input_type: :approval,
  older_than: hours(24)
)
```

**Testing Strategy:**
- Test form input with validation
- Test single/multi choice
- Test approval workflow
- Test timeout handling
- Test provide_input resumes workflow

**Acceptance Criteria:**
- [ ] Form input with field validation
- [ ] Choice inputs validated against options
- [ ] Timeout triggers with timeout_value
- [ ] Pending inputs queryable
- [ ] Input response stored in context

---

### 3.4 Decision Steps

**Priority:** High
**Complexity:** Medium
**Dependencies:** Core DSL

**Goal:** Implement `decision` and `on_decision` macros for conditional branching.

**Files to Create:**
- `lib/durable/dsl/decision.ex`

**Files to Modify:**
- `lib/durable.ex` - Add import
- `lib/durable/executor.ex` - Handle decision execution
- `lib/durable/definition.ex` - Add decision node type

**DSL Design:**

```elixir
defmodule MyApp.OrderWorkflow do
  use Durable
  use Durable.Context

  workflow "process_order" do
    step :calculate_total do
      put_context(:total, calculate_order_total())
    end

    decision :check_order_value do
      total = get_context(:total)
      cond do
        total > 10_000 -> :high_value
        total > 1_000 -> :medium_value
        true -> :standard
      end
    end

    on_decision :check_order_value do
      branch :high_value do
        step :require_approval do
          wait_for_input("manager_approval")
        end
      end

      branch :medium_value do
        step :verify_payment do
          PaymentService.verify_with_3ds(get_context(:order))
        end
      end

      branch :standard do
        step :auto_approve do
          put_context(:approved, true)
        end
      end
    end

    step :finalize do
      # Continues after any branch completes
    end
  end
end
```

**Implementation Approach:**

1. **Compile-time:** Collect branches into definition
2. **Runtime:** Executor evaluates decision, selects branch, executes branch steps

```elixir
defmodule Durable.DSL.Decision do
  defmacro decision(name, do: body) do
    quote do
      def unquote(:"__decision_body__#{name}")(_ctx) do
        unquote(body)
      end

      @durable_current_steps %Durable.Definition.Step{
        name: unquote(name),
        type: :decision,
        module: __MODULE__,
        opts: %{}
      }
    end
  end

  defmacro on_decision(decision_name, do: block) do
    # Collect branches and register as a single decision handler step
    quote do
      @durable_decision_branches %{}
      unquote(block)

      branches = @durable_decision_branches
      @durable_current_steps %Durable.Definition.Step{
        name: :"#{unquote(decision_name)}_handler",
        type: :decision_handler,
        module: __MODULE__,
        opts: %{decision: unquote(decision_name), branches: branches}
      }
    end
  end

  defmacro branch(result, do: block) do
    # Register branch steps
  end
end
```

**Graph Representation:**
- Decision node as diamond
- Edges labeled with result values
- Each branch as subgraph

**Acceptance Criteria:**
- [ ] `decision` macro works
- [ ] `on_decision` routes correctly
- [ ] `branch` matches values
- [ ] Graph shows decision branches
- [ ] Decision result stored in context

---

### 3.5 Loops

**Priority:** Medium
**Complexity:** Medium
**Dependencies:** 3.4 (Decisions)

**Goal:** Implement `loop` construct for iterative processing.

**DSL:**

```elixir
loop :retry_api, while: fn ctx -> ctx.retries < 5 && !ctx.success end do
  step :call_api do
    case ExternalAPI.call() do
      {:ok, result} ->
        put_context(:success, true)
        put_context(:result, result)
      {:error, _} ->
        increment_context(:retries, 1)
    end
  end

  step :backoff do
    unless get_context(:success) do
      sleep_for(seconds: get_context(:retries) * 2)
    end
  end
end
```

**Implementation:**
- Loop is a special step type
- Executor evaluates condition before each iteration
- Track iteration count in step execution
- Max iterations guard (configurable)

**Acceptance Criteria:**
- [ ] `loop` macro works
- [ ] `while` condition evaluated each iteration
- [ ] Context flows between iterations
- [ ] Loop terminates on false condition
- [ ] Max iterations enforced (safety)

---

### 3.6 Parallel Execution

**Priority:** High
**Complexity:** High
**Dependencies:** Core executor

**Goal:** Implement `parallel` block for concurrent step execution.

**DSL:**

```elixir
parallel do
  step :send_email do
    EmailService.send(get_context(:user))
  end

  step :provision_workspace do
    WorkspaceService.create(get_context(:user_id))
  end

  step :setup_billing do
    BillingService.setup(get_context(:user))
  end
end
```

**Implementation Approach:**

1. **Compile-time:** Collect parallel steps into a single parallel node
2. **Runtime:** Spawn tasks for each step, await all, merge context

```elixir
defmodule Durable.Executor.ParallelRunner do
  def execute(parallel_steps, workflow_id, base_context) do
    tasks = Enum.map(parallel_steps, fn step ->
      Task.async(fn ->
        # Each task gets a copy of context
        Durable.Context.restore_context(base_context, ...)
        Durable.Executor.StepRunner.execute(step, workflow_id)
      end)
    end)

    results = Task.await_many(tasks, :infinity)

    # Merge contexts from all tasks
    merged_context = merge_contexts(results)

    # Check for failures
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, merged_context}
      {:error, _} = error -> error
    end
  end

  defp merge_contexts(results) do
    # Strategy: later steps override, or deep merge, or custom function
  end
end
```

**Context Merging Strategies:**

| Strategy | Description |
|----------|-------------|
| `:last_wins` | Later steps override earlier (default) |
| `:deep_merge` | Deep merge maps |
| `:collect` | Collect all into a list |
| Custom fn | User-provided merge function |

**Error Handling Options:**

| Strategy | Description |
|----------|-------------|
| `:fail_fast` | Cancel siblings on first failure |
| `:complete_all` | Wait for all, collect errors |

**Acceptance Criteria:**
- [ ] `parallel` macro works
- [ ] Steps execute concurrently
- [ ] All steps complete before continuing
- [ ] Context merging works
- [ ] Error handling configurable
- [ ] Graph shows parallel branches

---

### 3.7 ForEach

**Priority:** Medium
**Complexity:** Medium
**Dependencies:** 3.6 (Parallel)

**Goal:** Implement `foreach` for processing collections.

**DSL:**

```elixir
foreach :process_items,
  items: fn -> get_context(:items) end,
  concurrency: 5 do |item|

  step :process_item do
    result = ItemProcessor.process(item)
    append_context(:results, result)
  end
end
```

**Implementation:**
- Sequential: Process items one at a time
- Concurrent: Process up to N items in parallel

**Acceptance Criteria:**
- [ ] `foreach` iterates over collection
- [ ] Item available in step context
- [ ] Sequential mode works
- [ ] Concurrent mode with limit works
- [ ] Results collected correctly

---

### 3.8 Switch/Case

**Priority:** Medium
**Complexity:** Low
**Dependencies:** 3.4 (Decisions)

**Goal:** Implement `switch`/`case_match` for multi-way branching.

**DSL:**

```elixir
switch :route_ticket, on: fn -> get_context(:category) end do
  case_match "billing" do
    step :assign_billing, do: assign_to(:billing)
  end

  case_match "technical" do
    step :assign_engineering, do: assign_to(:engineering)
  end

  case_match ~r/security.*/ do
    step :assign_security, do: assign_to(:security)
  end

  default do
    step :assign_general, do: assign_to(:general)
  end
end
```

**Implementation:**
- Similar to decision but with pattern matching
- Support literal, regex, and guard-like matching

**Acceptance Criteria:**
- [ ] Literal matching works
- [ ] Regex matching works
- [ ] Default branch works
- [ ] Graph shows all branches

---

### 3.9 Compensation/Saga

**Priority:** High
**Complexity:** High
**Dependencies:** Core executor

**Goal:** Implement compensation handlers for rollback scenarios.

**DSL:**

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
  # If this fails, compensations run in reverse order
  PaymentService.charge(get_context(:total))
end

# Compensation functions
compensate :cancel_flight do
  FlightAPI.cancel(get_context(:flight_booking))
end

compensate :cancel_hotel do
  HotelAPI.cancel(get_context(:hotel_booking))
end
```

**Implementation:**

1. **Track compensatable steps:** Record which steps completed with compensation handlers
2. **On failure:** Execute compensations in reverse order
3. **Compensation failures:** Log but continue (don't fail the compensation chain)

```elixir
defmodule Durable.Executor.Compensator do
  def run_compensations(workflow_id, failed_step) do
    # Get completed steps with compensations before failed_step
    steps = get_compensatable_steps(workflow_id, failed_step)

    # Run in reverse order
    Enum.reverse(steps)
    |> Enum.each(fn step ->
      try do
        execute_compensation(step)
      rescue
        e ->
          Logger.error("Compensation failed: #{inspect(e)}")
          # Continue with other compensations
      end
    end)

    mark_workflow_compensated(workflow_id)
  end
end
```

**Workflow Status:**
- Add `:compensated` status for workflows that failed and ran compensations
- Add `:compensation_failed` for workflows where compensation also failed

**Acceptance Criteria:**
- [ ] `compensate` option registers handler
- [ ] Failure triggers compensation chain
- [ ] Compensations run in reverse order
- [ ] Compensation results recorded
- [ ] Status reflects compensation state
- [ ] Compensation failures logged but don't stop chain

---

### 3.10 Cron Scheduling

**Priority:** Medium
**Complexity:** Medium
**Dependencies:** 3.1 (Sleep/Scheduler)

**Goal:** Implement decorator-based cron scheduling.

**DSL:**

```elixir
defmodule ReportWorkflow do
  use Durable
  use Durable.Cron

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

**Files to Create:**
- `lib/durable/cron.ex` - Cron DSL module
- `lib/durable/scheduler/cron_scheduler.ex` - Cron runner

**Implementation:**

```elixir
defmodule Durable.Cron do
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :cron, accumulate: false)
      Module.register_attribute(__MODULE__, :cron_queue, accumulate: false)
      Module.register_attribute(__MODULE__, :cron_input, accumulate: false)
      Module.register_attribute(__MODULE__, :cron_timezone, accumulate: false)

      @before_compile Durable.Cron
    end
  end

  defmacro __before_compile__(env) do
    # Collect cron metadata and generate registration functions
  end
end

defmodule Durable.Scheduler.CronScheduler do
  use GenServer

  def init(_) do
    schedules = load_schedules_from_db()
    schedule_next_runs(schedules)
    {:ok, %{schedules: schedules}}
  end

  def handle_info({:run_schedule, schedule_id}, state) do
    schedule = find_schedule(state.schedules, schedule_id)

    # Start the workflow
    module = String.to_existing_atom(schedule.workflow_module)
    Durable.start(module, schedule.input,
      workflow: schedule.workflow_name,
      queue: schedule.queue
    )

    # Calculate and schedule next run
    next_run = calculate_next_run(schedule.cron_expression, schedule.timezone)
    update_schedule(schedule_id, next_run)
    schedule_timer(schedule_id, next_run)

    {:noreply, state}
  end
end
```

**Management API:**

```elixir
Durable.Scheduler.list_schedules()
Durable.Scheduler.enable(schedule_name)
Durable.Scheduler.disable(schedule_name)
Durable.Scheduler.trigger_now(schedule_name)
Durable.Scheduler.update_schedule(name, cron: "0 */2 * * *")
```

**Acceptance Criteria:**
- [ ] `@cron` decorator works
- [ ] Cron expressions parsed correctly
- [ ] Jobs scheduled at correct times
- [ ] Timezone support works
- [ ] Enable/disable works
- [ ] Manual trigger works
- [ ] Persisted in `scheduled_workflows` table

---

## Phase 4: Scalability

### Overview
Add alternative queue/message bus adapters and horizontal scaling support.

---

### 4.1 Queue Adapter Behaviour

**Priority:** High
**Complexity:** Low
**Dependencies:** None

**Goal:** Define clean behaviour for queue adapters.

**Files to Create:**
- `lib/durable/queue/adapter.ex` (behaviour definition)

**Already exists, but needs enhancement:**

```elixir
defmodule Durable.Queue.Adapter do
  @callback enqueue(job :: map()) :: {:ok, job_id :: String.t()} | {:error, term()}
  @callback fetch_jobs(queue :: atom(), limit :: pos_integer()) :: [job()]
  @callback ack(job_id :: String.t()) :: :ok | {:error, term()}
  @callback nack(job_id :: String.t(), reason :: term()) :: :ok | {:error, term()}
  @callback reschedule(job_id :: String.t(), run_at :: DateTime.t()) :: :ok | {:error, term()}
  @callback get_stats(queue :: atom()) :: map()
  @callback pause(queue :: atom()) :: :ok
  @callback resume(queue :: atom()) :: :ok
end
```

---

### 4.2 Redis Queue Adapter

**Priority:** Medium
**Complexity:** Medium
**Dependencies:** 4.1

**Goal:** Implement Redis-based queue for high-throughput scenarios.

**Files to Create:**
- `lib/durable/queue/adapters/redis.ex`

**Implementation:**
- Uses Redis sorted sets for priority
- BRPOPLPUSH for atomic job claiming
- Lua scripts for complex operations

**Dependencies:**
- `{:redix, "~> 1.3", optional: true}`

---

### 4.3 RabbitMQ Queue Adapter

**Priority:** Low
**Complexity:** Medium
**Dependencies:** 4.1

**Goal:** Implement RabbitMQ-based queue.

**Files to Create:**
- `lib/durable/queue/adapters/rabbitmq.ex`

**Dependencies:**
- `{:amqp, "~> 3.3", optional: true}`

---

### 4.4 Message Bus Adapters

**Priority:** Medium
**Complexity:** Medium
**Dependencies:** None

**Goal:** Implement message bus for real-time events.

**Adapters:**
- PostgreSQL pg_notify (default)
- Redis Pub/Sub
- Phoenix.PubSub

**Files to Create:**
- `lib/durable/message_bus/adapter.ex`
- `lib/durable/message_bus/adapters/postgres.ex`
- `lib/durable/message_bus/adapters/redis.ex`
- `lib/durable/message_bus/adapters/phoenix_pubsub.ex`

---

### 4.5 Horizontal Scaling

**Priority:** Medium
**Complexity:** High
**Dependencies:** 4.1-4.4

**Goal:** Enable multiple nodes to process workflows safely.

**Components:**

1. **Leader Election** (for scheduler)
   - Use `:global` or pg2
   - Only leader runs cron scheduler

2. **Node-aware Locking**
   - Include node in `locked_by`
   - Handle node failures (stale lock detection)

3. **Distributed Telemetry**
   - Aggregate metrics across nodes

---

## Phase 5: Developer Experience

### Overview
Add tooling, testing helpers, and documentation.

---

### 5.1 Mix Tasks

**Priority:** High
**Complexity:** Low
**Dependencies:** Core complete

**Files to Create:**
- `lib/mix/tasks/durable.gen.migration.ex`
- `lib/mix/tasks/durable.list.ex`
- `lib/mix/tasks/durable.run.ex`
- `lib/mix/tasks/durable.status.ex`
- `lib/mix/tasks/durable.cancel.ex`
- `lib/mix/tasks/durable.cleanup.ex`

**Commands:**

```bash
mix durable.gen.migration    # Generate migrations
mix durable.list             # List registered workflows
mix durable.run Module input # Run a workflow
mix durable.status ID        # Show execution status
mix durable.cancel ID        # Cancel execution
mix durable.cleanup --older-than 30d  # Clean old executions
```

---

### 5.2 Testing Helpers

**Priority:** High
**Complexity:** Medium
**Dependencies:** Core complete

**Files to Create:**
- `lib/durable/testing.ex`
- `test/support/case.ex`

**TestCase:**

```elixir
defmodule Durable.TestCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Durable.Testing

      # Helper functions
      def start_workflow(module, input, opts \\ []) do
        Durable.start(module, input, opts)
      end

      def assert_workflow_completed(workflow_id, opts \\ []) do
        timeout = Keyword.get(opts, :timeout, 5000)

        # Poll until completed or timeout
        assert_eventually(fn ->
          {:ok, exec} = Durable.get_execution(workflow_id)
          exec.status == :completed
        end, timeout)
      end

      def assert_step_completed(workflow_id, step_name, opts \\ []) do
        # ...
      end

      def provide_test_input(workflow_id, input_name, data) do
        Durable.provide_input(workflow_id, input_name, data)
      end

      def send_test_event(workflow_id, event_name, payload) do
        Durable.send_event(workflow_id, event_name, payload)
      end
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Durable.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Durable.Repo, {:shared, self()})
    end

    :ok
  end
end
```

**Mock Step Execution:**

```elixir
defmodule Durable.Testing do
  def mock_step(module, step_name, return_value) do
    # Replace step function with mock
  end

  def stub_external_service(module, function, return_value) do
    # Use Mox or similar
  end
end
```

---

### 5.3 Documentation

**Priority:** High
**Complexity:** Low
**Dependencies:** All features

**Deliverables:**

1. **ExDoc Documentation**
   - All public modules documented
   - All functions with examples

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

3. **Examples in docs:**
   - Order processing
   - User onboarding
   - Document pipeline
   - Approval workflow

---

### 5.4 Example Project

**Priority:** Low
**Complexity:** Medium
**Dependencies:** All features

**Create:** `examples/` directory with sample Phoenix app demonstrating all features.

---

## Implementation Priority Matrix

| Feature | Priority | Complexity | Dependencies | Estimated Effort |
|---------|----------|------------|--------------|-----------------|
| Logger Backend | High | Medium | None | 1-2 days |
| IO Capture | Medium | Medium | Logger Backend | 1 day |
| Graph Generation | High | Medium | None | 2 days |
| Graph Export | Medium | Low | Graph Gen | 1 day |
| Execution State | High | Medium | Graph Gen | 1 day |
| Sleep Primitives | High | Medium | None | 1-2 days |
| Wait for Events | High | Medium | Sleep | 2 days |
| Wait for Input | High | Medium | Events | 2 days |
| Decision Steps | High | Medium | None | 2-3 days |
| Loops | Medium | Medium | Decisions | 2 days |
| Parallel | High | High | None | 3-4 days |
| ForEach | Medium | Medium | Parallel | 2 days |
| Switch/Case | Medium | Low | Decisions | 1 day |
| Compensation | High | High | None | 3-4 days |
| Cron Scheduling | Medium | Medium | Sleep | 2-3 days |
| Mix Tasks | High | Low | Core | 2 days |
| Testing Helpers | High | Medium | Core | 2-3 days |
| Documentation | High | Low | All | 3-5 days |

---

## Recommended Implementation Order

### Sprint 1: Core Observability (1 week)
1. Logger Backend (2.1)
2. IO Capture (2.2)
3. Graph Generation (2.3)
4. Graph Export (2.4)

### Sprint 2: Wait Primitives (1 week)
1. Sleep Primitives (3.1)
2. Wait for Events (3.2)
3. Wait for Input (3.3)
4. Execution State (2.5)

### Sprint 3: Control Flow (1.5 weeks)
1. Decision Steps (3.4)
2. Switch/Case (3.8)
3. Loops (3.5)
4. Parallel Execution (3.6)

### Sprint 4: Advanced Patterns (1 week)
1. ForEach (3.7)
2. Compensation/Saga (3.9)
3. Cron Scheduling (3.10)

### Sprint 5: Developer Experience (1 week)
1. Mix Tasks (5.1)
2. Testing Helpers (5.2)
3. Documentation (5.3)

### Sprint 6: Scalability (Optional, 1-2 weeks)
1. Redis Queue Adapter (4.2)
2. Message Bus Adapters (4.4)
3. Horizontal Scaling (4.5)

---

## Success Metrics

### Phase 2 Complete When:
- [ ] All Logger calls captured within steps
- [ ] Graph visualization works
- [ ] Real-time execution state available

### Phase 3 Complete When:
- [ ] All wait primitives work (sleep, event, input)
- [ ] All control flow works (decision, loop, parallel, foreach)
- [ ] Compensation pattern works
- [ ] Cron scheduling works

### Phase 4 Complete When:
- [ ] At least one alternative queue adapter works
- [ ] Message bus for real-time updates works
- [ ] Multiple nodes can process workflows

### Phase 5 Complete When:
- [ ] Mix tasks available
- [ ] TestCase provides all helpers
- [ ] Full documentation on HexDocs
- [ ] Example project demonstrates all features

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Macro complexity | Extensive testing, incremental development |
| Parallel execution bugs | Use Task.Supervisor, proper error handling |
| Context merge conflicts | Well-defined merge strategies, documentation |
| Performance issues | Benchmark critical paths, use database indexes |
| Breaking changes | Semantic versioning, deprecation warnings |

---

## Appendix: File Checklist

### Phase 2 Files
- [ ] `lib/durable/log_capture/logger_backend.ex`
- [ ] `lib/durable/log_capture/io_capture.ex`
- [ ] `lib/durable/graph.ex`
- [ ] `lib/durable/graph/generator.ex`
- [ ] `lib/durable/graph/layout.ex`
- [ ] `lib/durable/graph/execution_state.ex`
- [ ] `lib/durable/graph/export/dot.ex`
- [ ] `lib/durable/graph/export/mermaid.ex`
- [ ] `lib/durable/graph/export/cytoscape.ex`

### Phase 3 Files
- [ ] `lib/durable/scheduler/sleep_watcher.ex`
- [ ] `lib/durable/events.ex`
- [ ] `lib/durable/wait/input_validator.ex`
- [ ] `lib/durable/dsl/decision.ex`
- [ ] `lib/durable/dsl/loop.ex`
- [ ] `lib/durable/dsl/parallel.ex`
- [ ] `lib/durable/dsl/foreach.ex`
- [ ] `lib/durable/dsl/switch.ex`
- [ ] `lib/durable/executor/parallel_runner.ex`
- [ ] `lib/durable/executor/compensator.ex`
- [ ] `lib/durable/cron.ex`
- [ ] `lib/durable/scheduler/cron_scheduler.ex`

### Phase 4 Files
- [ ] `lib/durable/queue/adapters/redis.ex`
- [ ] `lib/durable/queue/adapters/rabbitmq.ex`
- [ ] `lib/durable/message_bus/adapter.ex`
- [ ] `lib/durable/message_bus/adapters/postgres.ex`
- [ ] `lib/durable/message_bus/adapters/redis.ex`
- [ ] `lib/durable/message_bus/adapters/phoenix_pubsub.ex`

### Phase 5 Files
- [ ] `lib/mix/tasks/durable.gen.migration.ex`
- [ ] `lib/mix/tasks/durable.list.ex`
- [ ] `lib/mix/tasks/durable.run.ex`
- [ ] `lib/mix/tasks/durable.status.ex`
- [ ] `lib/mix/tasks/durable.cancel.ex`
- [ ] `lib/mix/tasks/durable.cleanup.ex`
- [ ] `lib/durable/testing.ex`
- [ ] `test/support/case.ex`
