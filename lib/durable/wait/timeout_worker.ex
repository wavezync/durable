defmodule Durable.Wait.TimeoutWorker do
  @moduledoc """
  Background worker that enforces timeouts for pending inputs and events.

  Periodically checks for timed-out waits and either:
  - Resumes the workflow with the timeout_value (if on_timeout: :resume)
  - Fails the workflow (if on_timeout: :fail)
  """

  use GenServer

  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup}

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
    repo = config.repo

    # Find pending inputs that have timed out
    query =
      from(p in PendingInput,
        where:
          p.status == :pending and
            not is_nil(p.timeout_at) and
            p.timeout_at <= ^now,
        preload: [:workflow]
      )

    timed_out = repo.all(query)

    Enum.each(timed_out, fn pending_input ->
      handle_input_timeout(repo, pending_input, config)
    end)
  end

  defp handle_input_timeout(repo, pending_input, config) do
    # Mark as timed out
    {:ok, _} =
      pending_input
      |> PendingInput.timeout_changeset()
      |> repo.update()

    # Determine how to handle
    on_timeout = pending_input.on_timeout || :resume

    case on_timeout do
      :resume ->
        # Resume workflow with timeout value
        timeout_value = deserialize_timeout_value(pending_input.timeout_value)

        resume_data = %{
          pending_input.input_name => timeout_value,
          :__timeout__ => true
        }

        Durable.Executor.resume_workflow(
          pending_input.workflow_id,
          resume_data,
          durable: config.name
        )

      :fail ->
        # Cancel the workflow with timeout error
        reason = "Timeout waiting for input: #{pending_input.input_name}"
        Durable.Executor.cancel_workflow(pending_input.workflow_id, reason, durable: config.name)
    end

    Logger.info(
      "Timeout handled for pending input #{pending_input.input_name} " <>
        "in workflow #{pending_input.workflow_id} (#{on_timeout})"
    )
  end

  defp process_timed_out_events(config, now) do
    repo = config.repo

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

    timed_out = repo.all(query)

    Enum.each(timed_out, fn pending_event ->
      handle_event_timeout(repo, pending_event, config)
    end)
  end

  defp handle_event_timeout(repo, pending_event, config) do
    # Mark as timed out
    {:ok, _} =
      pending_event
      |> PendingEvent.timeout_changeset()
      |> repo.update()

    # Resume workflow with timeout value
    timeout_value = deserialize_timeout_value(pending_event.timeout_value)

    resume_data = %{
      pending_event.event_name => timeout_value,
      :__timeout__ => true
    }

    Durable.Executor.resume_workflow(
      pending_event.workflow_id,
      resume_data,
      durable: config.name
    )

    Logger.info(
      "Timeout handled for pending event #{pending_event.event_name} " <>
        "in workflow #{pending_event.workflow_id}"
    )
  end

  defp process_timed_out_wait_groups(config, now) do
    repo = config.repo

    # Find wait groups that have timed out
    query =
      from(w in WaitGroup,
        where:
          w.status == :pending and
            not is_nil(w.timeout_at) and
            w.timeout_at <= ^now,
        preload: [:workflow]
      )

    timed_out = repo.all(query)

    Enum.each(timed_out, fn wait_group ->
      handle_wait_group_timeout(repo, wait_group, config)
    end)
  end

  defp handle_wait_group_timeout(repo, wait_group, config) do
    # Mark wait group as timed out
    {:ok, _} =
      wait_group
      |> WaitGroup.timeout_changeset()
      |> repo.update()

    # Mark all related pending events as timed out
    from(p in PendingEvent,
      where: p.wait_group_id == ^wait_group.id and p.status == :pending
    )
    |> repo.update_all(set: [status: :timeout, completed_at: DateTime.utc_now()])

    # Resume workflow with timeout value and partial results
    timeout_value = deserialize_timeout_value(wait_group.timeout_value)

    resume_data =
      case wait_group.wait_type do
        :any ->
          # For wait_for_any, return {:timeout, nil} or timeout_value
          %{
            :__wait_group_result__ => timeout_value || {:timeout, nil},
            :__timeout__ => true
          }

        :all ->
          # For wait_for_all, return {:timeout, partial_results}
          partial = wait_group.received_events || %{}

          %{
            :__wait_group_result__ => timeout_value || {:timeout, partial},
            :__timeout__ => true
          }
      end

    Durable.Executor.resume_workflow(
      wait_group.workflow_id,
      resume_data,
      durable: config.name
    )

    Logger.info(
      "Timeout handled for wait group #{wait_group.id} " <>
        "(#{wait_group.wait_type}) in workflow #{wait_group.workflow_id}"
    )
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
