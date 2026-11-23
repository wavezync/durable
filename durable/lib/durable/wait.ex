defmodule Durable.Wait do
  @moduledoc """
  Wait primitives for durable workflows.

  Provides functions for:
  - Pausing workflow execution for a duration or until a specific time
  - Waiting for external events
  - Waiting for human input (human-in-the-loop)

  ## Usage

      defmodule MyApp.ApprovalWorkflow do
        use Durable
        use Durable.Helpers
        use Durable.Wait

        workflow "approval" do
          step :request_approval, fn expense ->
            answer = wait_for_approval("manager_approval",
              prompt: "Approve expense?",
              timeout: days(3),
              timeout_value: :no_answer
            )

            # An answer comes back with string keys; the timeout value as written.
            {:ok, assign(expense, :approved, match?(%{"approved" => true}, answer))}
          end
        end
      end

  ## Primitives

  - `sleep/1` - Pause for a duration
  - `schedule_at/1` - Pause until a specific time
  - `wait_for_event/2` - Wait for an external event
  - `wait_for_input/2` - Wait for human input (generic)
  - `wait_for_approval/2` - Wait for approval (convenience)
  - `wait_for_choice/2` - Wait for single choice selection
  - `wait_for_text/2` - Wait for text input
  - `wait_for_form/2` - Wait for form submission
  - `wait_for_any/2` - Wait for any of multiple events
  - `wait_for_all/2` - Wait for all of multiple events
  """

  alias Durable.Config
  alias Durable.Context
  alias Durable.EngineState
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Query.Opts
  alias Durable.Repo
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup, WorkflowExecution}

  @finished [:completed, :failed, :cancelled, :compensated, :compensation_failed]

  import Ecto.Query
  import Durable.Executor.StepRunner, only: [is_run_data: 1]

  @doc """
  Injects wait functions into the calling module.
  """
  defmacro __using__(_opts) do
    quote do
      import Durable.Wait,
        only: [
          # Pause primitives
          sleep: 1,
          schedule_at: 1,
          # Event waiting
          wait_for_event: 1,
          wait_for_event: 2,
          wait_for_any: 1,
          wait_for_any: 2,
          wait_for_all: 1,
          wait_for_all: 2,
          # Human input - core
          wait_for_input: 1,
          wait_for_input: 2,
          # Human input - convenience wrappers
          wait_for_approval: 1,
          wait_for_approval: 2,
          wait_for_choice: 2,
          wait_for_text: 1,
          wait_for_text: 2,
          wait_for_form: 2,
          # Time helpers
          next_business_day: 0,
          next_business_day: 1,
          next_weekday: 1,
          next_weekday: 2,
          end_of_day: 0,
          end_of_day: 1
        ]
    end
  end

  # ============================================================================
  # Pause Primitives
  # ============================================================================

  @doc """
  Pauses the workflow for the specified duration.

  The workflow will be suspended and resumed after the duration elapses.

  ## Examples

      sleep(seconds(30))
      sleep(minutes(5))
      sleep(hours(2))
      sleep(days(1))

  ## Resumption semantics

  Like `wait_for_event/2`, `sleep/1` is a resumption barrier: when the
  step re-runs after the wake fires, the SleepWaker has left a marker for
  the step that this call recognises and returns `nil` for instead of
  re-throwing. Any side effects
  *before* `sleep/1` therefore run twice (once on suspend, again on
  resume) — keep them idempotent or move them into a prior step.

  Multiple `sleep/1` calls inside one step body are not supported: the
  marker is per-step, not per-call, so the second call on resume would
  return immediately rather than wait. Use one wait per step.

  """
  @spec sleep(integer()) :: nil
  def sleep(duration_ms) when is_integer(duration_ms) do
    if sleep_satisfied?() do
      nil
    else
      throw({:sleep, duration_ms: duration_ms})
    end
  end

  @doc """
  Pauses the workflow until the specified datetime.

  ## Examples

      schedule_at(~U[2026-01-10 09:00:00Z])
      schedule_at(next_business_day(hour: 9))
      schedule_at(next_weekday(:monday, hour: 9))

  See `sleep/1` for resumption semantics — they are identical.
  """
  @spec schedule_at(DateTime.t()) :: nil
  def schedule_at(%DateTime{} = datetime) do
    if sleep_satisfied?() do
      nil
    else
      throw({:sleep, until: datetime})
    end
  end

  # On resume after a sleep wake, the SleepWaker writes
  # `"__sleep_satisfied__" => "<step_name>"` into the run's engine state.
  # When the step body re-runs, this guard makes `sleep`/`schedule_at`
  # return `nil` instead of throwing again — so the rest of the step
  # body runs, the step completes, and the workflow advances.
  #
  # The marker is keyed by step name (not by call site), so it survives
  # exactly until the user step finishes. Subsequent sleep steps get
  # their own marker written by the next wake.
  #
  # `cancel_wait/2` on a sleeping run leaves the same marker: a cancel of one
  # of the step's other waits doesn't end its sleep.
  defp sleep_satisfied? do
    step = Process.get(:durable_current_step)
    step != nil and EngineState.current()["__sleep_satisfied__"] == Atom.to_string(step)
  end

  # A wait under one of the engine's own names could never be answered: the
  # answer is the user's data, and those names are dropped from it.
  defp own_name!(name) do
    if EngineState.key?(name) do
      raise ArgumentError,
            "#{inspect(name)} is a name Durable keeps for itself, so nothing can wait under it"
    end

    name
  end

  # A wait_for_event or wait_for_input: what its own row says it ended with, or
  # it waits. A wait that timed out returns the call's own `:timeout_value`,
  # exactly as written: the stored copy went through JSON, so an atom or a
  # tuple wouldn't come back as one.
  defp await(schema, name, opts, wait) do
    case own_wait(single_waits(schema, name), {schema, name}, answered_status(schema)) do
      [%{status: status} = row | later] when status in [:received, :completed] ->
        answer_of(row, name, later)

      [%{status: :timeout} | _] ->
        Keyword.get(opts, :timeout_value)

      [%{status: :cancelled} | _] ->
        cancelled()

      _not_answered ->
        throw(wait)
    end
  end

  defp single_waits(PendingEvent, name) do
    from(p in PendingEvent,
      where: p.event_name == ^name and is_nil(p.wait_group_id) and p.status != :buffered
    )
  end

  defp single_waits(PendingInput, name), do: from(p in PendingInput, where: p.input_name == ^name)

  defp answered_status(PendingEvent), do: :received
  defp answered_status(_input_or_group), do: :completed

  # The answer is merged into the context under the wait's name, so the newest
  # wait of that name finds it there. One the step asked again under the same
  # name reads its row's copy.
  # ponytail: that copy wraps an answer that isn't a map as %{"value" => v}, so
  # an earlier answer of exactly %{"value" => v} reads as v. Store it unwrapped
  # if a step ever gets two such answers under one name.
  defp answer_of(_row, name, []), do: Map.get(Process.get(:durable_context, %{}), name)
  defp answer_of(%PendingEvent{payload: payload}, _name, _later), do: unwrapped(payload)
  defp answer_of(%PendingInput{response: response}, _name, _later), do: unwrapped(response)

  defp unwrapped(%{"value" => value} = stored) when map_size(stored) == 1, do: value
  defp unwrapped(stored), do: stored

  # This call's own wait: the n-th the step has made for `key` (a name, or a
  # group's names), n being how many times this pass of the step has asked for
  # it. The step runs again from the top each time it resumes, so it asks in
  # the same order every pass, and each call finds its own row, never an
  # earlier wait's of the same name or a key of the same name in the run's data.
  # A retried run keeps the answers its step already had, and asks again for
  # the waits that timed out or were closed when the run failed (its deadline,
  # `on_timeout: :fail`).
  # Returns that row and the one after it, or [] outside a run.
  defp own_wait(query, key, answered) do
    calls = Process.get(:durable_wait_calls, %{})
    n = Map.get(calls, key, 0)
    Process.put(:durable_wait_calls, Map.put(calls, key, n + 1))

    with id when id != nil <- Context.workflow_id(),
         step when step != nil <- Process.get(:durable_current_step) do
      Repo.all(
        Config.get(Process.get(:durable_instance, Durable)),
        from(p in query,
          join: w in WorkflowExecution,
          on: w.id == p.workflow_id,
          where: p.workflow_id == ^id and p.step_name == ^to_string(step),
          where: is_nil(w.retried_at) or p.inserted_at > w.retried_at or p.status == ^answered,
          order_by: [asc: p.inserted_at],
          offset: ^n,
          limit: 2
        )
      )
    else
      _outside_a_run -> []
    end
  end

  # A wait whose own row was cancelled. Why is the engine's to say: its state
  # for the run, never a key of the step's data.
  defp cancelled, do: {:cancelled, EngineState.current()["__cancelled__"]}

  # A wait_for_any or wait_for_all: what its own group got, or it waits.
  defp await_group(names, opts, wait) do
    groups = from(g in WaitGroup, where: g.event_names == ^names)

    case own_wait(groups, {WaitGroup, names}, :completed) do
      [%{status: :completed, wait_type: :any, received_events: received} | _] ->
        name = Enum.find(names, &Map.has_key?(received, &1))
        {name, received[name]}

      [%{status: :completed, received_events: received} | _] ->
        Map.take(received, names)

      [%{status: :timeout} = group | _] ->
        group_timeout_value(opts, group)

      [%{status: :cancelled} | _] ->
        cancelled()

      _not_answered ->
        throw(wait)
    end
  end

  # `timeout_value: nil` or `false` is a value like any other; only a call
  # without the option gets `{:timeout, received}`.
  defp group_timeout_value(opts, group) do
    Keyword.get_lazy(opts, :timeout_value, fn ->
      {:timeout, if(group.wait_type == :all, do: group.received_events)}
    end)
  end

  # ============================================================================
  # Event Waiting
  # ============================================================================

  @doc """
  Waits for an external event.

  The workflow will be suspended until the event is received or timeout occurs.
  Returns the event's payload as it is stored: a map sent as `%{amount: 99}`
  comes back as `%{"amount" => 99}`.

  ## Options

  - `:timeout` - Timeout in milliseconds (optional)
  - `:timeout_value` - Value to return on timeout (default: `nil`). It comes
    back exactly as written, atom, tuple or map: the wait returns the call's
    own option, not a stored copy. Put in the context, it is stored as JSON
    like the rest of it

  ## Resumption semantics

  `wait_for_event/2` is a **resumption barrier**, not a pause inside the
  step body. When the event arrives, the step body re-executes from the
  top — it doesn't "continue" from the line where the wait was called.
  On re-execution, the wait finds the event data in the restored context
  and returns immediately without re-suspending.

  This means any side effects BEFORE `wait_for_event/2` run each time the
  step is invoked (once on suspend, again on resume). Make them idempotent
  or move them into a separate prior step:

      # 🚫 not idempotent — sends two emails
      step :wait_for_approval, fn data ->
        Mailer.send_approval_request(data)      # runs on both passes
        result = wait_for_event("approved")
        {:ok, assign(data, :approved, result)}
      end

      # ✅ side effect lives in its own step
      step :request_approval, fn data -> Mailer.send_approval_request(data); {:ok, data} end
      step :await_approval,   fn data -> {:ok, assign(data, :approved, wait_for_event("approved"))} end

  ## Examples

      # Wait indefinitely
      result = wait_for_event("payment_confirmed")

      # With timeout
      result = wait_for_event("payment_confirmed",
        timeout: hours(2),
        timeout_value: {:error, :payment_timeout}
      )

  """
  @spec wait_for_event(String.t(), keyword()) :: term()
  def wait_for_event(event_name, opts \\ []) do
    own_name!(event_name)
    wait = {:wait_for_event, Keyword.put(opts, :event_name, event_name)}
    await(PendingEvent, event_name, opts, wait)
  end

  @doc """
  Waits for any of the specified events.

  Returns `{event_name, payload}` when any event is received.

  An event kept with `send_event(..., buffer: true)` before the run got here
  counts: the wait takes the first of its names that has one, in the order
  listed, and returns at once. Events kept for its other names stay kept.

  ## Options

  - `:timeout` - Timeout in milliseconds (optional)
  - `:timeout_value` - Value to return on timeout, exactly as written, `nil`
    and `false` included. Without the option a timeout returns
    `{:timeout, nil}`

  ## Examples

      {event, payload} = wait_for_any(["success", "failure", "cancelled"])

      {event, payload} = wait_for_any(["approved", "rejected"],
        timeout: hours(24),
        timeout_value: {:timeout, nil}
      )

  """
  @spec wait_for_any([String.t()], keyword()) :: {String.t(), term()}
  def wait_for_any(event_names, opts \\ []) when is_list(event_names) do
    # A name listed twice is one event to wait for.
    event_names = event_names |> Enum.uniq() |> Enum.map(&own_name!/1)
    wait = {:wait_for_any, Keyword.merge(opts, event_names: event_names, wait_type: :any)}
    await_group(event_names, opts, wait)
  end

  @doc """
  Waits for all of the specified events.

  Returns a map of `%{event_name => payload}` when all events are received.

  Events kept with `send_event(..., buffer: true)` before the run got here
  count, so the wait is only for the names that have none.

  ## Options

  - `:timeout` - Timeout in milliseconds (optional)
  - `:timeout_value` - Value to return on timeout, exactly as written, `nil`
    and `false` included. Without the option a timeout returns
    `{:timeout, received}`, with the events that did arrive

  ## Examples

      results = wait_for_all(["manager_approval", "legal_approval"])
      # => %{"manager_approval" => %{...}, "legal_approval" => %{...}}

      results = wait_for_all(["step1_complete", "step2_complete"],
        timeout: days(7),
        timeout_value: {:timeout, :partial}
      )

  """
  @spec wait_for_all([String.t()], keyword()) :: map()
  def wait_for_all(event_names, opts \\ []) when is_list(event_names) do
    event_names = event_names |> Enum.uniq() |> Enum.map(&own_name!/1)
    wait = {:wait_for_all, Keyword.merge(opts, event_names: event_names, wait_type: :all)}
    await_group(event_names, opts, wait)
  end

  # ============================================================================
  # Human Input - Core
  # ============================================================================

  @doc """
  Waits for human input.

  The workflow will be suspended until input is provided or timeout occurs.

  ## Options

  - `:type` - Input type: `:approval`, `:choice`, `:text`, `:form` (default: `:free_text`)
  - `:prompt` - Prompt to show to the user
  - `:metadata` - Additional data for the UI to display
  - `:fields` - Field definitions for form input
  - `:choices` - Choice options for choice input
  - `:timeout` - Timeout in milliseconds
  - `:timeout_value` - Value to return on timeout, exactly as written
    (default: `nil`)
  - `:on_timeout` - `:resume` (default) returns `:timeout_value`; `:fail`
    fails the run with a `"timeout"` error, running its compensations

  ## Examples

      # Simple input
      result = wait_for_input("feedback")

      # With timeout
      result = wait_for_input("manager_approval",
        type: :approval,
        prompt: "Approve expense?",
        metadata: %{amount: 150.00},
        timeout: days(3),
        timeout_value: :auto_approved
      )

  """
  @spec wait_for_input(String.t(), keyword()) :: term()
  def wait_for_input(input_name, opts \\ []) do
    own_name!(input_name)
    wait = {:wait_for_input, Keyword.put(opts, :input_name, input_name)}
    await(PendingInput, input_name, opts, wait)
  end

  # ============================================================================
  # Human Input - Convenience Wrappers
  # ============================================================================

  @doc """
  Waits for an approval decision.

  Returns the answer as it was given, read back from storage, or
  `timeout_value` if the timeout occurs. The dashboard's Inbox answers with
  `%{"approved" => true}` or `%{"approved" => false}`, plus `"comment"` and
  `"by"` when given.

  ## Options

  - `:prompt` - Prompt to show to the user
  - `:metadata` - Additional data for the UI to display
  - `:timeout` - Timeout in milliseconds
  - `:timeout_value` - Value to return on timeout

  ## Examples

      result = wait_for_approval("manager_approval")
      # => %{"approved" => true} after
      #    Durable.provide_input(id, "manager_approval", %{"approved" => true})

      result = wait_for_approval("expense_approval",
        prompt: "Approve expense for $500?",
        metadata: %{employee: "John", amount: 500},
        timeout: days(3),
        timeout_value: :auto_approved
      )

  """
  @spec wait_for_approval(String.t(), keyword()) :: term()
  def wait_for_approval(input_name, opts \\ []) do
    wait_for_input(input_name, Keyword.put(opts, :type, :approval))
  end

  @doc """
  Waits for a single choice selection.

  Returns the selected choice value.

  ## Options

  - `:choices` - List of choice options (required)
  - `:prompt` - Prompt to show to the user
  - `:metadata` - Additional data for the UI to display
  - `:timeout` - Timeout in milliseconds
  - `:timeout_value` - Value to return on timeout (often a default choice)

  ## Examples

      result = wait_for_choice("shipping_method",
        prompt: "Select shipping method:",
        choices: [
          %{value: "express", label: "Express ($15)"},
          %{value: "standard", label: "Standard (Free)"}
        ],
        timeout: hours(24),
        timeout_value: "standard"
      )
      # => "express" | "standard"

  """
  @spec wait_for_choice(String.t(), keyword()) :: term()
  def wait_for_choice(input_name, opts) do
    # Map choices to fields for storage
    opts =
      case Keyword.get(opts, :choices) do
        nil -> opts
        choices -> Keyword.put(opts, :fields, choices)
      end

    wait_for_input(input_name, Keyword.put(opts, :type, :single_choice))
  end

  @doc """
  Waits for text input.

  Returns the entered text string.

  ## Options

  - `:prompt` - Prompt to show to the user
  - `:metadata` - Additional data for the UI to display
  - `:timeout` - Timeout in milliseconds
  - `:timeout_value` - Value to return on timeout

  ## Examples

      result = wait_for_text("rejection_reason",
        prompt: "Please provide a reason for rejection:",
        timeout: hours(4),
        timeout_value: "No reason provided"
      )
      # => "Budget exceeded for this quarter"

  """
  @spec wait_for_text(String.t(), keyword()) :: String.t() | term()
  def wait_for_text(input_name, opts \\ []) do
    wait_for_input(input_name, Keyword.put(opts, :type, :free_text))
  end

  @doc """
  Waits for form submission.

  Returns a map of field values, keyed by field name as a string.

  ## Options

  - `:fields` - List of field definitions (required)
  - `:prompt` - Prompt to show to the user
  - `:metadata` - Additional data for the UI to display
  - `:timeout` - Timeout in milliseconds
  - `:timeout_value` - Value to return on timeout

  ## Examples

      result = wait_for_form("equipment_request",
        prompt: "Select your equipment preferences:",
        fields: [
          %{name: :laptop, type: :select, options: ["MacBook Pro", "ThinkPad X1"], required: true},
          %{name: :monitor, type: :select, options: ["27-inch", "32-inch"], required: false},
          %{name: :notes, type: :text, required: false}
        ],
        timeout: days(7)
      )
      # => %{"laptop" => "MacBook Pro", "monitor" => "27-inch", "notes" => "..."}

  """
  @spec wait_for_form(String.t(), keyword()) :: map() | term()
  def wait_for_form(input_name, opts) do
    wait_for_input(input_name, Keyword.put(opts, :type, :form))
  end

  # ============================================================================
  # Time Helpers
  # ============================================================================

  @doc """
  Returns the next business day (Mon-Fri) at the specified hour.

  ## Options

  - `:hour` - Hour of day (0-23), default: 9
  - `:timezone` - Timezone string, default: "UTC"

  ## Examples

      next_business_day()
      # => ~U[2026-01-05 09:00:00Z] (next Mon-Fri at 9am UTC)

      next_business_day(hour: 17)
      # => ~U[2026-01-05 17:00:00Z]

  """
  @spec next_business_day(keyword()) :: DateTime.t()
  def next_business_day(opts \\ []) do
    hour = Keyword.get(opts, :hour, 9)
    zone = zone(opts)

    zone |> today_in() |> find_next_business_day() |> at_time(Time.new!(hour, 0, 0, {0, 6}), zone)
  end

  defp find_next_business_day(date) do
    next_day = Date.add(date, 1)

    # Skip weekends (6 = Saturday, 7 = Sunday)
    if Date.day_of_week(next_day) in [6, 7], do: find_next_business_day(next_day), else: next_day
  end

  defp zone(opts) do
    case Keyword.get(opts, :timezone, "UTC") do
      "UTC" -> "Etc/UTC"
      zone -> zone
    end
  end

  # Raises for a zone that can't be resolved, as `DateTime.now!/1` does.
  defp today_in(zone), do: zone |> DateTime.now!() |> DateTime.to_date()

  # A day's hour in the zone, as UTC. A time that a clock change repeats means
  # its first occurrence, and one it skips means the moment after the change.
  defp at_time(date, time, zone) do
    local =
      case DateTime.new(date, time, zone) do
        {:ok, datetime} -> datetime
        {:ambiguous, first, _second} -> first
        {:gap, _before, just_after} -> just_after
      end

    DateTime.shift_zone!(local, "Etc/UTC")
  end

  @doc """
  Returns the next occurrence of the specified weekday.

  ## Options

  - `:hour` - Hour of day (0-23), default: 9
  - `:timezone` - Timezone string, default: "UTC"

  ## Examples

      next_weekday(:monday)
      # => ~U[2026-01-06 09:00:00Z]

      next_weekday(:friday, hour: 17)
      # => ~U[2026-01-10 17:00:00Z]

  """
  @spec next_weekday(atom(), keyword()) :: DateTime.t()
  def next_weekday(weekday, opts \\ []) do
    hour = Keyword.get(opts, :hour, 9)
    zone = zone(opts)
    today = today_in(zone)

    target_day = weekday_number(weekday)
    current_day = Date.day_of_week(today)

    days_until =
      if target_day > current_day do
        target_day - current_day
      else
        7 - current_day + target_day
      end

    today |> Date.add(days_until) |> at_time(Time.new!(hour, 0, 0, {0, 6}), zone)
  end

  defp weekday_number(:monday), do: 1
  defp weekday_number(:tuesday), do: 2
  defp weekday_number(:wednesday), do: 3
  defp weekday_number(:thursday), do: 4
  defp weekday_number(:friday), do: 5
  defp weekday_number(:saturday), do: 6
  defp weekday_number(:sunday), do: 7

  @doc """
  Returns the end of the current day.

  ## Options

  - `:timezone` - Timezone string, default: "UTC"

  ## Examples

      end_of_day()
      # => ~U[2026-01-03 23:59:59Z]

  """
  @spec end_of_day(keyword()) :: DateTime.t()
  def end_of_day(opts \\ []) do
    zone = zone(opts)

    zone |> today_in() |> at_time(Time.new!(23, 59, 59, {0, 6}), zone)
  end

  # ============================================================================
  # External API - Provide Input
  # ============================================================================

  @doc """
  Provides input for a waiting workflow.

  Called from external code (API, UI, etc.) to continue a workflow.

  ## Options

  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      Durable.provide_input(workflow_id, "manager_approval", %{approved: true})

  """
  @spec provide_input(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def provide_input(workflow_id, input_name, data, opts \\ []) do
    config = get_config(opts)
    # Sanitize at the API boundary so any tuples / PIDs / functions that
    # leak in from controllers, LiveViews, or external callers can't crash
    # JSONB persistence in PendingInput.response or workflow.context. An answer
    # is the user's data, so the engine's own keys are dropped from it.
    safe_data = data |> Durable.Executor.sanitize_for_json() |> EngineState.strip()

    with :ok <- answerable(workflow_id, input_name),
         {:ok, completed} <- answer_and_resume(config, workflow_id, input_name, safe_data, opts) do
      DurablePubSub.broadcast_input(config, :input_provided, pending_input_to_map(completed))
      :ok
    end
  end

  # One transaction: an answer used up without a resume would strand the run.
  defp answer_and_resume(config, workflow_id, input_name, safe_data, opts) do
    Repo.transaction(config, fn ->
      lock_run(config, workflow_id)

      with {:ok, pending} <- find_pending_input(config, workflow_id, input_name),
           {:ok, completed} <- complete_pending_input(config, pending, safe_data),
           {:ok, _} <-
             Durable.Executor.resume_workflow(workflow_id, %{input_name => safe_data}, opts) do
        completed
      else
        {:error, reason} -> config.repo.rollback(reason)
      end
    end)
  end

  # ============================================================================
  # External API - Send Event
  # ============================================================================

  @doc """
  Sends an event to a waiting workflow.

  Without `buffer: true`, the workflow must already be waiting for the event:
  otherwise this returns `{:error, :not_found}` and the event is not kept.

  ## Options

  - `:buffer` - Keep the event when the run isn't waiting for it yet, and
    deliver it when the run reaches a wait for `event_name`: `wait_for_event/2`,
    `wait_for_any/2` or `wait_for_all/2` (default: `false`). A run gets one
    event per name, so when several were kept by then, it gets the newest and
    the rest are dropped. Returns `{:error, :finished}` for a run that has
    finished.
  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      Durable.send_event(workflow_id, "payment_confirmed", %{amount: 99.99})

  """
  @spec send_event(String.t(), String.t(), term(), keyword()) :: :ok | {:error, term()}
  def send_event(workflow_id, event_name, payload, opts \\ []) do
    config = get_config(opts)
    # Sanitize at the API boundary — same rationale as provide_input/4.
    safe_payload = payload |> Durable.Executor.sanitize_for_json() |> EngineState.strip()

    with :ok <- answerable(workflow_id, event_name) do
      if Keyword.get(opts, :buffer, false),
        do: send_or_buffer(config, workflow_id, event_name, safe_payload),
        else: deliver_to_waiter(config, workflow_id, event_name, safe_payload)
    end
  end

  # An id or a name that couldn't be in the database has no one waiting on it.
  # Nor does a name the engine keeps for itself: its own events, a lane's or a
  # child's finish, are never sent from outside.
  defp answerable(workflow_id, name) do
    if Repo.id?(workflow_id) and not Repo.bad_text?(name) and not EngineState.key?(name),
      do: :ok,
      else: {:error, :not_found}
  end

  # The wait is looked up with the run locked: read before the lock, it could be
  # one another sender or the timeout sweep has since closed, and this sender
  # would overwrite what the run was given and report it delivered.
  defp deliver_to_waiter(config, workflow_id, event_name, safe_payload) do
    sent =
      Repo.transaction(config, fn ->
        lock_run(config, workflow_id)
        deliver_if_waiting(config, workflow_id, event_name, safe_payload)
      end)

    wake_resumed(config, sent)
  end

  defp deliver_if_waiting(config, workflow_id, event_name, payload) do
    case find_pending_event(config, workflow_id, event_name) do
      {:ok, pending_event} ->
        deliver(config, workflow_id, event_name, pending_event, payload)

      {:error, :not_found} = not_found ->
        if late_for_group?(config, workflow_id, event_name), do: :ok, else: not_found
    end
  end

  # The wake goes out once the transaction that resumed the run has committed.
  defp wake_resumed(config, {:ok, {:resumed, run}}), do: DurablePubSub.wake(config, run)
  defp wake_resumed(_config, {:ok, result}), do: result
  defp wake_resumed(_config, {:error, reason}), do: {:error, reason}

  # An event for a wait_for_any that already has its answer is a no-op, not an
  # error: the sender can't know which event got there first.
  defp late_for_group?(config, workflow_id, event_name) do
    query =
      from(p in PendingEvent,
        join: g in WaitGroup,
        on: g.id == p.wait_group_id,
        where:
          p.workflow_id == ^workflow_id and p.event_name == ^event_name and
            g.status == :completed,
        limit: 1,
        select: true
      )

    Repo.one(config, query) == true
  end

  defp deliver(config, workflow_id, event_name, pending_event, safe_payload) do
    # PendingEvent.payload is typed `:map`. Non-map payloads (e.g. an event
    # sent with just a string identifier) get wrapped under "value" so the
    # cast always succeeds. The wait group / resume context use the
    # unwrapped payload so user code reading `received_events` sees the
    # original shape it sent. A date is a map to Elixir but a string to JSON,
    # and a column of maps can't read a string back: it is wrapped too.
    storable_payload =
      if is_run_data(safe_payload), do: safe_payload, else: %{"value" => safe_payload}

    multi =
      build_send_event_multi(
        workflow_id,
        event_name,
        pending_event,
        storable_payload,
        safe_payload
      )

    case Repo.transaction(config, multi) do
      {:ok, %{resume: resumed}} ->
        {:resumed, resumed}

      {:error, stage, reason, _} ->
        require Logger

        Logger.error(
          "[Durable] failed to atomically fulfill event + (optional wait_group) + resume: " <>
            "stage=#{stage} reason=#{inspect(reason)} workflow=#{workflow_id} event=#{event_name}"
        )

        # Every caller holds the run's lock in a transaction of its own.
        config.repo.rollback(reason)
    end
  end

  # Buffered events. The sender and the run reaching `wait_for_event` both lock
  # the run's row first, so one of them always sees the other: either the
  # sender finds the waiter and delivers, or the run finds the buffered event.
  defp send_or_buffer(config, workflow_id, event_name, payload) do
    sent =
      Repo.transaction(config, fn ->
        case lock_run(config, workflow_id) do
          nil -> {:error, :not_found}
          %{status: status} when status in @finished -> {:error, :finished}
          _open -> deliver_or_buffer(config, workflow_id, event_name, payload)
        end
      end)

    wake_resumed(config, sent)
  end

  defp deliver_or_buffer(config, workflow_id, event_name, payload) do
    case find_pending_event(config, workflow_id, event_name) do
      {:ok, pending_event} ->
        deliver(config, workflow_id, event_name, pending_event, payload)

      {:error, :not_found} ->
        %PendingEvent{
          workflow_id: workflow_id,
          event_name: event_name,
          step_name: "__buffered",
          status: :buffered,
          # Wrapped so any payload shape round-trips through the jsonb column.
          payload: %{"__payload__" => payload},
          wait_type: :single
        }
        |> Repo.insert(config)

        :ok
    end
  end

  @doc false
  # Called right after a run starts waiting for `event_name`: delivers the
  # newest event kept for it, if any, and drops the rest.
  @spec deliver_buffered(Config.t(), String.t(), String.t()) :: :ok
  def deliver_buffered(config, workflow_id, event_name) do
    buffered =
      from(p in PendingEvent,
        where:
          p.workflow_id == ^workflow_id and p.event_name == ^event_name and
            p.status == :buffered
      )

    delivered =
      Repo.transaction(config, fn ->
        lock_run(config, workflow_id)

        with [newest | _] <-
               Repo.all(config, from(p in buffered, order_by: [desc: p.inserted_at])),
             {:ok, pending_event} <- find_pending_event(config, workflow_id, event_name) do
          Repo.delete_all(config, buffered)
          deliver(config, workflow_id, event_name, pending_event, newest.payload["__payload__"])
        end
      end)

    wake_resumed(config, delivered)
    :ok
  end

  defp lock_run(config, workflow_id) do
    Repo.one(
      config,
      from(w in WorkflowExecution,
        where: w.id == ^workflow_id,
        lock: "FOR UPDATE",
        select: struct(w, [:id, :status, :scheduled_at, :current_step])
      )
    )
  end

  # Single Ecto.Multi covering:
  #
  #   1. PendingEvent -> :received
  #   2. If the event belongs to a wait group: lock + merge into received_events,
  #      flip to :completed when satisfied (closes the lost-update race).
  #   3. Resume the workflow (`:waiting` -> `:pending`) when the wait condition
  #      is satisfied — either the single-event case, or the wait group just
  #      transitioned to :completed.
  #
  # All three steps share the same transaction so a crash anywhere can't leave
  # us with the "event :received but parent stuck :waiting" state that zombie
  # detection misreads as a workflow crash.
  defp build_send_event_multi(
         workflow_id,
         event_name,
         pending_event,
         storable_payload,
         resume_payload
       ) do
    Ecto.Multi.new()
    |> Durable.Executor.lock_run(workflow_id)
    |> Ecto.Multi.update(
      :event,
      PendingEvent.receive_changeset(pending_event, storable_payload)
    )
    |> Ecto.Multi.run(:resume, fn repo, _ ->
      resume_after_event(repo, workflow_id, event_name, pending_event, resume_payload)
    end)
  end

  defp resume_after_event(repo, workflow_id, event_name, pending_event, payload) do
    case pending_event.wait_group_id do
      nil ->
        # Plain wait_for_event — no wait group, resume immediately.
        Durable.Executor.resume_parent_in_multi(repo, workflow_id, %{event_name => payload})

      wait_group_id ->
        merge_wait_group_and_maybe_resume(repo, wait_group_id, event_name, payload)
    end
  end

  defp merge_wait_group_and_maybe_resume(repo, wait_group_id, event_name, payload) do
    with {:ok, wg_result} <-
           WaitGroup.add_event_locked(repo, wait_group_id, event_name, payload) do
      if wg_result.just_completed do
        close_group_events(repo, wait_group_id)

        Durable.Executor.resume_parent_in_multi(
          repo,
          wg_result.wait_group.workflow_id,
          wg_result.wait_group.received_events
        )
      else
        {:ok, %{no_op: true, wait_group: wg_result.wait_group}}
      end
    end
  end

  # wait_for_any leaves the events that didn't fire. Open, they'd still take an
  # event, and clash with a later wait on the same name.
  defp close_group_events(repo, wait_group_id) do
    repo.update_all(
      from(p in PendingEvent, where: p.wait_group_id == ^wait_group_id and p.status == :pending),
      set: [status: :cancelled, completed_at: DateTime.utc_now()]
    )
  end

  # ============================================================================
  # External API - Cancel Wait
  # ============================================================================

  @doc """
  Cancels a waiting workflow's wait.

  The wait returns `{:cancelled, reason}` and the run carries on from there.

  A run that waits on other runs has no wait of its own to cancel: one in a
  `parallel` block waits for its lanes, and one in `call_workflow` for the
  child. For such a run the call goes down to them instead. Every lane or
  child that is waiting has its wait cancelled the same way, and theirs in
  turn if they wait on other runs. Lanes and children that aren't waiting are
  left alone, and so is the block or the call itself: it still waits for them
  to finish, and then finishes by its own rules. Returns `:ok` even when
  nothing under the run was waiting.

  Returns `{:error, :not_waiting}` for a run that isn't waiting and
  `{:error, :not_found}` for an id that isn't a run.

  ## Options

  - `:reason` - Cancellation reason (default: "cancelled")
  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      Durable.Wait.cancel_wait(workflow_id, reason: "User cancelled")

  """
  @spec cancel_wait(String.t(), keyword()) :: :ok | {:error, term()}
  def cancel_wait(workflow_id, opts \\ []) do
    config = get_config(opts)
    reason = Keyword.get(opts, :reason, "cancelled")

    with {:ok, _execution} <- get_waiting_execution(config, workflow_id) do
      cancel_waits_under(config, workflow_id, reason, opts)
    end
  end

  # Each run is handled under its own lock, and no lock is held across two
  # runs: a child that finishes locks itself and then its parent.
  defp cancel_waits_under(config, workflow_id, reason, opts) do
    case Repo.transaction(config, fn -> cancel_and_resume(config, workflow_id, reason, opts) end) do
      {:ok, {:waits_on, children}} ->
        Enum.each(children, &cancel_wait_if_waiting(config, &1, reason, opts))

      {:ok, _resumed} ->
        :ok

      {:error, error} ->
        {:error, error}
    end
  end

  defp cancel_wait_if_waiting(config, workflow_id, reason, opts) do
    with {:ok, _execution} <- get_waiting_execution(config, workflow_id) do
      cancel_waits_under(config, workflow_id, reason, opts)
    end
  end

  defp cancel_and_resume(config, workflow_id, reason, opts) do
    run = lock_run(config, workflow_id)

    case awaited_runs(config, workflow_id) do
      [] ->
        :ok = cancel_pending_waits(config, workflow_id)
        resume_cancelled(config, run, reason, opts)

      children ->
        {:waits_on, children}
    end
  end

  # A sleeping run (the only waiting run with a `scheduled_at`) gets the
  # marker the sleep waker would leave, so its sleep returns.
  defp resume_cancelled(config, nil, _reason, _opts), do: config.repo.rollback(:not_found)

  defp resume_cancelled(config, run, reason, opts) do
    engine =
      if run.scheduled_at,
        do: %{"__cancelled__" => reason, "__sleep_satisfied__" => run.current_step},
        else: %{"__cancelled__" => reason}

    case Durable.Executor.resume_workflow(run.id, %{}, [engine: engine] ++ opts) do
      {:ok, resumed} -> resumed
      {:error, error} -> config.repo.rollback(error)
    end
  end

  # The runs this one waits for: the lanes of its parallel block, or the child
  # of its call_workflow. Cancelling the wait for them would resume a block
  # with its lanes unfinished, which fails it and leaves them waiting for ever.
  defp awaited_runs(config, workflow_id) do
    names =
      Repo.all(
        config,
        from(p in PendingEvent,
          where: p.workflow_id == ^workflow_id and p.status == :pending,
          select: p.event_name
        )
      )

    for name <- names, id = awaited_run(name), Repo.id?(id), do: id
  end

  defp awaited_run("__parallel_done:" <> id), do: id
  defp awaited_run("__child_done:" <> id), do: id
  defp awaited_run(_event_name), do: nil

  @doc false
  @spec cancel_pending_waits(Config.t(), String.t()) :: :ok
  def cancel_pending_waits(config, workflow_id) do
    # The run's row first (rule 2). A block's lane takes it before it changes
    # the block's events; without it, this took them in the table's order and
    # the lane in its own, and the two deadlocked.
    {:ok, :ok} =
      Repo.transaction(config, fn ->
        lock_run(config, workflow_id)

        for schema <- [PendingInput, PendingEvent, WaitGroup] do
          query = from(p in schema, where: p.workflow_id == ^workflow_id and p.status == :pending)

          Repo.update_all(config, query,
            set: [status: :cancelled, completed_at: DateTime.utc_now()]
          )
        end

        :ok
      end)

    :ok
  end

  # ============================================================================
  # Query API
  # ============================================================================

  @doc """
  Lists pending inputs for workflows.

  ## Filters

  - `:status` - Filter by status (default: :pending)
  - `:timeout_before` - Filter inputs timing out before this datetime
  - `:limit` - Maximum number of results (default: 50)
  - `:durable` - The Durable instance name (default: Durable)

  Returns `{:ok, inputs}`, or `{:error, {:invalid_option, key}}` for a filter
  of the wrong type, such as a negative `:limit` or a status no input has.
  `list_pending_inputs!/1` returns the inputs or raises `ArgumentError`. See
  `Durable.Query.Opts`.

      {:ok, inputs} = Durable.Wait.list_pending_inputs(limit: 20)
      inputs = Durable.Wait.list_pending_inputs!(limit: 20)

  """
  @spec list_pending_inputs(keyword()) ::
          {:ok, [map()]} | {:error, Opts.reason()}
  def list_pending_inputs(filters \\ []) do
    schema = [
      status: {:one_of, Ecto.Enum.values(PendingInput, :status)},
      timeout_before: :datetime,
      limit: :non_neg_integer
    ]

    with {:ok, filters} <- Opts.validate(filters, schema),
         do: {:ok, pending_inputs(filters)}
  end

  @doc "Like `list_pending_inputs/1`, but returns the inputs or raises `ArgumentError`."
  @spec list_pending_inputs!(keyword()) :: [map()]
  def list_pending_inputs!(filters \\ []),
    do: filters |> list_pending_inputs() |> Opts.unwrap!(filters)

  defp pending_inputs(filters) do
    config = get_config(filters)
    status = Keyword.get(filters, :status, :pending)
    limit = Keyword.get(filters, :limit, 50)

    query =
      from(p in PendingInput,
        where: p.status == ^status,
        order_by: [asc: p.timeout_at, asc: p.inserted_at],
        limit: ^limit,
        preload: [:workflow]
      )

    query =
      case Keyword.get(filters, :timeout_before) do
        nil -> query
        datetime -> from(p in query, where: p.timeout_at <= ^datetime)
      end

    Repo.all(config, query)
    |> Enum.map(&pending_input_to_map/1)
  end

  @doc """
  Lists pending events for workflows.

  ## Filters

  - `:event_name` - Filter by event name
  - `:status` - Filter by status (default: :pending)
  - `:limit` - Maximum number of results (default: 50)
  - `:durable` - The Durable instance name (default: Durable)

  Returns `{:ok, events}`, or `{:error, {:invalid_option, key}}` for a filter
  of the wrong type, such as a negative `:limit`, a status no event has, or an
  `:event_name` Postgres can't hold. `list_pending_events!/1` returns the
  events or raises `ArgumentError`. See `Durable.Query.Opts`.

      {:ok, events} = Durable.Wait.list_pending_events(event_name: "payment_confirmed")
      events = Durable.Wait.list_pending_events!(event_name: "payment_confirmed")

  """
  @spec list_pending_events(keyword()) ::
          {:ok, [map()]} | {:error, Opts.reason()}
  def list_pending_events(filters \\ []) do
    schema = [
      event_name: :text,
      status: {:one_of, Ecto.Enum.values(PendingEvent, :status)},
      limit: :non_neg_integer
    ]

    with {:ok, filters} <- Opts.validate(filters, schema),
         do: {:ok, pending_events(filters)}
  end

  @doc "Like `list_pending_events/1`, but returns the events or raises `ArgumentError`."
  @spec list_pending_events!(keyword()) :: [map()]
  def list_pending_events!(filters \\ []),
    do: filters |> list_pending_events() |> Opts.unwrap!(filters)

  defp pending_events(filters) do
    config = get_config(filters)
    status = Keyword.get(filters, :status, :pending)
    limit = Keyword.get(filters, :limit, 50)

    query =
      from(p in PendingEvent,
        where: p.status == ^status,
        order_by: [asc: p.timeout_at, asc: p.inserted_at],
        limit: ^limit,
        preload: [:workflow]
      )

    query =
      case Keyword.get(filters, :event_name) do
        nil ->
          query

        event_name ->
          if Repo.bad_text?(event_name),
            do: from(p in query, where: false),
            else: from(p in query, where: p.event_name == ^event_name)
      end

    Repo.all(config, query)
    |> Enum.map(&pending_event_to_map/1)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_config(opts) do
    durable_name = Keyword.get(opts, :durable, Durable)
    Config.get(durable_name)
  end

  defp find_pending_input(config, workflow_id, input_name) do
    query =
      from(p in PendingInput,
        where:
          p.workflow_id == ^workflow_id and
            p.input_name == ^input_name and
            p.status == :pending
      )

    case Repo.one(config, query) do
      nil -> {:error, :not_found}
      pending -> {:ok, pending}
    end
  end

  defp find_pending_event(config, workflow_id, event_name) do
    query =
      from(p in PendingEvent,
        where:
          p.workflow_id == ^workflow_id and
            p.event_name == ^event_name and
            p.status == :pending
      )

    case Repo.one(config, query) do
      nil -> {:error, :not_found}
      pending -> {:ok, pending}
    end
  end

  defp complete_pending_input(config, pending, response) do
    # PendingInput.response is typed `:map`. Non-map responses (a single
    # string from wait_for_choice/wait_for_text, an approval atom, etc.)
    # would silently fail Ecto's cast and short-circuit the resume flow,
    # leaving the workflow stuck in :waiting until timeout.
    #
    # The workflow's downstream context still receives the unwrapped value
    # via Executor.resume_workflow, so this wrapping is purely for the
    # audit/display field on PendingInput.
    storable_response = if is_run_data(response), do: response, else: %{"value" => response}

    pending
    |> PendingInput.complete_changeset(storable_response)
    |> Repo.update(config)
  end

  defp get_waiting_execution(config, workflow_id) do
    case Repo.id?(workflow_id) && Repo.get(config, WorkflowExecution, workflow_id) do
      %{status: :waiting} = execution -> {:ok, execution}
      %WorkflowExecution{} -> {:error, :not_waiting}
      _not_a_run -> {:error, :not_found}
    end
  end

  defp pending_input_to_map(pending) do
    %{
      id: pending.id,
      workflow_id: pending.workflow_id,
      input_name: pending.input_name,
      step_name: pending.step_name,
      input_type: pending.input_type,
      prompt: pending.prompt,
      metadata: pending.metadata,
      fields: pending.fields,
      status: pending.status,
      timeout_at: pending.timeout_at,
      inserted_at: pending.inserted_at
    }
  end

  defp pending_event_to_map(pending) do
    %{
      id: pending.id,
      workflow_id: pending.workflow_id,
      event_name: pending.event_name,
      step_name: pending.step_name,
      status: pending.status,
      wait_type: pending.wait_type,
      timeout_at: pending.timeout_at,
      inserted_at: pending.inserted_at
    }
  end
end
