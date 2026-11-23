defmodule Durable.Wait.TimeoutWorker do
  @moduledoc """
  Background worker that enforces timeouts for pending inputs and events, and
  wakes waiting runs that passed their workflow `timeout:` so they fail now
  rather than when their wait ends. A run past its `timeout:` on a queue no
  live node polls is handed to a queue that is polled, since no worker will
  ever claim it where it is. The worker that claims it there fails it.

  Periodically checks for timed-out waits and either:
  - Resumes the workflow with the timeout_value (if on_timeout: :resume)
  - Fails the workflow (if on_timeout: :fail)
  """

  use GenServer

  alias Durable.EngineState
  alias Durable.Executor
  alias Durable.NodeRegistry
  alias Durable.Repo
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup, WorkflowExecution}

  import Ecto.Query

  require Logger

  @default_interval 60_000

  # How many overdue rows a sweep reads at a time. After a long outage the
  # backlog can be every wait there is.
  @default_batch_size 500

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the timeout worker.

  ## Options

  - `:config` - The Durable config (required)
  - `:interval` - Check interval in milliseconds (default: 60_000)
  - `:batch_size` - Rows a sweep reads at a time (default: 500)
  """
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    interval = Keyword.get(opts, :interval, @default_interval)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    GenServer.start_link(
      __MODULE__,
      %{config: config, interval: interval, batch_size: batch_size},
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
    do_check_timeouts(state)
    schedule_check(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:check_timeouts, state) do
    do_check_timeouts(state)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_check(interval) do
    Process.send_after(self(), :check_timeouts, interval)
  end

  defp do_check_timeouts(%{config: config, batch_size: batch_size}) do
    now = DateTime.utc_now()

    for sweep <- [
          &process_timed_out_inputs/3,
          &process_timed_out_events/3,
          &process_timed_out_wait_groups/3,
          &process_expired_runs/3,
          &process_overdue_rollbacks/3,
          &process_unpolled_runs/3
        ] do
      run_sweep(sweep, config, now, batch_size)
    end
  end

  # A row one sweep can't handle mustn't stop the others, or crash this process
  # over and over until it takes the node's Durable down with it.
  defp run_sweep(sweep, config, now, batch_size) do
    sweep.(config, now, batch_size)
  rescue
    error -> Logger.error("[Durable] timeout sweep failed: #{Exception.message(error)}")
  end

  # A failed run nobody retried or rolled back within its workflow's
  # `on_failure: [rollback_after: ms]` is rolled back, on a worker. Two nodes
  # sweeping at once ask twice, and the run's status lets one through.
  defp process_overdue_rollbacks(config, now, batch_size) do
    each_due(config, runs(:failed), :scheduled_at, now, batch_size, fn config, run ->
      Executor.rollback_workflow(run.id, durable: config.name)
    end)
  end

  # The runs in `status`, read light: a sweep needs only what it pages by.
  defp runs(status) do
    from(w in WorkflowExecution,
      where: w.status == ^status,
      select: struct(w, [:id, :scheduled_at, :deadline_at])
    )
  end

  # A waiting run past its deadline is resumed; the executor sees the deadline
  # before the step re-runs and fails the run (running its compensations).
  # Resume first, so an input answered at the same moment isn't marked timed
  # out; only then close the waits it no longer needs. In one transaction: a
  # sweep lost in between left a wait open on a failed run, and its retry
  # couldn't wait under that name again.
  defp process_expired_runs(config, now, batch_size) do
    each_due(config, runs(:waiting), :deadline_at, now, batch_size, fn config, run ->
      Repo.transaction(config, fn -> expire(config, run.id, now) end)
    end)
  end

  defp expire(config, id, now) do
    with {:ok, _} <- Executor.resume_workflow(id, %{}, durable: config.name),
         do: close_waits(config, id, now)
  end

  # A run past its deadline on a queue a live node polls is failed by the claim
  # that reaches it, so a paused or backlogged queue keeps its limits. On any
  # other queue no claim is coming, so it moves to one where it is.
  defp process_unpolled_runs(config, now, batch_size) do
    polled =
      for %{status: :alive, queues: queues} <- NodeRegistry.list(config),
          queue <- queues,
          uniq: true,
          do: queue

    unpolled = from(w in runs(:pending), where: w.queue not in ^polled)

    each_due(config, unpolled, :deadline_at, now, batch_size, fn config, run ->
      expire_unpolled(config, run.id, polled)
    end)
  end

  defp expire_unpolled(config, id, polled) do
    Executor.expire_unclaimed(id, polled, config)
  rescue
    # A node that doesn't have this workflow's code leaves it to one that does;
    # a crash here would only repeat on every sweep.
    error ->
      Logger.error("[Durable] couldn't time out run #{id}: #{Exception.message(error)}")
  end

  defp close_waits(config, workflow_id, now) do
    for schema <- [PendingInput, PendingEvent, WaitGroup] do
      Repo.update_all(
        config,
        from(p in schema, where: p.workflow_id == ^workflow_id and p.status == :pending),
        set: [status: :timeout, completed_at: now]
      )
    end
  end

  # The rows of `query` due by `field`, oldest first and a batch at a time,
  # each handed to `handle`. A node back after a day finds everything it has
  # overdue at once, and that is never one load. Each batch starts after the
  # last row of the one before, so a row that couldn't be handled is passed
  # by, for the next check, and the sweep ends: rows that never can be don't
  # keep the rest waiting behind them.
  defp each_due(config, query, field, now, batch_size, handle, last \\ nil) do
    rows =
      Repo.all(
        config,
        from(p in after_row(query, field, last),
          where: field(p, ^field) <= ^now,
          order_by: [asc: field(p, ^field), asc: p.id],
          limit: ^batch_size
        )
      )

    Enum.each(rows, &handle.(config, &1))

    if length(rows) == batch_size,
      do: each_due(config, query, field, now, batch_size, handle, List.last(rows))
  end

  defp after_row(query, _field, nil), do: query

  defp after_row(query, field, last) do
    at = Map.fetch!(last, field)

    from(p in query,
      where: field(p, ^field) > ^at or (field(p, ^field) == ^at and p.id > ^last.id)
    )
  end

  defp pending(schema), do: from(p in schema, where: p.status == :pending)

  defp process_timed_out_inputs(config, now, batch_size),
    do:
      each_due(
        config,
        pending(PendingInput),
        :timeout_at,
        now,
        batch_size,
        &handle_input_timeout/2
      )

  defp handle_input_timeout(config, pending_input) do
    on_timeout = pending_input.on_timeout || :resume

    # Atomic: mark the input :timeout AND transition the workflow back to
    # :pending in a single transaction. Before this change, a crash between
    # the two updates left the input as :timeout but the workflow stuck in
    # :waiting forever (Bug M-2).
    case atomic_resume_after_timeout(
           config,
           pending_input,
           input_timeout_data(on_timeout, pending_input)
         ) do
      {:ok, %{pending: {0, _}}} ->
        :ok

      {:ok, _} ->
        Logger.info(
          "Timeout handled for pending input #{pending_input.input_name} " <>
            "in workflow #{pending_input.workflow_id} (#{on_timeout})"
        )

      {:error, stage, reason, _changes} ->
        Logger.error(
          "Failed input timeout transaction for #{pending_input.workflow_id}: " <>
            "#{stage} → #{inspect(reason)}"
        )
    end
  end

  defp input_timeout_data(:resume, pending_input) do
    {%{pending_input.input_name => stored_timeout_value(pending_input.timeout_value)},
     %{"__timeout__" => true}}
  end

  # The executor fails the run at the waiting step, so compensations run and a
  # parent run hears about it.
  defp input_timeout_data(:fail, pending_input) do
    {%{},
     %{
       "__fail__" => %{
         "type" => "timeout",
         "message" => "Timeout waiting for input: #{pending_input.input_name}"
       }
     }}
  end

  # Only single events: one in a group times out with its group.
  defp process_timed_out_events(config, now, batch_size) do
    single =
      from(p in pending(PendingEvent), where: p.wait_type == :single and is_nil(p.wait_group_id))

    each_due(config, single, :timeout_at, now, batch_size, &handle_event_timeout/2)
  end

  defp handle_event_timeout(config, pending_event) do
    ended = %{pending_event.event_name => stored_timeout_value(pending_event.timeout_value)}

    # A call_workflow's wait is the engine's own, under the engine's own name.
    resume_data =
      case pending_event.event_name do
        "__child_done:" <> _child_id -> {%{}, Map.put(ended, "__timeout__", true)}
        _event_name -> {ended, %{"__timeout__" => true}}
      end

    case atomic_resume_after_timeout(config, pending_event, resume_data) do
      {:ok, %{pending: {0, _}}} ->
        :ok

      {:ok, _} ->
        Logger.info(
          "Timeout handled for pending event #{pending_event.event_name} " <>
            "in workflow #{pending_event.workflow_id}"
        )

        maybe_cancel_timed_out_child(config, pending_event.event_name)

      {:error, stage, reason, _changes} ->
        Logger.error(
          "Failed event timeout transaction for #{pending_event.workflow_id}: " <>
            "#{stage} → #{inspect(reason)}"
        )
    end
  end

  # A `call_workflow` parent waits on a PendingEvent named
  # `__child_done:<child_id>`. When that wait times out the parent resumes with
  # its `timeout_value`, but the child keeps running — wasted work whose result
  # is then silently dropped (and which could mutate shared state the parent
  # has moved past). Cancel the abandoned child so the timeout actually stops
  # it. Best-effort: a child that already finished/cancelled is a harmless no-op.
  defp maybe_cancel_timed_out_child(config, "__child_done:" <> child_id)
       when byte_size(child_id) > 0 do
    Logger.warning(
      "[Durable] call_workflow wait timed out — cancelling abandoned child #{child_id}"
    )

    Executor.cancel_workflow(child_id, "parent_call_timeout", durable: config.name)
  rescue
    e ->
      Logger.warning("[Durable] failed to cancel timed-out child #{child_id}: #{inspect(e)}")
      :ok
  end

  defp maybe_cancel_timed_out_child(_config, _event_name), do: :ok

  # Atomically: persist the pending row's :timeout transition AND flip the
  # owning workflow back to :pending with what the wait ended with merged into
  # its context and the engine's markers into its engine state. If either step
  # fails the entire transaction rolls back, so the workflow can never end up
  # "input/event marked timeout but workflow still stuck in :waiting".
  #
  # The sweep read the wait before it had the run's lock. Whoever held the lock
  # may have answered or cancelled it, so it is closed only if still pending,
  # and the run is left alone if it wasn't.
  #
  # `resume_data` is `{answer, engine}`: what the wait ends with, under the
  # wait's name in the user's data, and the engine's own markers.
  defp atomic_resume_after_timeout(config, %schema{} = wait, {answer, engine}) do
    safe_resume =
      {answer |> Executor.sanitize_for_json() |> EngineState.strip(),
       Executor.sanitize_for_json(engine)}

    now = DateTime.utc_now()

    multi =
      Ecto.Multi.new()
      |> Executor.lock_run(wait.workflow_id)
      |> Ecto.Multi.update_all(
        :pending,
        from(p in schema, where: p.id == ^wait.id and p.status == :pending),
        set: [status: :timeout, completed_at: now]
      )
      |> close_group_events(wait, now)
      |> Ecto.Multi.run(:workflow, fn repo, %{pending: {closed, _}} ->
        resume_timed_out(repo, wait.workflow_id, safe_resume, closed)
      end)

    Repo.transaction(config, multi)
  end

  defp close_group_events(multi, %WaitGroup{id: id}, now) do
    Ecto.Multi.update_all(
      multi,
      :pending_events,
      from(p in PendingEvent, where: p.wait_group_id == ^id and p.status == :pending),
      set: [status: :timeout, completed_at: now]
    )
  end

  defp close_group_events(multi, _wait, _now), do: multi

  defp resume_timed_out(_repo, _workflow_id, _resume, 0), do: {:ok, %{no_op: true}}

  defp resume_timed_out(repo, workflow_id, {user, engine}, _closed) do
    case EngineState.adopt(repo, repo.get(WorkflowExecution, workflow_id)) do
      nil ->
        {:error, :workflow_not_found}

      %WorkflowExecution{status: :waiting} = exec ->
        exec
        |> Ecto.Changeset.change(
          context: Map.merge(exec.context || %{}, user),
          engine_state: Map.merge(exec.engine_state, engine),
          status: :pending,
          locked_by: nil,
          locked_at: nil
        )
        |> repo.update()

      %WorkflowExecution{status: status} ->
        {:ok, %{status: status, no_op: true}}
    end
  end

  defp process_timed_out_wait_groups(config, now, batch_size),
    do:
      each_due(
        config,
        pending(WaitGroup),
        :timeout_at,
        now,
        batch_size,
        &handle_wait_group_timeout/2
      )

  # The wait reads what it got, and that it timed out, from its own group.
  defp handle_wait_group_timeout(config, wait_group) do
    case atomic_resume_after_timeout(config, wait_group, {%{}, %{"__timeout__" => true}}) do
      {:ok, %{pending: {0, _}}} ->
        :ok

      {:ok, _} ->
        log_wait_group_timeout_success(wait_group)

      {:error, stage, reason, _} ->
        Logger.error(
          "Failed wait_group timeout transaction for #{wait_group.workflow_id}: " <>
            "#{stage} → #{inspect(reason)}"
        )
    end
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

  # What the context shows the wait ended with. The wait itself returns the
  # call's own `:timeout_value`, so this copy is never turned back into a term:
  # an atom stays the text it was stored as.
  defp stored_timeout_value(%{"__atom__" => name}), do: name
  defp stored_timeout_value(%{"__value__" => value}), do: value
  defp stored_timeout_value(value), do: value
end
