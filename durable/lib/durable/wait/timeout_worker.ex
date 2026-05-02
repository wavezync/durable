defmodule Durable.Wait.TimeoutWorker do
  @moduledoc """
  Background worker that enforces timeouts for pending inputs and events.

  Periodically checks for timed-out waits and either:
  - Resumes the workflow with the timeout_value (if on_timeout: :resume)
  - Fails the workflow (if on_timeout: :fail)
  """

  use GenServer

  alias Durable.Executor
  alias Durable.Repo
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup, WorkflowExecution}

  import Ecto.Query

  require Logger

  @default_interval 60_000

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the timeout worker.

  ## Options

  - `:config` - The Durable config (required)
  - `:interval` - Check interval in milliseconds (default: 60_000)
  """
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    interval = Keyword.get(opts, :interval, @default_interval)

    GenServer.start_link(
      __MODULE__,
      %{config: config, interval: interval},
      name: worker_name(config.name)
    )
  end

  @doc """
  Returns the process name for a given Durable instance.
  """
  def worker_name(durable_name) do
    Module.concat([durable_name, Wait, TimeoutWorker])
  end

  @doc """
  Manually triggers a timeout check.
  """
  def check_timeouts(durable_name \\ Durable) do
    GenServer.cast(worker_name(durable_name), :check_timeouts)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(state) do
    schedule_check(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:check_timeouts, state) do
    do_check_timeouts(state.config)
    schedule_check(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:check_timeouts, state) do
    do_check_timeouts(state.config)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_check(interval) do
    Process.send_after(self(), :check_timeouts, interval)
  end

  defp do_check_timeouts(config) do
    now = DateTime.utc_now()

    process_timed_out_inputs(config, now)
    process_timed_out_events(config, now)
    process_timed_out_wait_groups(config, now)
  end

  defp process_timed_out_inputs(config, now) do
    # Find pending inputs that have timed out
    query =
      from(p in PendingInput,
        where:
          p.status == :pending and
            not is_nil(p.timeout_at) and
            p.timeout_at <= ^now,
        preload: [:workflow]
      )

    timed_out = Repo.all(config, query)

    Enum.each(timed_out, fn pending_input ->
      handle_input_timeout(config, pending_input)
    end)
  end

  defp handle_input_timeout(config, pending_input) do
    on_timeout = pending_input.on_timeout || :resume

    case on_timeout do
      :resume ->
        timeout_value = deserialize_timeout_value(pending_input.timeout_value)

        resume_data = %{
          pending_input.input_name => timeout_value,
          :__timeout__ => true
        }

        # Atomic: mark the input :timeout AND transition the workflow back
        # to :pending in a single transaction. Before this change, a crash
        # between the two updates left the input as :timeout but the workflow
        # stuck in :waiting forever (Bug M-2).
        result =
          atomic_resume_after_timeout(
            config,
            PendingInput.timeout_changeset(pending_input),
            pending_input.workflow_id,
            resume_data
          )

        case result do
          {:ok, _} ->
            Logger.info(
              "Timeout handled for pending input #{pending_input.input_name} " <>
                "in workflow #{pending_input.workflow_id} (resume)"
            )

          {:error, stage, reason, _changes} ->
            Logger.error(
              "Failed input timeout transaction for #{pending_input.workflow_id}: " <>
                "#{stage} → #{inspect(reason)}"
            )
        end

      :fail ->
        # Mark input :timeout then cancel — same Multi pattern.
        case atomic_cancel_after_timeout(
               config,
               PendingInput.timeout_changeset(pending_input),
               pending_input.workflow_id,
               "Timeout waiting for input: #{pending_input.input_name}"
             ) do
          {:ok, _} ->
            Logger.info(
              "Timeout handled for pending input #{pending_input.input_name} " <>
                "in workflow #{pending_input.workflow_id} (fail)"
            )

          {:error, stage, reason, _changes} ->
            Logger.error(
              "Failed input timeout transaction for #{pending_input.workflow_id}: " <>
                "#{stage} → #{inspect(reason)}"
            )
        end
    end
  end

  defp process_timed_out_events(config, now) do
    # Find pending events that have timed out (only single events, not in groups)
    query =
      from(p in PendingEvent,
        where:
          p.status == :pending and
            p.wait_type == :single and
            is_nil(p.wait_group_id) and
            not is_nil(p.timeout_at) and
            p.timeout_at <= ^now,
        preload: [:workflow]
      )

    timed_out = Repo.all(config, query)

    Enum.each(timed_out, fn pending_event ->
      handle_event_timeout(config, pending_event)
    end)
  end

  defp handle_event_timeout(config, pending_event) do
    timeout_value = deserialize_timeout_value(pending_event.timeout_value)

    resume_data = %{
      pending_event.event_name => timeout_value,
      :__timeout__ => true
    }

    case atomic_resume_after_timeout(
           config,
           PendingEvent.timeout_changeset(pending_event),
           pending_event.workflow_id,
           resume_data
         ) do
      {:ok, _} ->
        Logger.info(
          "Timeout handled for pending event #{pending_event.event_name} " <>
            "in workflow #{pending_event.workflow_id}"
        )

      {:error, stage, reason, _changes} ->
        Logger.error(
          "Failed event timeout transaction for #{pending_event.workflow_id}: " <>
            "#{stage} → #{inspect(reason)}"
        )
    end
  end

  # Atomically: persist the pending row's :timeout transition AND flip the
  # owning workflow back to :pending with the timeout payload merged into
  # context. If either step fails the entire transaction rolls back, so the
  # workflow can never end up "input/event marked timeout but workflow still
  # stuck in :waiting".
  defp atomic_resume_after_timeout(config, pending_changeset, workflow_id, resume_data) do
    safe_resume = Executor.sanitize_for_json(resume_data)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:pending, pending_changeset)
      |> Ecto.Multi.run(:workflow, fn repo, _changes ->
        case repo.get(WorkflowExecution, workflow_id) do
          nil ->
            {:error, :workflow_not_found}

          %WorkflowExecution{status: :waiting} = exec ->
            new_context = Map.merge(exec.context || %{}, safe_resume)

            exec
            |> Ecto.Changeset.change(
              context: new_context,
              status: :pending,
              locked_by: nil,
              locked_at: nil
            )
            |> repo.update()

          %WorkflowExecution{status: status} ->
            # The workflow already moved on (e.g. someone provided input
            # before the timeout sweep ran). Tolerate this — the pending
            # row is still marked :timeout via the Multi above, which is
            # the right outcome.
            {:ok, %{status: status, no_op: true}}
        end
      end)

    Repo.transaction(config, multi)
  end

  defp atomic_cancel_after_timeout(config, pending_changeset, workflow_id, reason) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:pending, pending_changeset)
      |> Ecto.Multi.run(:workflow, fn repo, _changes ->
        case repo.get(WorkflowExecution, workflow_id) do
          nil ->
            {:error, :workflow_not_found}

          %WorkflowExecution{} = exec ->
            exec
            |> WorkflowExecution.status_changeset(:cancelled, %{
              error: %{"type" => "timeout", "message" => reason},
              completed_at: DateTime.utc_now()
            })
            |> Ecto.Changeset.change(locked_by: nil, locked_at: nil)
            |> repo.update()
        end
      end)

    Repo.transaction(config, multi)
  end

  defp process_timed_out_wait_groups(config, now) do
    # Find wait groups that have timed out
    query =
      from(w in WaitGroup,
        where:
          w.status == :pending and
            not is_nil(w.timeout_at) and
            w.timeout_at <= ^now,
        preload: [:workflow]
      )

    timed_out = Repo.all(config, query)

    Enum.each(timed_out, fn wait_group ->
      handle_wait_group_timeout(config, wait_group)
    end)
  end

  defp handle_wait_group_timeout(config, wait_group) do
    resume_data = build_wait_group_resume_data(wait_group)

    case atomic_resume_after_wait_group_timeout(config, wait_group, resume_data) do
      {:ok, _} ->
        log_wait_group_timeout_success(wait_group)

      {:error, stage, reason, _} ->
        Logger.error(
          "Failed wait_group timeout transaction for #{wait_group.workflow_id}: " <>
            "#{stage} → #{inspect(reason)}"
        )
    end
  end

  # Builds the resume context for a timed-out wait group.
  #
  # Bug M-4: include per-event status in the resume payload so user code
  # can distinguish events that were :received from events that :timed_out.
  defp build_wait_group_resume_data(wait_group) do
    timeout_value = deserialize_timeout_value(wait_group.timeout_value)
    received = wait_group.received_events || %{}

    per_event_status =
      Map.new(wait_group.event_names || [], fn name ->
        case Map.get(received, name) do
          nil -> {name, %{"status" => "timeout", "value" => nil}}
          payload -> {name, %{"status" => "received", "value" => payload}}
        end
      end)

    fallback_result =
      case wait_group.wait_type do
        :any -> {:timeout, nil}
        :all -> {:timeout, received}
      end

    %{
      :__wait_group_result__ => timeout_value || fallback_result,
      :__wait_group_status__ => per_event_status,
      :__timeout__ => true
    }
  end

  defp log_wait_group_timeout_success(wait_group) do
    received_count = map_size(wait_group.received_events || %{})
    expected_count = length(wait_group.event_names || [])

    Logger.info(
      "Timeout handled for wait group #{wait_group.id} " <>
        "(#{wait_group.wait_type}) in workflow #{wait_group.workflow_id} — " <>
        "received #{received_count} of #{expected_count} events"
    )
  end

  defp atomic_resume_after_wait_group_timeout(config, wait_group, resume_data) do
    safe_resume = Executor.sanitize_for_json(resume_data)
    now = DateTime.utc_now()

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:wait_group, WaitGroup.timeout_changeset(wait_group))
      |> Ecto.Multi.update_all(
        :pending_events,
        from(p in PendingEvent,
          where: p.wait_group_id == ^wait_group.id and p.status == :pending
        ),
        set: [status: :timeout, completed_at: now]
      )
      |> Ecto.Multi.run(:workflow, fn repo, _changes ->
        case repo.get(WorkflowExecution, wait_group.workflow_id) do
          nil ->
            {:error, :workflow_not_found}

          %WorkflowExecution{status: :waiting} = exec ->
            new_context = Map.merge(exec.context || %{}, safe_resume)

            exec
            |> Ecto.Changeset.change(
              context: new_context,
              status: :pending,
              locked_by: nil,
              locked_at: nil
            )
            |> repo.update()

          %WorkflowExecution{status: status} ->
            {:ok, %{status: status, no_op: true}}
        end
      end)

    Repo.transaction(config, multi)
  end

  defp deserialize_timeout_value(nil), do: nil

  defp deserialize_timeout_value(%{"__atom__" => atom_string}) do
    String.to_existing_atom(atom_string)
  rescue
    ArgumentError -> String.to_atom(atom_string)
  end

  defp deserialize_timeout_value(%{"__value__" => value}), do: value
  defp deserialize_timeout_value(value) when is_map(value), do: value
end
