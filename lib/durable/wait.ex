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
        use Durable.Context
        use Durable.Wait

        workflow "approval" do
          step :request_approval do
            result = wait_for_approval("manager_approval",
              prompt: "Approve expense?",
              timeout: days(3),
              timeout_value: :auto_reject
            )
            put_context(:approval, result)
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
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup, WorkflowExecution}

  import Ecto.Query

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

  """
  @spec sleep(integer()) :: nil
  def sleep(duration_ms) when is_integer(duration_ms) do
    throw({:sleep, duration_ms: duration_ms})
  end

  @doc """
  Pauses the workflow until the specified datetime.

  ## Examples

      schedule_at(~U[2026-01-10 09:00:00Z])
      schedule_at(next_business_day(hour: 9))
      schedule_at(next_weekday(:monday, hour: 9))

  """
  @spec schedule_at(DateTime.t()) :: nil
  def schedule_at(%DateTime{} = datetime) do
    throw({:sleep, until: datetime})
  end

  # ============================================================================
  # Event Waiting
  # ============================================================================

  @doc """
  Waits for an external event.

  The workflow will be suspended until the event is received or timeout occurs.

  ## Options

  - `:timeout` - Timeout in milliseconds (optional)
  - `:timeout_value` - Value to return on timeout (optional)

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
    # Check if we're resuming with event data already in context
    # Context keys are atoms (converted from strings when restored from DB)
    context = Process.get(:durable_context, %{})
    key = String.to_atom(event_name)

    case Map.get(context, key) do
      nil -> throw({:wait_for_event, Keyword.put(opts, :event_name, event_name)})
      data -> data
    end
  end

  @doc """
  Waits for any of the specified events.

  Returns `{event_name, payload}` when any event is received.

  ## Options

  - `:timeout` - Timeout in milliseconds (optional)
  - `:timeout_value` - Value to return on timeout (optional)

  ## Examples

      {event, payload} = wait_for_any(["success", "failure", "cancelled"])

      {event, payload} = wait_for_any(["approved", "rejected"],
        timeout: hours(24),
        timeout_value: {:timeout, nil}
      )

  """
  @spec wait_for_any([String.t()], keyword()) :: {String.t(), term()}
  def wait_for_any(event_names, opts \\ []) when is_list(event_names) do
    # Check if we're resuming with event data already in context
    # Context keys are atoms (converted from strings when restored from DB)
    context = Process.get(:durable_context, %{})

    # Find first matching event in context (convert string names to atoms)
    case Enum.find(event_names, fn name -> Map.has_key?(context, String.to_atom(name)) end) do
      nil ->
        throw({:wait_for_any, Keyword.merge(opts, event_names: event_names, wait_type: :any)})

      event_name ->
        {event_name, Map.get(context, String.to_atom(event_name))}
    end
  end

  @doc """
  Waits for all of the specified events.

  Returns a map of `%{event_name => payload}` when all events are received.

  ## Options

  - `:timeout` - Timeout in milliseconds (optional)
  - `:timeout_value` - Value to return on timeout (optional)

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
    # Check if we're resuming with all events already in context
    # Context keys are atoms (converted from strings when restored from DB)
    context = Process.get(:durable_context, %{})
    atom_names = Enum.map(event_names, &String.to_atom/1)

    # Check if all events are in context
    if Enum.all?(atom_names, fn name -> Map.has_key?(context, name) end) do
      Map.take(context, atom_names)
    else
      throw({:wait_for_all, Keyword.merge(opts, event_names: event_names, wait_type: :all)})
    end
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
  - `:timeout_value` - Value to return on timeout
  - `:on_timeout` - `:resume` (default) or `:fail`

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
    # Check if we're resuming with input data already in context
    # Context keys are atoms (converted from strings when restored from DB)
    context = Process.get(:durable_context, %{})
    key = String.to_atom(input_name)

    case Map.get(context, key) do
      nil -> throw({:wait_for_input, Keyword.put(opts, :input_name, input_name)})
      data -> data
    end
  end

  # ============================================================================
  # Human Input - Convenience Wrappers
  # ============================================================================

  @doc """
  Waits for an approval decision.

  Returns `:approved`, `:rejected`, or `timeout_value` if timeout occurs.

  ## Options

  - `:prompt` - Prompt to show to the user
  - `:metadata` - Additional data for the UI to display
  - `:timeout` - Timeout in milliseconds
  - `:timeout_value` - Value to return on timeout

  ## Examples

      result = wait_for_approval("manager_approval")
      # => :approved | :rejected

      result = wait_for_approval("expense_approval",
        prompt: "Approve expense for $500?",
        metadata: %{employee: "John", amount: 500},
        timeout: days(3),
        timeout_value: :auto_approved
      )

  """
  @spec wait_for_approval(String.t(), keyword()) :: :approved | :rejected | term()
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
          %{value: :express, label: "Express ($15)"},
          %{value: :standard, label: "Standard (Free)"}
        ],
        timeout: hours(24),
        timeout_value: :standard
      )
      # => :express | :standard

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

  Returns a map of field values.

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
      # => %{laptop: "MacBook Pro", monitor: "27-inch", notes: "..."}

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
    now = DateTime.utc_now()

    # Find next business day
    find_next_business_day(now, hour)
  end

  defp find_next_business_day(date, hour) do
    next_day = DateTime.add(date, 1, :day)
    day_of_week = Date.day_of_week(DateTime.to_date(next_day))

    # Skip weekends (6 = Saturday, 7 = Sunday)
    if day_of_week in [6, 7] do
      find_next_business_day(next_day, hour)
    else
      next_day
      |> DateTime.to_date()
      |> DateTime.new!(Time.new!(hour, 0, 0, {0, 6}), "Etc/UTC")
    end
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
    now = DateTime.utc_now()

    target_day = weekday_number(weekday)
    current_day = Date.day_of_week(DateTime.to_date(now))

    days_until =
      if target_day > current_day do
        target_day - current_day
      else
        7 - current_day + target_day
      end

    now
    |> DateTime.add(days_until, :day)
    |> DateTime.to_date()
    |> DateTime.new!(Time.new!(hour, 0, 0, {0, 6}), "Etc/UTC")
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
    _timezone = Keyword.get(opts, :timezone, "UTC")

    DateTime.utc_now()
    |> DateTime.to_date()
    |> DateTime.new!(Time.new!(23, 59, 59, {0, 6}), "Etc/UTC")
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
    repo = get_repo(opts)

    with {:ok, pending} <- find_pending_input(repo, workflow_id, input_name),
         {:ok, _} <- complete_pending_input(repo, pending, data),
         {:ok, _} <- Durable.Executor.resume_workflow(workflow_id, %{input_name => data}, opts) do
      :ok
    end
  end

  # ============================================================================
  # External API - Send Event
  # ============================================================================

  @doc """
  Sends an event to a waiting workflow.

  ## Options

  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      Durable.send_event(workflow_id, "payment_confirmed", %{amount: 99.99})

  """
  @spec send_event(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def send_event(workflow_id, event_name, payload, opts \\ []) do
    repo = get_repo(opts)

    with {:ok, pending_event} <- find_pending_event(repo, workflow_id, event_name),
         {:ok, _} <- receive_pending_event(repo, pending_event, payload),
         {:ok, _} <- maybe_resume_workflow(repo, workflow_id, event_name, payload, opts) do
      :ok
    end
  end

  defp maybe_resume_workflow(repo, workflow_id, event_name, payload, opts) do
    # Check if this is part of a wait group
    case find_wait_group_for_event(repo, workflow_id, event_name) do
      {:ok, wait_group} ->
        # Update the wait group with the received event
        handle_wait_group_event(repo, wait_group, event_name, payload, opts)

      {:error, :not_found} ->
        # Single event - resume immediately
        event_data = %{event_name => payload}
        Durable.Executor.resume_workflow(workflow_id, event_data, opts)
    end
  end

  defp handle_wait_group_event(repo, wait_group, event_name, payload, opts) do
    {:ok, updated_group} =
      wait_group
      |> WaitGroup.add_event_changeset(event_name, payload)
      |> repo.update()

    if updated_group.status == :completed do
      # All required events received - resume workflow
      Durable.Executor.resume_workflow(
        updated_group.workflow_id,
        updated_group.received_events,
        opts
      )
    else
      {:ok, updated_group}
    end
  end

  # ============================================================================
  # External API - Cancel Wait
  # ============================================================================

  @doc """
  Cancels a waiting workflow.

  The workflow will resume with `{:cancelled, reason}`.

  ## Options

  - `:reason` - Cancellation reason (default: "cancelled")
  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      Durable.cancel_wait(workflow_id, reason: "User cancelled")

  """
  @spec cancel_wait(String.t(), keyword()) :: :ok | {:error, term()}
  def cancel_wait(workflow_id, opts \\ []) do
    repo = get_repo(opts)
    reason = Keyword.get(opts, :reason, "cancelled")

    with {:ok, execution} <- get_waiting_execution(repo, workflow_id),
         :ok <- cancel_pending_waits(repo, workflow_id),
         {:ok, _} <-
           Durable.Executor.resume_workflow(
             workflow_id,
             %{__cancelled__: true, reason: reason},
             opts
           ) do
      {:ok, execution}
      :ok
    end
  end

  defp cancel_pending_waits(repo, workflow_id) do
    # Cancel pending inputs
    from(p in PendingInput, where: p.workflow_id == ^workflow_id and p.status == :pending)
    |> repo.update_all(set: [status: :cancelled, completed_at: DateTime.utc_now()])

    # Cancel pending events
    from(p in PendingEvent, where: p.workflow_id == ^workflow_id and p.status == :pending)
    |> repo.update_all(set: [status: :cancelled, completed_at: DateTime.utc_now()])

    # Cancel wait groups
    from(w in WaitGroup, where: w.workflow_id == ^workflow_id and w.status == :pending)
    |> repo.update_all(set: [status: :cancelled, completed_at: DateTime.utc_now()])

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

  """
  @spec list_pending_inputs(keyword()) :: [map()]
  def list_pending_inputs(filters \\ []) do
    repo = get_repo(filters)
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

    repo.all(query)
    |> Enum.map(&pending_input_to_map/1)
  end

  @doc """
  Lists pending events for workflows.

  ## Filters

  - `:event_name` - Filter by event name
  - `:status` - Filter by status (default: :pending)
  - `:limit` - Maximum number of results (default: 50)
  - `:durable` - The Durable instance name (default: Durable)

  """
  @spec list_pending_events(keyword()) :: [map()]
  def list_pending_events(filters \\ []) do
    repo = get_repo(filters)
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
        nil -> query
        event_name -> from(p in query, where: p.event_name == ^event_name)
      end

    repo.all(query)
    |> Enum.map(&pending_event_to_map/1)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_repo(opts) do
    durable_name = Keyword.get(opts, :durable, Durable)
    Config.repo(durable_name)
  end

  defp find_pending_input(repo, workflow_id, input_name) do
    query =
      from(p in PendingInput,
        where:
          p.workflow_id == ^workflow_id and
            p.input_name == ^input_name and
            p.status == :pending
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      pending -> {:ok, pending}
    end
  end

  defp find_pending_event(repo, workflow_id, event_name) do
    query =
      from(p in PendingEvent,
        where:
          p.workflow_id == ^workflow_id and
            p.event_name == ^event_name and
            p.status == :pending
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      pending -> {:ok, pending}
    end
  end

  defp find_wait_group_for_event(repo, workflow_id, event_name) do
    query =
      from(w in WaitGroup,
        where:
          w.workflow_id == ^workflow_id and
            ^event_name in w.event_names and
            w.status == :pending
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      wait_group -> {:ok, wait_group}
    end
  end

  defp complete_pending_input(repo, pending, response) do
    pending
    |> PendingInput.complete_changeset(response)
    |> repo.update()
  end

  defp receive_pending_event(repo, pending_event, payload) do
    pending_event
    |> PendingEvent.receive_changeset(payload)
    |> repo.update()
  end

  defp get_waiting_execution(repo, workflow_id) do
    case repo.get(WorkflowExecution, workflow_id) do
      nil -> {:error, :not_found}
      %{status: :waiting} = execution -> {:ok, execution}
      _ -> {:error, :not_waiting}
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
