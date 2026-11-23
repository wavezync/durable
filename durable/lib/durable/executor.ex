defmodule Durable.Executor do
  @moduledoc """
  The main workflow executor.

  Responsible for:
  - Starting new workflow executions
  - Executing workflow steps sequentially
  - Managing workflow state and context
  - Handling workflow suspension and resumption
  """

  alias Durable.Activity
  alias Durable.Config
  alias Durable.Context
  alias Durable.Definition.Workflow
  alias Durable.EngineState
  alias Durable.Executor.CompensationRunner
  alias Durable.Executor.StepRunner
  alias Durable.Keys
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Query.Opts
  alias Durable.Queue.Drainer
  alias Durable.Repo
  alias Durable.Storage.Schemas.PendingEvent
  alias Durable.Storage.Schemas.PendingInput
  alias Durable.Storage.Schemas.StepExecution
  alias Durable.Storage.Schemas.WaitGroup
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query
  import Durable.Executor.StepRunner, only: [is_run_data: 1]

  require EngineState
  require Logger

  # The names below are keys of a run's `engine_state`, never of its context.
  #
  # Every save leaves this one, which is how a run is known to have saved a
  # context (see record_saved/2).
  @string_keys "__string_keys__"
  # Stored with a step's result: the step it is the result of, and for a
  # branch the arm it chose. A run that comes back to that step (it was
  # stopped, or its worker died, before it moved on) goes on from what follows,
  # not through it again on its own result: a parallel block isn't started a
  # second time, and a branch doesn't decide again.
  @done "__done__"
  # Put on a failed run by `rollback_workflow/2`, holding the error it failed
  # with: the worker that claims it runs its compensations and nothing else.
  @rollback "__rollback__"
  # What 1.5.0 recorded on a park instead. Kept for runs parked over an upgrade.
  @atom_keys "__atom_keys__"
  # What 2.0.0 recorded for a key written as both an atom and a string. No
  # longer read: the next save drops it.
  @atom_twins "__atom_twins__"

  @missing_code_retry_ms 30_000
  # As long as the scheduler gives a deploy to bring a schedule's code.
  @missing_code_grace_ms 15 * 60_000

  # A run in one of these is over, so no worker can be running an attempt of it.
  @ended [:completed, :failed, :cancelled, :compensated, :compensation_failed]

  @doc """
  Starts a new workflow execution.

  ## Options

  - `:workflow` - The workflow name (optional, uses default if not specified)
  - `:queue` - The queue to use (default: "default")
  - `:priority` - Priority level (default: 0)
  - `:scheduled_at` - Schedule for future execution
  - `:key` - Workflow key; see `Durable.start/3`
  - `:on_duplicate` - `:use_existing` or `:error` when the key is taken
  - `:durable` - The Durable instance name (default: Durable)

  ## Returns

  - `{:ok, workflow_id}` on success
  - `{:error, reason}` on failure
  """
  @spec start_workflow(module(), map(), keyword()) ::
          {:ok, String.t() | %{id: String.t(), created: boolean()}} | {:error, term()}
  def start_workflow(module, input, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)

    Keys.validate_start_opts!(opts)

    with {:ok, workflow_def} <- get_workflow_definition(module, opts),
         {:ok, safe_input} <- storable_input(input) do
      config
      |> create_execution(module, workflow_def, safe_input, opts)
      |> started(config, opts)
    end
  end

  @doc false
  @spec storable_input(term()) :: {:ok, map()} | {:error, :invalid_input}
  def storable_input(input) when not is_map(input), do: {:error, :invalid_input}

  # Every way a run is given its input comes through here, so this is where
  # the engine's own keys are dropped from it.
  def storable_input(input) do
    case sanitize_for_json(input) do
      map when not is_struct(map) -> {:ok, EngineState.strip(map)}
      _scalar -> {:error, :invalid_input}
    end
  end

  @doc """
  Starts one run per `{module, input}` or `{module, input, opts}` item, in one
  transaction (the caller's, if it is in one). `opts` applies to every item,
  under the item's own options. Returns one result per item, in order, each
  what `start_workflow/3` would have returned: keys are checked item by item.
  If the batch's key locks can't be taken, nothing is started and every item
  gets `{:error, reason}`.
  """
  @spec start_many([{module(), map()} | {module(), map(), keyword()}], keyword()) ::
          [{:ok, String.t() | map()} | {:error, term()}]
  def start_many(items, opts \\ []) do
    config = Config.get(Keyword.get(opts, :durable, Durable))

    items =
      Enum.map(items, fn
        {module, input} -> {module, input, opts}
        {module, input, item_opts} -> {module, input, Keyword.merge(opts, item_opts)}
      end)

    # ponytail: one insert per item, so keys and on_duplicate: are checked;
    # an insert_all for unkeyed items if thousands per call ever matter.
    result =
      Repo.transaction(config, fn ->
        lock_batch_keys(config, items)

        Enum.map(items, fn {module, input, item_opts} ->
          start_workflow(module, input, [wake: false] ++ item_opts)
        end)
      end)

    case result do
      {:ok, results} ->
        wake_committed(config, results)
        results

      {:error, reason} ->
        Enum.map(items, fn _item -> {:error, reason} end)
    end
  end

  # Every key the batch will touch, locked up front in one order. Taken item
  # by item, two batches naming the same keys in different orders deadlock.
  # A key that can't be stored raises from its own start, as it always has.
  defp lock_batch_keys(config, items) do
    names =
      for {module, _input, item_opts} <- items,
          key = item_opts[:key],
          is_binary(key) and not Repo.bad_text?(key),
          {:ok, workflow_def} <- [get_workflow_definition(module, item_opts)] do
        Keys.lock_name(module, workflow_def.name, key)
      end

    Keys.lock_all(config, names)
  end

  # One wake per queue, once the batch has committed.
  defp wake_committed(config, results) do
    ids = for {:ok, result} <- results, do: if(is_map(result), do: result.id, else: result)
    now = DateTime.utc_now()

    config
    |> Repo.all(
      from(w in WorkflowExecution,
        where: w.id in ^ids and w.status == :pending,
        where: is_nil(w.scheduled_at) or w.scheduled_at <= ^now,
        distinct: w.queue,
        select: %{status: w.status, queue: w.queue}
      )
    )
    |> Enum.each(&DurablePubSub.wake(config, &1))
  end

  defp started({:ok, execution}, config, opts) do
    DurablePubSub.broadcast_workflow(config, :workflow_started, workflow_event(execution))
    if Keyword.get(opts, :wake, true), do: DurablePubSub.wake(config, execution)

    # For inline/synchronous execution (useful for testing)
    if Keyword.get(opts, :inline, false) do
      execute_workflow(execution.id, config)
    end

    # Otherwise, the queue poller will pick up the job
    start_reply(execution.id, true, opts)
  end

  # The key is held: nothing was created, broadcast or run.
  defp started({:duplicate, holder_id, :use_existing}, _config, opts),
    do: start_reply(holder_id, false, opts)

  defp started({:duplicate, holder_id, :error}, _config, _opts),
    do: {:error, {:key_taken, holder_id}}

  defp started({:error, _} = error, _config, _opts), do: error

  defp start_reply(id, created, opts) do
    if opts[:return] == :details, do: {:ok, %{id: id, created: created}}, else: {:ok, id}
  end

  @doc """
  Cancels a running or pending workflow.
  """
  @spec cancel_workflow(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def cancel_workflow(workflow_id, reason \\ nil, opts \\ []) do
    if Repo.id?(workflow_id),
      do: cancel_run(workflow_id, reason, opts),
      else: {:error, :not_found}
  end

  defp cancel_run(workflow_id, reason, opts) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)

    error =
      storable_error(
        if reason, do: %{type: "cancelled", message: reason}, else: %{type: "cancelled"}
      )

    now = DateTime.utc_now()

    # One conditional UPDATE, so a run that finishes concurrently can't be
    # flipped back to :cancelled. Clearing the lock token fences the worker
    # still executing it: its ack/nack become no-ops, its next heartbeat stops
    # the step, and the executor's status compare-and-set stops it at the next
    # step boundary if the step finishes first.
    #
    # A run back on its queue to be undone is left to it: cancelled, it would
    # end with nothing undone, and could be neither rolled back nor retried.
    cancellable =
      from(w in WorkflowExecution,
        where: w.id == ^workflow_id and w.status in [:pending, :running, :waiting],
        where: not EngineState.marked?(w, ^@rollback),
        select: w
      )

    seen = opts[:rollback] && status_now(config, workflow_id)
    cancellable = if seen, do: where(cancellable, [w], w.status == ^seen), else: cancellable

    set = [
      status: :cancelled,
      error: error,
      completed_at: now,
      updated_at: now,
      locked_by: nil,
      locked_at: nil,
      lock_token: nil
    ]

    {:ok, cancelled} =
      Repo.transaction(config, fn -> cancel_and_queue(config, cancellable, set, opts) end)

    if cancelled do
      # To be undone, the step a worker is running stays open: it may finish
      # before the worker hears of the cancel, and then it is undone too. The
      # worker closes it as it stops, or the undo if that worker is gone.
      after_cancel(config, cancelled, seen != :running)
      if opts[:rollback], do: undo_once_stopped(config, cancelled, seen)
      :ok
    else
      not_cancelled(status_now(config, workflow_id), seen, {workflow_id, reason, opts})
    end
  end

  # With `rollback: true` the run goes back on its queue to be undone in the
  # transaction that cancels it. Seen cancelled and over in between, a run
  # waiting behind its key would start before the undo.
  defp cancel_and_queue(config, cancellable, set, opts) do
    case Repo.update_all(config, cancellable, set: set) do
      {1, [cancelled]} ->
        if opts[:rollback], do: queue_cancelled(config, cancelled)
        cancelled

      {0, _} ->
        nil
    end
  end

  # A rollback has to know whether a worker had the run, so its cancel only
  # lands on the status it saw. A run queued to be undone is being undone.
  defp status_now(config, workflow_id) do
    run = from(w in WorkflowExecution, where: w.id == ^workflow_id)

    case Repo.one(config, from(w in run, select: {w.status, EngineState.marked?(w, ^@rollback)})) do
      {status, false} -> status
      {_queued, true} -> :compensating
      nil -> nil
    end
  end

  defp not_cancelled(nil, _seen, _cancel), do: {:error, :not_found}

  # It moved between the read and the cancel: go by what it is now.
  defp not_cancelled(status, seen, {workflow_id, reason, opts})
       when seen != nil and status in [:pending, :running, :waiting],
       do: cancel_run(workflow_id, reason, opts)

  defp not_cancelled(_ended, _seen, _cancel), do: {:error, :already_completed}

  # `rollback: true`: the cancelled run goes back on its queue to be undone.
  # A worker that had it is told at its next heartbeat, and until then a step
  # of its can still finish. The undo waits that long, so it sees that step,
  # and as long while the cancel goes on to stop the runs under it.
  #
  # A run that never started has nothing to undo. Back on its queue it would
  # still be its key's holder, a run yet to come, to the next start.
  defp queue_cancelled(_config, %{started_at: nil}), do: :ok

  defp queue_cancelled(config, cancelled) do
    at = DateTime.add(DateTime.utc_now(), config.heartbeat_interval, :millisecond)
    {:ok, _queued} = queue_rollback(config, cancelled, at)
  end

  # Once the runs under it are stopped, a run nobody was running is undone a
  # heartbeat after the last of them (settles_at/2), or now. One a worker had
  # waits the heartbeat it was queued with.
  defp undo_once_stopped(_config, _cancelled, :running), do: :ok
  defp undo_once_stopped(_config, %{started_at: nil}, _seen), do: :ok

  defp undo_once_stopped(config, cancelled, _seen) do
    {_, queued} =
      Repo.update_all(
        config,
        from(w in WorkflowExecution,
          where: w.id == ^cancelled.id and w.status == :pending and is_nil(w.locked_by),
          select: w
        ),
        set: [scheduled_at: settles_at(config, cancelled)]
      )

    for run <- queued, do: DurablePubSub.wake(config, run)
  end

  @doc """
  Cancels every pending, running or waiting run that matches `filters` (those
  of `Durable.Query.list_executions/1`, without `:limit` and `:offset`), one
  by one as `cancel_workflow/3` would. Returns how many it cancelled.
  """
  @spec cancel_all(keyword(), String.t() | nil) :: {:ok, non_neg_integer()}
  def cancel_all(filters, reason \\ nil) do
    {durable, filters} = Keyword.pop(filters, :durable, Durable)
    filters = Keyword.drop(filters, [:limit, :offset])

    # Guard against cancel_all([]) cancelling every run there is.
    if filters == [] do
      raise ArgumentError, "Durable.cancel_all/2 needs at least one filter, such as tag:"
    end

    # A filter the query would skip (a misspelt name, a nil, a value of the
    # wrong type) is the same thing: `cancel_all(tag: tag)` with `tag` unset
    # must not cancel everything.
    skipped = Enum.reject(filters, &narrows?/1)

    cond do
      # No run has an empty tag, key or name.
      Enum.any?(filters, fn {_name, value} -> value in ["", []] end) -> {:ok, 0}
      skipped != [] -> raise ArgumentError, skipped_filters(skipped)
      true -> cancel_matching(durable, filters, reason)
    end
  end

  defp narrows?(filter), do: Durable.Query.executions_query([filter]).wheres != []

  defp skipped_filters(skipped) do
    "Durable.cancel_all/2 can't filter on #{inspect(skipped)}, and won't cancel " <>
      "every other run instead"
  end

  defp cancel_matching(durable, filters, reason) do
    ids =
      Repo.all(
        Config.get(durable),
        filters
        |> Durable.Query.executions_query()
        |> where([w], w.status in [:pending, :running, :waiting])
        |> select([w], w.id)
      )

    # A cancel cascades to children, which may be in `ids` too.
    {:ok, Enum.count(ids, &(cancel_workflow(&1, reason, durable: durable) == :ok))}
  end

  @doc """
  Resumes a failed workflow at the step that failed.

  Completed steps are not re-run: the run continues from its saved context,
  and the failed step gets its full retry budget again. A failure inside a
  parallel block re-queues only the children that failed; the ones that
  completed keep their results.

  Runs that were rolled back by compensation can't be resumed — their
  earlier effects were undone — so use `rerun_workflow/2` for those.
  """
  @spec retry_workflow(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def retry_workflow(workflow_id, opts \\ []) do
    config = Config.get(Keyword.get(opts, :durable, Durable))

    with {:ok, execution} <- load_execution(config, workflow_id),
         :ok <- ensure_retryable(execution.status),
         :ok <- nothing_undone(config, execution),
         {:ok, retried} <- reset_for_retry(config, execution) do
      DurablePubSub.broadcast_workflow(config, :workflow_retried, workflow_event(retried))
      DurablePubSub.wake(config, retried)
      {:ok, workflow_id}
    end
  end

  @doc """
  Undoes a failed run: runs the `compensate:` of every step that completed,
  newest first, on a worker.

  For a run that failed and was left as it was (`on_failure: :halt`, the
  default) once it's clear it shouldn't be retried. The run ends
  `:compensated`, or `:compensation_failed` if an undo failed, and can't be
  retried after. A run with nothing to undo stays `:failed`.
  """
  @spec rollback_workflow(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def rollback_workflow(workflow_id, opts \\ []) do
    config = Config.get(Keyword.get(opts, :durable, Durable))

    with {:ok, execution} <- load_execution(config, workflow_id),
         :ok <- ensure_retryable(execution.status),
         {:ok, queued} <- queue_rollback(config, execution) do
      DurablePubSub.wake(config, queued)
      {:ok, workflow_id}
    end
  end

  @doc """
  What `rollback_workflow/2` would run: the compensation of every step that
  completed, newest first, as `{step, compensation}` names, in `{:ok, plan}`.
  Empty when there is nothing to undo or the run's code isn't on this node,
  and `{:error, :not_found}` for an id that isn't a run.
  """
  @spec rollback_plan(String.t(), keyword()) ::
          {:ok, [{atom(), atom()}]} | {:error, Opts.reason()}
  def rollback_plan(workflow_id, opts \\ []) do
    with {:ok, opts} <- Opts.validate(opts),
         config = Config.get(Keyword.get(opts, :durable, Durable)),
         {:ok, execution} <- load_execution(config, workflow_id) do
      {:ok, compensations_of(execution, config)}
    end
  end

  defp compensations_of(execution, config) do
    case get_workflow_definition_from_execution(execution) do
      {:ok, workflow_def} ->
        for {step, compensation} <- build_compensation_stack(execution.id, workflow_def, config),
            do: {step, compensation.name}

      _code_not_here ->
        []
    end
  end

  defp queue_rollback(config, execution, at \\ nil) do
    execution
    |> Ecto.Changeset.change(
      status: :pending,
      engine_state:
        Map.put(execution.engine_state, @rollback, %{
          "error" => execution.error || %{},
          "status" => Atom.to_string(execution.status)
        }),
      completed_at: nil,
      scheduled_at: at,
      locked_by: nil,
      locked_at: nil,
      lock_token: nil
    )
    |> without_key(execution)
    |> cas_update(config)
    |> not_failed_if_superseded()
  end

  # A run being undone is over for its key: it failed or was cancelled, and a
  # start may take the key from such a run unless the workflow says
  # `reuse: :never`. Kept until it was undone, the key would hand that start a
  # run that does no work. If the undo finds nothing to do and the run is left
  # failed, a retry takes the key back as for any run that lost it.
  defp without_key(changeset, %{holds_key: true} = execution) do
    with {:ok, workflow_def} <- get_workflow_definition_from_execution(execution),
         true <- Keys.reuse(workflow_def) != :never do
      Ecto.Changeset.change(changeset, holds_key: false)
    else
      _ -> changeset
    end
  end

  defp without_key(changeset, _execution), do: changeset

  defp ensure_retryable(:failed), do: :ok

  defp ensure_retryable(status) when status in [:compensated, :compensation_failed],
    do: {:error, :rolled_back}

  defp ensure_retryable(_status), do: {:error, :not_failed}

  # A rollback that lost its worker part-way leaves the run failed with some of
  # it undone. Retried, it would carry on as if none of it was.
  defp nothing_undone(config, execution) do
    if Repo.aggregate(config, undone(execution.id), :count) > 0,
      do: {:error, :rolled_back},
      else: :ok
  end

  defp reset_for_retry(config, execution) do
    retry_attrs = [
      error: nil,
      completed_at: nil,
      retried_at: DateTime.utc_now(),
      scheduled_at: nil,
      locked_by: nil,
      locked_at: nil,
      lock_token: nil,
      deadline_at: retried_deadline(execution)
    ]

    cond do
      parallel_children(execution.engine_state) ->
        retry_parallel_block(config, execution, retry_attrs)

      execution.key && not execution.holds_key ->
        retry_and_retake(config, execution, retry_attrs)

      execution.key ->
        retry_holder(config, execution, retry_attrs)

      true ->
        execution
        |> Ecto.Changeset.change([status: :pending] ++ retry_attrs)
        |> reopen(config, retry_attrs)
        |> not_failed_if_superseded()
    end
  end

  # Reopens a run and puts back the child workflows that were stopped with it:
  # its timeout cancelled them, and its step would find its child cancelled
  # and fail again. In one transaction, or a worker could claim the run before
  # its child is back.
  defp reopen(changeset, config, retry_attrs, opts \\ []) do
    {:ok, result} =
      Repo.transaction(config, fn ->
        with {:ok, retried} = ok <- cas_update(changeset, config, opts) do
          put_back_called(config, [retried.id], retry_attrs)
          ok
        end
      end)

    result
  end

  # Reopens a run that holds its key, only if it still does: a start may be
  # taking the key from it right now, and reopened regardless, the two would
  # both run. If the key went, this is a retry that has to take it back.
  defp retry_holder(config, execution, retry_attrs) do
    changeset = Ecto.Changeset.change(execution, [status: :pending] ++ retry_attrs)

    case reopen(%{changeset | filters: %{holds_key: true}}, config, retry_attrs) do
      {:error, :superseded} ->
        with {:ok, lost} <- lost_its_key(config, execution),
             do: retry_and_retake(config, lost, retry_attrs)

      result ->
        result
    end
  end

  # Why a reopen that asked for `holds_key` found nothing: the run as it is
  # now if it's still failed and only its key went, or it was retried already.
  defp lost_its_key(config, execution) do
    case load_execution(config, execution.id) do
      {:ok, %{status: :failed, holds_key: false} = lost} -> {:ok, lost}
      _retried_or_gone -> {:error, :not_failed}
    end
  end

  # A run whose key moved to another run takes it back by the start rules
  # (releasing a closed holder `reuse:` lets go) in the same transaction that
  # reopens it, or the retry is refused with {:key_taken, holder_id}.
  defp retry_and_retake(config, execution, retry_attrs) do
    # The key's lock rolls the transaction back when it can't be taken.
    with {:ok, result} <-
           Repo.transaction(config, fn -> retake_and_reopen(config, execution, retry_attrs) end),
         do: result
  end

  defp retake_and_reopen(config, execution, retry_attrs) do
    with {:ok, key_attrs} <- Keys.retake(config, execution, definition_or_nil(execution)) do
      execution
      |> Ecto.Changeset.change([status: :pending] ++ retry_attrs ++ key_attrs)
      |> Ecto.Changeset.unique_constraint(:key, name: :workflow_executions_key_holder_index)
      |> reopen(config, retry_attrs, mode: :savepoint)
      |> not_failed_if_superseded()
      |> key_taken_if_conflict(config, execution)
    end
  end

  defp key_taken_if_conflict({:error, %Ecto.Changeset{} = changeset} = error, config, execution) do
    if Keys.key_taken?(changeset), do: Keys.key_taken_error(config, execution), else: error
  end

  defp key_taken_if_conflict(result, _config, _execution), do: result

  # A retried run gets its full workflow timeout again, from now.
  defp retried_deadline(execution) do
    case get_workflow_definition_from_execution(execution) do
      {:ok, workflow_def} -> deadline(workflow_def, nil)
      _ -> execution.deadline_at
    end
  end

  defp parallel_children(engine_state), do: Map.get(engine_state, "__parallel_children")

  # A run that failed inside a parallel block is waiting on a WaitGroup of
  # child runs. Re-queue only the children that failed, re-open their
  # completion events and the group, and park the parent in :waiting again —
  # the last child to finish wakes it, exactly as on the first pass.
  defp retry_parallel_block(config, parent, retry_attrs) do
    case Repo.transaction(config, fn -> reopen_parallel_block(config, parent, retry_attrs) end) do
      # As in retry_holder/3: a start took the key while this reopened the run.
      {:error, :not_failed} when parent.holds_key ->
        with {:ok, lost} <- lost_its_key(config, parent),
             do: retry_parallel_block(config, lost, retry_attrs)

      result ->
        result
    end
  end

  defp still_holding(changeset, %{holds_key: true}),
    do: %{changeset | filters: %{holds_key: true}}

  defp still_holding(changeset, _parent), do: changeset

  defp reopen_parallel_block(config, parent, retry_attrs) do
    key_attrs =
      case Keys.retake(config, parent, definition_or_nil(parent)) do
        {:ok, attrs} -> attrs
        {:error, reason} -> config.repo.rollback(reason)
      end

    # Every child had finished and the block failed after them (its `into:`,
    # say): nothing is left to wait for, so the run reads their results again.
    status =
      if stopped_block?(config, parent.engine_state) do
        reopen_children(config, parent.engine_state, retry_attrs)
        :waiting
      else
        :pending
      end

    parent
    |> Ecto.Changeset.change([status: status] ++ retry_attrs ++ key_attrs)
    |> still_holding(parent)
    |> Ecto.Changeset.unique_constraint(:key, name: :workflow_executions_key_holder_index)
    |> reopen(config, retry_attrs, mode: :savepoint)
    |> not_failed_if_superseded()
    |> key_taken_if_conflict(config, parent)
    |> case do
      {:ok, retried} -> retried
      {:error, reason} -> config.repo.rollback(reason)
    end
  end

  # Puts the children of a block that stopped back to work, and re-opens the
  # events and the group the block waits on. A lane can hold a block of its
  # own: if that one stopped too, the lane waits on it again and its children
  # are put back the same way, or the lane would wake to the old failure.
  defp reopen_children(config, engine_state, retry_attrs) do
    child_ids = Map.keys(parallel_children(engine_state))
    group_id = engine_state["__parallel_wait_group_id"]
    now = DateTime.utc_now()

    children =
      config
      |> Repo.all(
        from(c in WorkflowExecution, where: c.id in ^child_ids and c.status != :completed)
      )
      |> Enum.map(&EngineState.adopt(config, &1))

    if Enum.any?(children, &(&1.status in [:compensated, :compensation_failed])),
      do: config.repo.rollback(:rolled_back)

    stopped =
      for child <- children,
          child.status in [:failed, :cancelled],
          do: {child.id, child.engine_state}

    # A lane with a `timeout:` gets all of it again, and what is put back under
    # the lane has until then too.
    for {id, _state} = lane <- stopped do
      ms = parallel_children(engine_state)[id]["timeout"]
      put_back(config, [lane], Keyword.update!(retry_attrs, :deadline_at, &lane_deadline(&1, ms)))
    end

    reopen_group(config, group_id, %{
      # Every lane that hasn't completed is waited for again, the one already
      # retried by its own id and running included: its failure isn't its answer.
      stopped: Enum.map(children, &"__parallel_done:#{&1.id}"),
      # A child can finish after its block stopped, when nobody was counting
      # any more. The group is told now, or it would wait for it for ever.
      finished: for(id <- child_ids -- Enum.map(children, & &1.id), do: "__parallel_done:#{id}"),
      now: now
    })
  end

  # Stopped runs go back to work: one that waits on a block of its own waits
  # on it again, with that block's children put back the same way. The child
  # workflows a run was waiting for (`call_workflow`) were cancelled with it,
  # and are put back too, or the run would wake to find its child cancelled.
  defp put_back(_config, [], _retry_attrs), do: :ok

  defp put_back(config, stopped, retry_attrs) do
    {blocks, steps} =
      Enum.split_with(stopped, fn {_id, state} -> stopped_block?(config, state) end)

    for {runs, status} <- [{steps, :pending}, {blocks, :waiting}] do
      Repo.update_all(
        config,
        from(c in WorkflowExecution, where: c.id in ^Enum.map(runs, &elem(&1, 0))),
        set: [status: status, updated_at: DateTime.utc_now()] ++ retry_attrs
      )
    end

    for {_id, state} <- blocks, do: reopen_children(config, state, retry_attrs)

    put_back_called(config, Enum.map(steps, &elem(&1, 0)), retry_attrs)
  end

  # A child workflow has its own `timeout:`, and gets all of that again.
  defp put_back_called(config, parent_ids, retry_attrs) do
    called =
      Repo.all(
        config,
        from(c in WorkflowExecution,
          where: c.parent_workflow_id in ^parent_ids,
          where: c.status == :cancelled and c.error["message"] == "parent_cancelled"
        )
      )

    for child <- called do
      attrs = Keyword.put(retry_attrs, :deadline_at, retried_deadline(child))
      put_back(config, [{child.id, EngineState.adopt(config, child).engine_state}], attrs)
    end
  end

  defp reopen_group(config, group_id, %{stopped: stopped, finished: finished, now: now}) do
    events = from(e in PendingEvent, where: e.wait_group_id == ^group_id)

    Repo.update_all(config, from(e in events, where: e.event_name in ^stopped),
      set: [status: :pending, payload: nil, completed_at: nil, updated_at: now]
    )

    Repo.update_all(
      config,
      from(e in events, where: e.event_name in ^finished and e.status != :received),
      set: [status: :received, updated_at: now]
    )

    group = Repo.get(config, WaitGroup, group_id)

    received =
      Enum.reduce(finished, Map.drop(group.received_events, stopped), &Map.put_new(&2, &1, %{}))

    {:ok, _} =
      group
      |> Ecto.Changeset.change(status: :pending, completed_at: nil, received_events: received)
      |> Repo.update(config)
  end

  # Whether a run stopped while a block of its own still had children to finish.
  defp stopped_block?(config, engine_state) do
    case parallel_children(engine_state) do
      nil ->
        false

      children ->
        ids = Map.keys(children)

        open = from(c in WorkflowExecution, where: c.id in ^ids and c.status != :completed)
        Repo.one(config, from(c in open, select: count(c.id))) > 0
    end
  end

  defp definition_or_nil(execution) do
    case get_workflow_definition_from_execution(execution) do
      {:ok, definition} -> definition
      _ -> nil
    end
  end

  defp not_failed_if_superseded({:error, :superseded}), do: {:error, :not_failed}
  defp not_failed_if_superseded(result), do: result

  @doc """
  Starts a fresh run of the same workflow, with the original input unless
  `:input` is given. The new run records which run it re-runs.

  Only finished runs (completed, failed, cancelled or rolled back) can be
  re-run, so an operator can't accidentally double up live work.
  """
  @spec rerun_workflow(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def rerun_workflow(workflow_id, opts \\ []) do
    durable = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable)

    with {:ok, execution} <- load_execution(config, workflow_id),
         # A run being rolled back is still going: its undo races the rerun.
         true <-
           execution.status not in WorkflowExecution.open_statuses() || {:error, :not_finished},
         # A lane is part of its block's run. Started on its own it would be
         # the whole workflow again, from its first step, on the block's data.
         true <- not parallel_branch?(execution) || {:error, :lane},
         {:ok, _definition} <- get_workflow_definition_from_execution(execution) do
      start_workflow(
        String.to_existing_atom(execution.workflow_module),
        Keyword.get(opts, :input, execution.input),
        workflow: execution.workflow_name,
        queue: execution.home_queue || execution.queue,
        priority: execution.priority,
        durable: durable,
        trigger: :rerun,
        trigger_ref: execution.id,
        tags: execution.tags,
        # Keyed runs rerun under the start rules, and an operator should hear
        # why a rerun was refused rather than get the holder back.
        key: execution.key,
        on_duplicate: :error
      )
    end
  end

  # Moves a run past its deadline off a queue no live node polls, from the
  # timeout sweep: to the queue it came from if that one is polled, else to one
  # that is. The claim there fails it before its next step, so its compensations
  # run in a worker, under that queue's limits, and not in the sweep. The update
  # goes through the row's status and queue, so it can't overlap a poller or
  # another node's sweep. A parallel branch has no deadline check; its parent's
  # timeout cancels it. With no polled queue anywhere it stays until a node
  # shows up.
  @doc false
  @spec expire_unclaimed(String.t(), [String.t()], Config.t()) :: term()
  def expire_unclaimed(workflow_id, polled, %Config{} = config) do
    with {:ok, execution} <- load_execution(config, workflow_id),
         false <- parallel_branch?(execution),
         {:ok, _workflow_def} <- get_workflow_definition_from_execution(execution),
         home = execution.home_queue || execution.queue,
         queue when is_binary(queue) <- Enum.find([home, "default" | polled], &(&1 in polled)),
         {1, _} <- hand_over(config, execution, queue, if(queue != home, do: home)) do
      DurablePubSub.wake(config, %{status: :pending, queue: queue})
    end
  end

  defp hand_over(config, execution, queue, home_queue) do
    Repo.update_all(
      config,
      from(w in WorkflowExecution,
        where: w.id == ^execution.id and w.status == :pending and w.queue == ^execution.queue
      ),
      set: [queue: queue, home_queue: home_queue, scheduled_at: nil]
    )
  end

  @doc """
  Executes a workflow by ID.

  This is called internally by queue workers or directly for immediate execution.

  A worker passes the `lock_token` of its claim. The claim may have been taken
  from it before it got here, and then the run is another worker's: nothing
  runs, and this returns `{:error, :superseded}`.
  """
  @spec execute_workflow(String.t(), Config.t(), String.t() | nil) ::
          {:ok, map()} | {:waiting, map()} | {:error, term()}
  def execute_workflow(workflow_id, %Config{} = config, lock_token \\ nil) do
    with {:ok, execution} <- load_execution(config, workflow_id),
         true <- execution.status in [:pending, :running] || {:error, :superseded},
         true <- lock_token in [nil, execution.lock_token] || {:error, :superseded},
         {:ok, workflow_def} <- definition_or_leave(config, execution),
         {:ok, execution} <- take_waiting_key(config, execution, workflow_def),
         resumed = execution.current_step != nil,
         {:ok, execution} <- mark_running(config, execution) do
      # Set workflow ID for logging/observability
      Context.set_workflow_id(execution.id)
      Context.set_input(execution.input)

      meta = %{
        durable: config.name,
        workflow_id: execution.id,
        workflow: execution.workflow_name,
        workflow_module: execution.workflow_module,
        queue: execution.queue,
        key: execution.key,
        tags: execution.tags,
        trigger: execution.trigger,
        resumed: resumed,
        root_workflow_id: execution.root_workflow_id || execution.id,
        telemetry_span_context: execution.id
      }

      Durable.Telemetry.put_run_meta(meta, workflow_def.opts[:log_metadata])
      run_segment(meta, execution, workflow_def, config)
    end
  end

  # Whoever closed this segment's attempt has sent its end events, the
  # segment's included, so losing the attempt ends it here without another.
  defp run_segment(meta, execution, workflow_def, config) do
    Durable.Telemetry.span([:durable, :workflow], meta, fn ->
      result = run_until_superseded(execution, workflow_def, config)
      {result, Map.put(meta, :status, segment_status(config, execution.id, result))}
    end)
  catch
    :throw, :durable_attempt_closed ->
      Context.cleanup()
      {:error, :superseded}
  end

  # In a rolling deploy this node may not have the code yet. The run goes back
  # for one that does, or waits for an operator if none ever does: failing it
  # here would throw it away over a deploy. Its deadline still ends the wait,
  # once it's past by longer than a deploy takes. That run fails without its
  # compensations, which are in the code nobody has.
  defp definition_or_leave(config, execution) do
    with {:error, reason} <- get_workflow_definition_from_execution(execution) do
      if past_deadline_by?(execution, @missing_code_grace_ms) and not to_roll_back?(execution),
        do: time_out_without_code(config, execution),
        else: leave_for_its_code(config, execution, reason)
    end
  end

  # Back on its queue to be undone, not to run: its deadline, long past by
  # now, says nothing, and timing it out would drop the undo and its error.
  defp to_roll_back?(execution), do: is_map_key(execution.engine_state, @rollback)

  defp leave_for_its_code(config, execution, reason) do
    Logger.warning(
      "[Durable] #{execution.workflow_module} (#{execution.workflow_name}) isn't on this " <>
        "node (#{inspect(reason)}), leaving run #{execution.id} for one that has it"
    )

    execution
    |> Ecto.Changeset.change(
      status: :pending,
      # Not capped at the deadline: past it, the run would be due again at once.
      scheduled_at: DateTime.add(DateTime.utc_now(), @missing_code_retry_ms, :millisecond),
      locked_by: nil,
      locked_at: nil,
      lock_token: nil
    )
    |> cas_update(config)
    |> case do
      {:ok, parked} -> {:waiting, parked}
      superseded -> superseded
    end
  end

  defp time_out_without_code(config, execution) do
    cancel_child_workflows(config, execution.id)

    mark_failed(config, execution, %{
      type: "timeout",
      message:
        "the run passed its timeout, and no node has #{execution.workflow_module} " <>
          "(#{execution.workflow_name}) to run it or its compensations"
    })
  catch
    :throw, :durable_superseded -> {:error, :superseded}
  end

  defp segment_status(_config, _id, {:ok, _}), do: :completed
  defp segment_status(_config, _id, {:waiting, _}), do: :waiting
  defp segment_status(_config, _id, {:error, :superseded}), do: :superseded

  # A failure may have been compensated; the row has the final word.
  defp segment_status(config, id, {:error, _}) do
    Repo.one(config, from(w in WorkflowExecution, where: w.id == ^id, select: w.status))
  end

  # A status compare-and-set deep in the step loop throws when another actor
  # (cancel, stale-lock recovery) changed the run's status under us.
  defp run_until_superseded(execution, workflow_def, config) do
    run_execution(execution, workflow_def, config)
  catch
    :throw, :durable_superseded ->
      Context.cleanup()
      {:error, :superseded}
  end

  defp run_execution(execution, workflow_def, config) do
    # Check if this is a single-step parallel child execution
    parallel_step_flag = execution.engine_state["__parallel_step"]

    lane_steps = parallel_step_flag && lane_steps(workflow_def, parallel_step_flag)
    # Whose deadline a timeout names: the lane's own, if it has one.
    Process.put(:durable_lane_timeout, lane_timeout(execution, workflow_def))
    done = execution.engine_state[@done]

    result =
      cond do
        to_roll_back?(execution) ->
          roll_back(execution, workflow_def, config)

        lane_steps ->
          run_lane(execution, lane_steps, {parallel_step_flag, done}, workflow_def, config)

        # A lane the deployed code no longer has. Run as a whole workflow, it
        # would repeat every step after the block.
        parallel_step_flag ->
          mark_failed(config, execution, %{
            type: "parallel_step_not_found",
            message: "Lane #{parallel_step_flag} not found in workflow"
          })

        true ->
          # Pipeline model: start with workflow input or restored context
          initial_data =
            if saved?(execution),
              do: execution |> data_of() |> restore_lane_keys(workflow_def),
              else: execution.input

          execute_steps(workflow_def.steps, execution, config, initial_data, done)
      end

    Context.cleanup()
    result
  end

  # The steps of the lane a run was started for, if the workflow still has it.
  defp lane_steps(workflow_def, lane_id) do
    Enum.find_value(workflow_def.steps, fn
      %{type: :parallel, opts: %{lanes: lanes}} ->
        with {_id, _lane, names} <- Enum.find(lanes, &(to_string(elem(&1, 0)) == lane_id)),
             do: Enum.filter(workflow_def.steps, &(&1.name in names))

      _step ->
        nil
    end)
  end

  # The lane a run was started for and its `timeout:`, if it has one.
  defp lane_timeout(execution, workflow_def) do
    lane_id = execution.engine_state["__parallel_step"]

    Enum.find_value(workflow_def.steps, fn
      %{type: :parallel, opts: %{lanes: lanes} = opts} ->
        with {_id, lane, _names} <- Enum.find(lanes, &(to_string(elem(&1, 0)) == lane_id)),
             ms when is_integer(ms) <- Map.get(opts[:timeouts] || %{}, lane),
             do: {lane, ms}

      _step ->
        nil
    end)
  end

  # A lane is a run of its own steps: it resumes, retries and waits like any
  # run, and finishing tells the block. What says it is a lane is in its
  # engine state, for as long as the run is kept. A lane that hasn't started
  # has its own id for a current step.
  defp run_lane(execution, steps, {lane_id, done}, workflow_def, config) do
    data = execution |> data_of() |> restore_lane_keys(workflow_def)

    # A step on its own in the block is a lane with that step's name: its run
    # is at that step from the start, and back at it, it may have finished it
    # (`finished_before_lost/5`).
    one_step? = Enum.any?(steps, &(Atom.to_string(&1.name) == lane_id))
    current = if execution.current_step != lane_id or one_step?, do: execution.current_step
    execute_steps(steps, %{execution | current_step: current}, config, data, done)
  end

  # A block that collects holds each lane as a pair, which is stored as a
  # two-item list: this gives a step the pairs, however the run got to it.
  defp restore_lane_keys(data, nil), do: data

  defp restore_lane_keys(data, workflow_def) do
    for %{type: :parallel, opts: %{result_key: key} = opts} <- workflow_def.steps,
        key = to_string(key),
        is_map(data[key]),
        reduce: data do
      data -> Map.update!(data, key, &lane_pairs(&1, opts, workflow_def))
    end
  end

  # A block that collects holds each lane as a pair, stored as a two-item list.
  # A lane's data can hold a block of its own, which is put back the same way.
  defp lane_pairs(results, opts, workflow_def) do
    collect? = opts[:error_strategy] == :collect
    Map.new(results, fn {lane, result} -> {lane, lane_pair(result, collect?, workflow_def)} end)
  end

  defp lane_pair(["ok", data], true, workflow_def), do: {:ok, in_lane(data, workflow_def)}
  defp lane_pair(["error", reason], true, _workflow_def), do: {:error, reason}
  defp lane_pair(data, _collect?, workflow_def), do: in_lane(data, workflow_def)

  defp in_lane(data, workflow_def) when is_map(data), do: restore_lane_keys(data, workflow_def)
  defp in_lane(data, _workflow_def), do: data

  # Every save leaves this in the engine's state: a run that has it has saved
  # a context, even an empty one. Its value is the context's keys, which the
  # engine read up to 2.0.0 and no longer does.
  defp record_saved(engine_state, context),
    do: engine_state |> Map.delete(@atom_twins) |> Map.put(@string_keys, Map.keys(context))

  # A run's stored context as a step sees it. The context is the user's data
  # and nothing in it is the engine's, whatever it is called.
  defp data_of(execution),
    do: EngineState.strip(execution.context)

  # Whether the run has saved a context: before that, its data is its input.
  defp saved?(%{context: context, engine_state: engine_state}) do
    context != %{} or is_map_key(engine_state, @string_keys) or
      is_map_key(engine_state, @atom_keys)
  end

  @doc """
  Resumes a waiting workflow.

  ## Options

  - `:inline` - If true, execute synchronously instead of via queue (default: false).
    Runs until the run finishes or parks: a retry, snooze, wait or move to a
    step's queue is left for the queue
  - `:durable` - The Durable instance name (default: Durable)
  - `:engine` - The engine's own markers for the step that waited. Only the
    engine passes this: `additional_context` is the user's data, and has the
    engine's keys dropped from it
  """
  @spec resume_workflow(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resume_workflow(workflow_id, additional_context \\ %{}, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)
    # Sanitize at the API boundary — callers (provide_input, send_event,
    # timeout workers) supply maps that can carry arbitrary user terms.
    safe_additional = additional_context |> sanitize_for_json() |> EngineState.strip()
    engine = sanitize_for_json(Keyword.get(opts, :engine, %{}))

    with {:ok, execution} <- load_execution(config, workflow_id),
         true <- execution.status == :waiting || {:error, :not_waiting},
         {:ok, resumed} <- mark_resumed(config, execution, safe_additional, engine) do
      DurablePubSub.wake(config, resumed)

      # For inline/synchronous execution (useful for testing)
      if Keyword.get(opts, :inline, false) do
        execute_workflow(workflow_id, config)
      end

      # Otherwise, the queue poller will pick up the job
      {:ok, workflow_id}
    end
  end

  # Compare-and-set from :waiting, so a cancel that lands between the status
  # check above and this write isn't silently undone.
  defp mark_resumed(config, execution, additional_context, engine) do
    execution
    |> Ecto.Changeset.change(
      context: Map.merge(execution.context || %{}, additional_context),
      engine_state: Map.merge(execution.engine_state, engine),
      status: :pending,
      scheduled_at: nil,
      locked_by: nil,
      locked_at: nil
    )
    |> cas_update(config)
    |> case do
      {:error, :superseded} -> {:error, :not_waiting}
      result -> result
    end
  end

  # Private functions

  defp get_workflow_definition(module, opts) do
    case Keyword.get(opts, :workflow) do
      nil ->
        module.__default_workflow__()

      name ->
        module.__workflow_definition__(name)
    end
  rescue
    UndefinedFunctionError ->
      {:error, :not_a_workflow_module}
  end

  defp get_workflow_definition_from_execution(execution) do
    module = String.to_existing_atom(execution.workflow_module)
    module.__workflow_definition__(execution.workflow_name)
  rescue
    ArgumentError -> {:error, :module_not_found}
    UndefinedFunctionError -> {:error, :module_not_found}
  end

  defp create_execution(config, module, %Workflow{} = workflow_def, input, opts) do
    # A keyed start of a debounced workflow waits out its quiet period first.
    scheduled_at =
      if Keyword.get(opts, :key),
        do: Keys.debounced_start(workflow_def, Keyword.get(opts, :scheduled_at)),
        else: Keyword.get(opts, :scheduled_at)

    attrs = %{
      workflow_module: Atom.to_string(module),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: (opts[:queue] || workflow_def.opts[:queue] || "default") |> to_string(),
      priority: Keyword.get(opts, :priority) || 0,
      input: input,
      context: %{},
      scheduled_at: scheduled_at,
      trigger: Keyword.get(opts, :trigger, :api),
      trigger_ref: Keyword.get(opts, :trigger_ref),
      deadline_at: deadline(workflow_def, scheduled_at),
      tags: Keyword.get(opts, :tags) || []
    }

    case Keyword.fetch(opts, :key) do
      {:ok, key} when not is_nil(key) ->
        changeset = WorkflowExecution.changeset(%WorkflowExecution{}, Map.put(attrs, :key, key))
        Keys.insert(config, changeset, workflow_def, opts)

      _ ->
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(attrs)
        |> Repo.insert(config)
    end
  end

  defp load_execution(config, workflow_id) do
    case Repo.id?(workflow_id) && Repo.get(config, WorkflowExecution, workflow_id) do
      %WorkflowExecution{} = execution -> {:ok, EngineState.adopt(config, execution)}
      _not_a_run -> {:error, :not_found}
    end
  end

  # started_at is the first start: a run resumed after a wait keeps it, so
  # queue wait (ready → started) and run duration (started → finished) aren't
  # measured from the last resume.
  # A run_again run waits behind its key's holder (runs_after_id), and the
  # claim query skips it until that holder has ended. Now it takes the key.
  # If another run took the key meanwhile it waits behind that one instead,
  # unless a newer start already waits there (that one has the newer input,
  # so this one is cancelled). If `reuse:` keeps the key, it's cancelled.
  defp take_waiting_key(_config, %{runs_after_id: nil} = execution, _workflow_def),
    do: {:ok, execution}

  defp take_waiting_key(config, execution, workflow_def) do
    case Keys.take_waiting(config, execution, workflow_def) do
      {:ok, taken} ->
        {:ok, taken}

      {:behind, holder_id} ->
        wait_behind(config, execution, holder_id)

      {:kept, holder_id} ->
        stop_waiting(
          config,
          execution,
          "the key is kept by reuse: #{Keys.reuse(workflow_def)} " <>
            "(held by #{String.slice(holder_id, 0, 8)})"
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp wait_behind(config, execution, holder_id) do
    execution
    |> Ecto.Changeset.change(
      status: :pending,
      runs_after_id: holder_id,
      locked_by: nil,
      locked_at: nil
    )
    |> Ecto.Changeset.unique_constraint(:key, name: :workflow_executions_runs_after_index)
    |> cas_update(config)
    |> case do
      {:ok, waiting} -> {:waiting, waiting}
      {:error, :superseded} = superseded -> superseded
      {:error, _taken} -> stop_waiting(config, execution, "a newer start is waiting for the key")
    end
  end

  defp stop_waiting(config, execution, reason) do
    _ = cancel_workflow(execution.id, reason, durable: config.name)
    {:error, :superseded}
  end

  defp mark_running(config, execution) do
    started_at = execution.started_at || DateTime.utc_now()

    case execution
         |> WorkflowExecution.status_changeset(:running, %{started_at: started_at})
         |> cas_update(config) do
      {:ok, running} = ok ->
        DurablePubSub.broadcast_workflow(config, :workflow_resumed, workflow_event(running))
        ok

      other ->
        other
    end
  end

  # A run's deadline counts from when it's due to start, so a run scheduled for
  # tomorrow doesn't time out before it begins.
  @doc false
  @spec deadline(Workflow.t(), DateTime.t() | nil) :: DateTime.t() | nil
  def deadline(%Workflow{opts: %{timeout: ms}}, start) when is_integer(ms) and ms > 0,
    do: DateTime.add(start || DateTime.utc_now(), ms, :millisecond)

  def deadline(_workflow_def, _start), do: nil

  defp past_deadline?(%{deadline_at: %DateTime{} = deadline}),
    do: DateTime.compare(DateTime.utc_now(), deadline) != :lt

  defp past_deadline?(_execution), do: false

  defp past_deadline_by?(%{deadline_at: %DateTime{} = deadline}, ms),
    do: DateTime.diff(DateTime.utc_now(), deadline, :millisecond) >= ms

  defp past_deadline_by?(_execution, _ms), do: false

  # The deadline passed before `step` began.
  defp time_out(execution, step, workflow_def, config) do
    passed =
      case Process.get(:durable_lane_timeout) do
        {lane, ms} -> "lane #{lane} passed its #{format_timeout(ms)} timeout"
        nil -> "the run passed its #{format_timeout(workflow_def.opts[:timeout])} timeout"
      end

    error = %{type: "timeout", message: "#{passed} before #{step.name}"}

    # Only its own deadline stops a run's children; any other failure leaves
    # its start_workflow children running.
    cancel_child_workflows(config, execution.id)
    fail_at(execution, step, error, workflow_def, config)
  end

  # The TimeoutWorker resumes a run whose `on_timeout: :fail` wait timed out
  # with the error under `__fail__`, so the run fails here, in the executor,
  # rather than being written off from outside.
  defp resume_failure(%{engine_state: %{"__fail__" => error}}), do: error
  defp resume_failure(_execution), do: nil

  # Fail the run at `step` the way a failed step would, so its compensations
  # run.
  defp fail_at(execution, step, error, workflow_def, config) do
    {:ok, exec} =
      execution
      |> Ecto.Changeset.change(
        current_step: Atom.to_string(step.name),
        # A retried run must not fail again on the same marker.
        engine_state: Map.delete(execution.engine_state, "__fail__")
      )
      |> cas_update!(config)

    handle_step_failure(exec, error, workflow_def, config)
  end

  @doc false
  def format_timeout(ms) when is_integer(ms) do
    Enum.find_value(
      [{86_400_000, "d"}, {3_600_000, "h"}, {60_000, "m"}, {1_000, "s"}],
      "#{ms}ms",
      fn {size, unit} -> rem(ms, size) == 0 and "#{div(ms, size)}#{unit}" end
    )
  end

  def format_timeout(_ms), do: "workflow"

  defp execute_steps(steps, execution, config, initial_data, done) do
    # Get workflow definition for compensation lookup
    {:ok, workflow_def} = get_workflow_definition_from_execution(execution)

    steps_to_run = steps_to_resume(steps, execution.current_step)

    if steps_to_run == [] and execution.current_step != nil do
      # The deployed definition no longer has the step this run stopped at.
      # Running on from a guess would skip work, so fail, without
      # compensating: restore the step and `Durable.retry/2` the run.
      mark_failed(config, execution, %{
        type: "definition_changed",
        message:
          "#{execution.workflow_name} has no step #{execution.current_step} any more; " <>
            "this run stopped there before the workflow changed"
      })
    else
      run_steps(
        steps,
        after_done(steps_to_run, done),
        execution,
        workflow_def,
        config,
        initial_data
      )
    end
  end

  # The data is already the first step's result: go on from what follows it.
  defp after_done([%{name: name} = step | rest], %{"step" => done} = record) do
    # An arm the branch no longer has: the workflow changed, so it decides again.
    arm = step.type == :branch && arm_steps(step, record["arm"])

    cond do
      Atom.to_string(name) != done -> [step | rest]
      step.type == :branch and arm -> only_clause(rest, step, arm)
      step.type == :branch -> [step | rest]
      record["arm"] -> jumped(step, rest, record["arm"])
      true -> Enum.reject(rest, &(&1.name in (step.opts[:all_steps] || [])))
    end
  end

  defp after_done(steps, _not_done), do: steps

  # A block whose `into:` jumped: on from the step it named, or the block again
  # if the workflow no longer has that step.
  defp jumped(step, rest, target) do
    case Enum.drop_while(rest, &(Atom.to_string(&1.name) != target)) do
      [] -> [step | rest]
      from_target -> from_target
    end
  end

  defp arm_steps(branch, arm) do
    Enum.find_value(branch.opts[:clauses], fn {{name, _}, steps} ->
      if to_string(name) == to_string(arm), do: steps
    end)
  end

  # A resumed run picks up at its current step, found by name. The steps of
  # every branch clause sit side by side in the definition, so a run that
  # stopped inside a branch goes on with the rest of its own clause and then
  # whatever follows the block.
  defp steps_to_resume(steps, nil), do: steps

  # A named branch can sit inside another's arm, so that is done for every
  # branch the step is in. An unnamed one can't, and its steps aren't in the
  # order they run in, so its clause is read from the block.
  defp steps_to_resume(steps, current) do
    rest = Enum.drop_while(steps, &(Atom.to_string(&1.name) != current))

    case Enum.filter(steps, &(&1.type == :branch and named?(&1.opts[:all_steps], current))) do
      [] ->
        rest

      [%{opts: %{decider: true}} | _] = branches ->
        Enum.reduce(branches, rest, &only_clause(&2, &1, clause_of(&1, current)))

      [branch | _] ->
        rest_of_clause(branch, current, steps) ++
          Enum.reject(rest, &(&1.name in branch.opts[:all_steps]))
    end
  end

  defp rest_of_clause(branch, current, steps) do
    branch
    |> clause_of(current)
    |> Enum.drop_while(&(Atom.to_string(&1) != current))
    |> Enum.map(fn name -> Enum.find(steps, &(&1.name == name)) end)
  end

  defp clause_of(branch, current) do
    Enum.find_value(branch.opts[:clauses], fn {_pattern, names} ->
      if named?(names, current), do: names
    end)
  end

  # `steps` without the steps of the branch's other clauses.
  defp only_clause(steps, branch, taken) do
    Enum.reject(steps, &(&1.name in branch.opts[:all_steps] and &1.name not in taken))
  end

  defp named?(names, current), do: Enum.any?(names, &(Atom.to_string(&1) == current))

  defp run_steps(steps, steps_to_run, execution, workflow_def, config, initial_data) do
    # Build step index for validation
    step_index = build_step_index(steps)

    # Execute steps with pipeline data flow
    case execute_steps_recursive(
           steps_to_run,
           execution,
           step_index,
           workflow_def,
           config,
           initial_data
         ) do
      {:ok, exec, final_data} ->
        mark_completed(config, exec, final_data)

      {:waiting, exec} ->
        {:waiting, exec}

      {:error, _} = error ->
        error
    end
  end

  defp build_step_index(steps) do
    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, idx} -> {step.name, idx} end)
    |> Map.new()
  end

  defp execute_steps_recursive([], execution, _step_index, _workflow_def, _config, data) do
    {:ok, execution, data}
  end

  defp execute_steps_recursive(
         [step | remaining_steps],
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    cond do
      past_deadline?(execution) ->
        time_out(execution, step, workflow_def, config)

      error = resume_failure(execution) ->
        fail_at(execution, step, error, workflow_def, config)

      queue = queue_move(step, execution, config) ->
        move_to_queue(config, execution, step, queue, data)

      true ->
        # Every step is handed its data as it is stored, string keys at every
        # depth, whether the run was reloaded to get here or not.
        # ponytail: a JSON round trip per step; skip it for data that came
        # straight from a save if a profile ever shows it.
        data = data |> stored() |> restore_lane_keys(workflow_def)
        dispatch_step(step, remaining_steps, execution, step_index, workflow_def, config, data)
    end
  end

  defp dispatch_step(step, remaining_steps, execution, step_index, workflow_def, config, data) do
    case step.type do
      :branch ->
        execute_branch(step, remaining_steps, execution, step_index, workflow_def, config, data)

      :parallel ->
        execute_parallel(step, remaining_steps, execution, step_index, workflow_def, config, data)

      _ ->
        execute_regular_step(
          step,
          remaining_steps,
          execution,
          step_index,
          workflow_def,
          config,
          data
        )
    end
  end

  defp execute_regular_step(
         step,
         remaining_steps,
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    # Update current step
    {:ok, exec} = update_current_step(config, execution, step.name)

    {result, exec} =
      case finished_before_lost(config, execution, step, data, workflow_def) do
        nil -> run_step(step, data, exec, config)
        finished -> {finished, exec}
      end

    case result do
      {:ok, new_data} ->
        # Save data as context and continue to next step
        {:ok, exec} = save_data_as_context(config, exec, new_data, :drop, step.name)
        # Pass the saved context forward: what the step returned and what it put
        execute_steps_recursive(
          remaining_steps,
          exec,
          step_index,
          workflow_def,
          config,
          passed_on(exec, workflow_def)
        )

      {:decision, target_step, new_data} ->
        handle_decision_result(
          exec,
          target_step,
          new_data,
          remaining_steps,
          step,
          step_index,
          workflow_def,
          config
        )

      stopped ->
        step_stopped(stopped, exec, data, workflow_def, config)
    end
  end

  # A step's body reads the run's engine state through its process (what its
  # wait was answered with) and writes to it (the children it started). It is
  # put there as the step starts and taken back as it ends, and is never in
  # the step's data.
  defp run_step(step, data, exec, config) do
    EngineState.put_current(exec.engine_state)
    result = StepRunner.execute(step, data, exec.id, config, exec.deadline_at)
    # Merged: a body only ever adds to it.
    {result, %{exec | engine_state: Map.merge(exec.engine_state, EngineState.current())}}
  end

  # A run back at the step it was at may have finished it already: its worker
  # was lost after the step's row was written and before the run saved the
  # result. The row has the result, so the body doesn't run again. Read only
  # for the step a run comes back to, never for the ones it goes on to.
  #
  # The result is read as any stored data is, with string keys at every
  # depth. The row also has what the step put in
  # the context without returning it (`StepRunner.put_in_body/0`).
  #
  # ponytail: a step that jumps (a decision, a `{:goto, _, _}`) and a step in
  # an unnamed branch still run again. Read their rows too if that matters.
  #
  # The row has the step's data, not what its body added to the engine's
  # state; a child it started is on the run's row already (`record_child/3`).
  #
  # What the body took out of the context (`delete_context/1`) is in the run's
  # engine state, under that row's id (`StepRunner.record_deleted/3`): left in
  # the data the step was handed, a key it deleted would be saved again. One
  # it also returned or put back is in the output, and stays.
  defp finished_before_lost(config, %{current_step: current} = run, step, data, workflow_def) do
    with true <- current == Atom.to_string(step.name) and step.type != :decision,
         %{id: row_id, output: output} <- lost_attempt(config, run) do
      dropped = Map.get(run.engine_state, EngineState.dropped_key(row_id), [])
      Process.put(:durable_context, Map.drop(data, dropped))

      {:ok,
       output
       |> EngineState.strip()
       |> restore_lane_keys(workflow_def)}
    else
      _not_finished -> nil
    end
  end

  # Only the run's newest row can be the one: a wait, a retry or a jump back
  # leaves a newer one. One from before `Durable.retry/2` isn't it either.
  defp lost_attempt(config, %{id: id, current_step: step, retried_at: retried_at}) do
    newest =
      from(s in StepExecution,
        where: s.workflow_id == ^id and s.is_compensation == false,
        order_by: [desc: s.inserted_at],
        limit: 1
      )

    with %{status: :completed, step_name: ^step, output: %{} = output} = row <-
           Repo.one(config, newest),
         false <- jumped?(output),
         true <- is_nil(retried_at) or DateTime.after?(row.inserted_at, retried_at) do
      row
    else
      _not_it -> nil
    end
  end

  # The row of a step that jumped holds the jump and its data, and nothing
  # else. A step's own data can have a `decision_type` key.
  defp jumped?(output),
    do: map_size(output) == 3 and match?(%{"decision_type" => _, "target_step" => _}, output)

  # A step that didn't finish: it waits, failed, cancelled the run or is parked.
  defp step_stopped({wait_type, opts}, exec, data, workflow_def, config)
       when wait_type in [:sleep, :wait_for_event, :wait_for_input, :wait_for_any, :wait_for_all] do
    # Save current data before waiting
    {:ok, exec} = save_data_as_context(config, exec, data, :keep)
    handle_wait_result(config, exec, wait_type, opts)
  rescue
    error ->
      wait_not_recorded(exec, caught_error(:error, error, __STACKTRACE__), workflow_def, config)
  end

  defp step_stopped({:call_workflow, opts}, exec, data, _workflow_def, config) do
    {:ok, exec} = save_data_as_context(config, exec, data, :keep)
    handle_call_workflow(config, exec, opts)
  end

  # What the body added to the engine's state (a child it started under a
  # `ref:`) is written first, forced as a save's is: the failure leaves the
  # row's as it was, and a retry has to find that child, not start another.
  defp step_stopped({:error, error}, exec, _data, workflow_def, config) do
    {:ok, exec} =
      exec
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.force_change(:engine_state, exec.engine_state)
      |> cas_update!(config)

    handle_step_failure(exec, error, workflow_def, config)
  end

  defp step_stopped({:cancel, reason, scope}, exec, _data, _workflow_def, config),
    do: cancel_from_step(config, exec, reason, scope)

  defp step_stopped({:park, delay_ms}, exec, _data, _workflow_def, config),
    do: park(config, exec, delay_ms)

  # The step asked for a wait that couldn't be written: a sleep to a time no
  # timestamp holds, a timeout that isn't a number, a prompt JSON can't take.
  # Raised from here it reached whoever ran the executor, and inline that is
  # the caller, with the run left :running. It is the step's failure. The row
  # says :waiting for a wait that doesn't exist, so it is closed as failed; its
  # end event went out when the step suspended.
  defp wait_not_recorded(exec, error, workflow_def, config) do
    now = DateTime.utc_now()

    suspended =
      from(s in StepExecution,
        where:
          s.workflow_id == ^exec.id and s.step_name == ^exec.current_step and
            s.status == :waiting,
        order_by: [desc: s.inserted_at],
        limit: 1,
        select: s.id
      )

    Repo.update_all(
      config,
      from(s in StepExecution, where: s.id in subquery(suspended)),
      set: [status: :failed, error: storable_error(error), completed_at: now, updated_at: now]
    )

    handle_step_failure(exec, error, workflow_def, config)
  end

  defp handle_decision_result(
         exec,
         target_step,
         data,
         remaining_steps,
         step,
         step_index,
         workflow_def,
         config
       ) do
    case find_jump_target(target_step, remaining_steps, step.name, {step_index, workflow_def}) do
      {:ok, target_steps} ->
        # Saved with the jump it made, so a run that comes back to this step
        # goes on from its target, not through the step again.
        {:ok, exec} = save_data_as_context(config, exec, data, :drop, {step.name, target_step})

        # Use the merged exec.context (prior put_context writes + goto data),
        # not the goto's raw data — otherwise put_context writes from prior
        # steps would silently vanish across the goto boundary.
        execute_steps_recursive(
          target_steps,
          exec,
          step_index,
          workflow_def,
          config,
          passed_on(exec, workflow_def)
        )

      {:error, reason} ->
        {:ok, exec} = save_data_as_context(config, exec, data)

        handle_step_failure(
          exec,
          decision_error(step.name, target_step, reason),
          workflow_def,
          config
        )
    end
  end

  defp handle_wait_result(config, exec, :sleep, opts),
    do: {:waiting, handle_sleep(config, exec, opts) |> elem(1)}

  defp handle_wait_result(config, exec, :wait_for_event, opts),
    do: {:waiting, handle_wait_for_event(config, exec, opts) |> elem(1)}

  defp handle_wait_result(config, exec, :wait_for_input, opts),
    do: {:waiting, handle_wait_for_input(config, exec, opts) |> elem(1)}

  defp handle_wait_result(config, exec, :wait_for_any, opts),
    do: {:waiting, handle_wait_for_any(config, exec, opts) |> elem(1)}

  defp handle_wait_result(config, exec, :wait_for_all, opts),
    do: {:waiting, handle_wait_for_all(config, exec, opts) |> elem(1)}

  # ============================================================================
  # Workflow Orchestration (call_workflow)
  # ============================================================================

  defp handle_call_workflow(config, execution, opts) do
    child_id = Keyword.fetch!(opts, :child_id)
    event_name = Durable.Orchestration.child_event_name(child_id)
    timeout_at = calculate_timeout_at(opts)

    # Create pending event to wait for child completion
    attrs = %{
      workflow_id: execution.id,
      event_name: event_name,
      step_name: execution.current_step,
      timeout_at: timeout_at,
      timeout_value: serialize_timeout_value(Keyword.get(opts, :timeout_value, :child_timeout)),
      wait_type: :single
    }

    {execution, _event} = enter_wait(config, execution, fn -> insert_event!(config, attrs) end)

    settle_child(config, child_id)
    {:waiting, execution}
  end

  # Commits a wait's rows and the run's :waiting status together, so whoever
  # answers the wait finds a run it can resume or finds no wait at all, never a
  # wait on a run that's still :running. Events kept for the wait are handed to
  # it in the same transaction: committed apart, a worker lost in between left
  # the run waiting for an event it already had. Returns the waiting run and
  # what `insert_wait` returned.
  defp enter_wait(config, execution, insert_wait, kept_events \\ []) do
    {:ok, entered} =
      Repo.transaction(config, fn ->
        wait = insert_wait.()

        {:ok, waiting} =
          execution
          |> Ecto.Changeset.change(status: :waiting, scheduled_at: nil)
          |> cas_update!(config)

        Enum.each(kept_events, &Durable.Wait.deliver_buffered(config, execution.id, &1))
        {waiting, wait}
      end)

    entered
  end

  defp insert_event!(config, attrs) do
    {:ok, event} = %PendingEvent{} |> PendingEvent.changeset(attrs) |> Repo.insert(config)
    event
  end

  # A child that finished before the parent's event existed had no one to tell,
  # so tell it now. A child's finish commits before it looks for the event and
  # this reads the child after the event commits, so one of the two sees the
  # other. A child that hasn't finished is woken only now, once its parent is
  # ready to hear from it.
  defp settle_child(config, child_id) do
    child = Repo.get(config, WorkflowExecution, child_id)

    case child do
      %{status: :completed} ->
        notify_orchestration_parent(config, child, :completed, EngineState.strip(child.context))

      %{status: :cancelled} ->
        notify_orchestration_parent(config, child, :cancelled, child.error)

      %{status: status} when status in [:failed, :compensated, :compensation_failed] ->
        notify_orchestration_parent(config, child, :failed, child.error)

      _still_going ->
        DurablePubSub.wake(config, child)
    end
  end

  # The branch's `on:` value. The DSL stores the function as `body_fn`; older
  # definitions name it in `opts[:condition_fn]`. A raise or exit becomes
  # `{:branch_error, error}`, stack and all.
  defp branch_condition(%{body_fn: condition_fn} = branch_step, data) do
    cond do
      is_function(condition_fn, 1) -> condition_fn.(data)
      is_function(branch_step.opts[:condition_fn], 1) -> branch_step.opts[:condition_fn].(data)
      true -> apply(branch_step.module, branch_step.opts[:condition_fn], [data])
    end
  catch
    kind, reason -> {:branch_error, caught_error(kind, reason, __STACKTRACE__)}
  end

  # A named branch: its decider runs as a step, and the arm it names is the
  # jump that step's row records. The arm's steps are next, then what follows
  # the block.
  defp execute_branch(
         %{opts: %{decider: true}} = branch,
         remaining_steps,
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    {:ok, exec} = update_current_step(config, execution, branch.name)
    {result, exec} = run_step(branch, data, exec, config)

    case result do
      {:decision, arm, new_data} ->
        {:ok, exec} = save_data_as_context(config, exec, new_data, :drop, {branch.name, arm})

        remaining_steps
        |> only_clause(branch, arm_steps(branch, arm))
        |> execute_steps_recursive(
          exec,
          step_index,
          workflow_def,
          config,
          passed_on(exec, workflow_def)
        )

      stopped ->
        step_stopped(stopped, exec, data, workflow_def, config)
    end
  end

  defp execute_branch(
         branch_step,
         remaining_steps,
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    {:ok, exec} = update_current_step(config, execution, branch_step.name)

    clauses = branch_step.opts[:clauses]
    all_branch_steps = branch_step.opts[:all_steps] || []

    case branch_condition(branch_step, data) do
      {:branch_error, error} ->
        handle_step_failure(exec, error, workflow_def, config)

      {:error, error} ->
        handle_step_failure(exec, %{type: "branch_error", message: error}, workflow_def, config)

      value ->
        # Find matching clause steps
        matching_steps = find_matching_clause_steps(value, clauses)

        # Save data before executing branch steps
        {:ok, exec} = save_data_as_context(config, exec, data)

        # Execute only the matching branch's steps
        case execute_branch_steps(
               matching_steps,
               remaining_steps,
               exec,
               step_index,
               workflow_def,
               config,
               data
             ) do
          {:ok, exec, branch_data} ->
            # Skip past all branch steps in remaining and continue with updated data
            after_branch = skip_branch_steps(remaining_steps, all_branch_steps)

            execute_steps_recursive(
              after_branch,
              exec,
              step_index,
              workflow_def,
              config,
              branch_data
            )

          # Found among the clause's steps and what follows the block: the
          # other clauses' steps are in `remaining_steps` too.
          {:decision, exec, step, target_step, new_data} ->
            handle_decision_result(
              exec,
              target_step,
              new_data,
              only_clause(remaining_steps, branch_step, matching_steps),
              step,
              step_index,
              workflow_def,
              config
            )

          {:waiting, exec} ->
            {:waiting, exec}

          {:error, _} = error ->
            error
        end
    end
  end

  defp find_matching_clause_steps(value, clauses) do
    find_exact_match(value, clauses) || find_default_clause(clauses)
  end

  defp find_exact_match(value, clauses) do
    Enum.find_value(clauses, fn {{pattern, _idx}, steps} ->
      if clause_matches?(pattern, value), do: steps
    end)
  end

  # An atom a step returned is stored as its text, and that text is what
  # `on:` reads, so an atom clause takes it: `:invoice ->` matches "invoice".
  defp clause_matches?(pattern, value) when is_atom(pattern) and is_binary(value),
    do: Atom.to_string(pattern) == value

  defp clause_matches?(pattern, value), do: pattern == value

  defp find_default_clause(clauses) do
    Enum.find_value(clauses, [], fn {{pattern, _idx}, steps} ->
      if pattern == :default, do: steps
    end)
  end

  defp execute_branch_steps(
         step_names,
         remaining_steps,
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    # Find the actual step definitions from remaining_steps
    steps_to_execute =
      Enum.filter(remaining_steps, fn step ->
        step.name in step_names
      end)

    # Execute them in the order they appear in step_names
    ordered_steps =
      Enum.map(step_names, fn name ->
        Enum.find(steps_to_execute, fn s -> s.name == name end)
      end)
      |> Enum.reject(&is_nil/1)

    execute_branch_steps_sequential(
      ordered_steps,
      execution,
      step_index,
      workflow_def,
      config,
      data
    )
  end

  defp execute_branch_steps_sequential([], execution, _step_index, _workflow_def, _config, data) do
    {:ok, execution, data}
  end

  defp execute_branch_steps_sequential(
         [step | _] = steps,
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    case queue_move(step, execution, config) do
      nil -> run_branch_step(steps, execution, step_index, workflow_def, config, data)
      queue -> move_to_queue(config, execution, step, queue, data)
    end
  end

  defp run_branch_step([step | rest], execution, step_index, workflow_def, config, data) do
    {:ok, exec} = update_current_step(config, execution, step.name)
    {result, exec} = run_step(step, data, exec, config)

    case result do
      {:ok, new_data} ->
        {:ok, exec} = save_data_as_context(config, exec, new_data, :drop, step.name)

        execute_branch_steps_sequential(
          rest,
          exec,
          step_index,
          workflow_def,
          config,
          passed_on(exec, workflow_def)
        )

      # The jump is made by execute_branch/7, which has the steps after the block.
      {:decision, target_step, new_data} ->
        {:decision, exec, step, target_step, new_data}

      {wait_type, opts}
      when wait_type in [:sleep, :wait_for_event, :wait_for_input, :wait_for_any, :wait_for_all] ->
        {:ok, exec} = save_data_as_context(config, exec, data, :keep)
        handle_wait_result(config, exec, wait_type, opts)

      {:call_workflow, opts} ->
        {:ok, exec} = save_data_as_context(config, exec, data, :keep)
        handle_call_workflow(config, exec, opts)

      {:error, _error} = failed ->
        step_stopped(failed, exec, data, workflow_def, config)

      {:cancel, reason, scope} ->
        cancel_from_step(config, exec, reason, scope)

      {:park, delay_ms} ->
        park(config, exec, delay_ms)
    end
  end

  defp skip_branch_steps(remaining_steps, all_branch_step_names) do
    Enum.reject(remaining_steps, fn step ->
      step.name in all_branch_step_names
    end)
  end

  # ============================================================================
  # Parallel Execution
  # ============================================================================

  defp execute_parallel(
         parallel_step,
         remaining_steps,
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    {:ok, exec} = update_current_step(config, execution, parallel_step.name)

    # Get parallel configuration
    opts = parallel_step.opts
    all_parallel_steps = opts[:all_steps] || []
    error_strategy = opts[:error_strategy] || :fail_fast
    into_fn = opts[:into_fn]

    ordered_steps = block_children(opts)

    # Save data before parallel execution
    {:ok, exec} = save_data_as_context(config, exec, data)

    # Check if we're resuming after fan-in (all children completed)
    if parallel_children(exec.engine_state) do
      collect_parallel_results(exec, data, into_fn, error_strategy, %{
        remaining_steps: remaining_steps,
        all_parallel_steps: all_parallel_steps,
        step_index: step_index,
        workflow_def: workflow_def,
        config: config,
        parallel_step_name: parallel_step.name
      })
    else
      # Fan-out: create child executions + WaitGroup
      # A block with `into:` hands every result to the function, so it runs them all.
      strategy = if into_fn, do: :complete_all, else: error_strategy
      fan_out_parallel(exec, ordered_steps, data, config, strategy)
    end
  end

  # What runs as a child: each lane, started like a step, under its own id.
  defp block_children(%{lanes: lanes} = opts) do
    for {id, lane, _names} <- lanes,
        do: %{
          name: id,
          opts: %{
            returns: lane,
            optional: lane in (opts[:optional] || []),
            timeout: Map.get(opts[:timeouts] || %{}, lane)
          }
        }
  end

  # Fan-out: create child workflow executions for each parallel step and wait
  # In one transaction: a branch that a worker could claim while the parent was
  # still writing its events would finish with no one to tell, and the parent
  # would wait forever. Pollers are woken once the branches can be seen.
  defp fan_out_parallel(exec, ordered_steps, data, config, error_strategy) do
    {:ok, waiting} =
      Repo.transaction(config, fn ->
        open_parallel_block(exec, ordered_steps, data, config, error_strategy)
      end)

    ordered_steps
    |> Enum.map(&to_string(&1.opts[:queue] || exec.queue || "default"))
    |> Enum.uniq()
    |> Enum.each(&DurablePubSub.wake(config, %{status: :pending, queue: &1}))

    {:waiting, waiting}
  end

  defp open_parallel_block(exec, ordered_steps, data, config, error_strategy) do
    parent_queue = exec.queue || "default"

    # Create child executions for each parallel step
    children_meta =
      Enum.map(ordered_steps, fn step ->
        returns_key = get_returns_key(step)
        child_queue = step.opts[:queue] || parent_queue

        {:ok, child} = create_parallel_child(exec, step, data, child_queue, config)

        {child.id, Atom.to_string(step.name), returns_key,
         %{"optional" => step.opts[:optional] == true, "timeout" => step.opts[:timeout]}}
      end)

    # Build event names and children metadata map
    event_names = Enum.map(children_meta, fn {id, _, _, _} -> "__parallel_done:#{id}" end)

    children_map =
      Map.new(children_meta, fn {id, step_name, returns_key, lane_opts} ->
        returns_str = if is_atom(returns_key), do: Atom.to_string(returns_key), else: returns_key
        {id, Map.merge(lane_opts, %{"step_name" => step_name, "returns_key" => returns_str})}
      end)

    # Create WaitGroup + PendingEvents for all children
    {:ok, wait_group} =
      %WaitGroup{}
      |> WaitGroup.changeset(%{
        workflow_id: exec.id,
        step_name: exec.current_step,
        wait_type: :all,
        event_names: event_names
      })
      |> Repo.insert(config)

    Enum.each(event_names, fn event_name ->
      {:ok, _} =
        %PendingEvent{}
        |> PendingEvent.changeset(%{
          workflow_id: exec.id,
          event_name: event_name,
          step_name: exec.current_step,
          wait_group_id: wait_group.id,
          wait_type: :all
        })
        |> Repo.insert(config)
    end)

    # What the block's run resumes with, once its lanes have finished
    block = %{
      "__parallel_children" => children_map,
      "__parallel_wait_group_id" => wait_group.id,
      "__parallel_error_strategy" => Atom.to_string(error_strategy),
      @string_keys => Map.keys(exec.context || %{})
    }

    {:ok, exec} =
      exec
      |> Ecto.Changeset.change(
        engine_state: Map.merge(exec.engine_state, block),
        status: :waiting,
        scheduled_at: nil
      )
      |> cas_update!(config)

    exec
  end

  # A lane with a `timeout:` has until then, or until the run's own deadline.
  defp lane_deadline(run_deadline, nil), do: run_deadline

  defp lane_deadline(run_deadline, ms) do
    at = DateTime.add(DateTime.utc_now(), ms, :millisecond)
    if run_deadline && DateTime.before?(run_deadline, at), do: run_deadline, else: at
  end

  # Create a child workflow execution for a single parallel step
  defp create_parallel_child(parent_exec, step, data, queue, config) do
    # Inherit the parent's accumulated context so prior put_context/2 calls
    # are visible to the child step via get_context/1. This is a snapshot at
    # spawn time — concurrent siblings still can't see each other's writes,
    # which is intentional (avoids races across parallel branches).
    parent_context = parent_exec.context || %{}

    attrs = %{
      workflow_module: parent_exec.workflow_module,
      workflow_name: parent_exec.workflow_name,
      status: :pending,
      queue: to_string(queue),
      priority: parent_exec.priority,
      # Straight after another block the data is still as its `into:` or its
      # lanes left it, tuples and all.
      input: sanitize_for_json(data),
      context: parent_context,
      # Which lane the run is, for as long as the run is kept.
      engine_state:
        EngineState.new()
        |> Map.merge(EngineState.inherited(parent_exec.engine_state))
        |> Map.put("__parallel_step", Atom.to_string(step.name))
        |> record_saved(parent_context),
      parent_workflow_id: parent_exec.id,
      root_workflow_id: parent_exec.root_workflow_id || parent_exec.id,
      trigger: :parent,
      current_step: Atom.to_string(step.name),
      # A branch is part of the run, so the run's deadline stops it too.
      deadline_at: lane_deadline(parent_exec.deadline_at, step.opts[:timeout])
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> Repo.insert(config)
  end

  # Collect results from completed child executions (called when parent resumes)
  defp collect_parallel_results(exec, _base_data, into_fn, _error_strategy, opts) do
    %{
      remaining_steps: remaining_steps,
      all_parallel_steps: all_parallel_steps,
      step_index: step_index,
      workflow_def: workflow_def,
      config: config,
      parallel_step_name: parallel_step_name
    } = opts

    children_map = parallel_children(exec.engine_state)
    error_strategy_str = exec.engine_state["__parallel_error_strategy"] || "fail_fast"

    error_strategy = String.to_existing_atom(error_strategy_str)
    # When into_fn is provided, always collect all results
    effective_strategy = if into_fn, do: :complete_all, else: error_strategy

    # Load all child executions and build results
    results = build_results_from_children(children_map, config)

    # The block is over once its results are saved: the run that goes on from
    # it carries no record of its lanes. One that fails here keeps it, for a
    # retry to find.
    finished = %{
      exec
      | engine_state:
          Map.drop(exec.engine_state, [
            "__parallel_children",
            "__parallel_wait_group_id",
            "__parallel_error_strategy"
          ])
    }

    clean_ctx = passed_on(exec, workflow_def)

    # Check for fail_fast. A lane the block can do without doesn't fail it.
    optional = for {_id, %{"optional" => true, "returns_key" => key}} <- children_map, do: key

    errors =
      Enum.filter(results, fn {key, result} ->
        match?({:error, _}, result) and to_string(key) not in optional
      end)

    if effective_strategy == :fail_fast && errors != [] do
      # Branches the failure stopped report "cancelled", which isn't the reason.
      {_key, {:error, first_error}} =
        Enum.find(errors, hd(errors), fn {_key, {:error, error}} ->
          not cancelled_error?(error)
        end)

      handle_step_failure(exec, first_error, workflow_def, config)
    else
      handle_parallel_completion(results, clean_ctx, into_fn, %{
        remaining_steps: remaining_steps,
        all_parallel_steps: all_parallel_steps,
        exec: finished,
        step_index: step_index,
        workflow_def: workflow_def,
        config: config,
        parallel_step_name: parallel_step_name
      })
    end
  end

  # Build results map from child workflow executions
  defp cancelled_error?(%{"type" => "cancelled"}), do: true
  defp cancelled_error?(_error), do: false

  defp build_results_from_children(children_map, config) do
    Map.new(children_map, fn {child_id, meta} ->
      returns_key = Context.known_key(meta["returns_key"])

      case Repo.get(config, WorkflowExecution, child_id) do
        %{status: :completed, context: ctx} ->
          {returns_key, {:ok, EngineState.strip(ctx)}}

        %{status: status, error: error}
        when status in [:failed, :cancelled, :compensation_failed] ->
          {returns_key, {:error, error || %{type: "child_failed", message: "#{status}"}}}

        _ ->
          {returns_key, {:error, %{type: "child_incomplete", message: "child not finished"}}}
      end
    end)
  end

  # Handle completion of parallel block - apply into_fn or add __results__
  # Uses opts map to reduce arity below credo's limit of 8
  defp handle_parallel_completion(results, base_ctx, into_fn, opts) do
    %{
      remaining_steps: remaining_steps,
      all_parallel_steps: all_parallel_steps,
      exec: exec,
      step_index: step_index,
      workflow_def: workflow_def,
      config: config,
      parallel_step_name: parallel_step_name
    } = opts

    block = Enum.find(workflow_def.steps, &(&1.name == parallel_step_name))

    results = lane_outputs(results, base_ctx)

    case apply_parallel_into(into_fn, base_ctx, results, block.opts) do
      {:ok, final_ctx} ->
        {:ok, exec} = save_data_as_context(config, exec, final_ctx, :drop, parallel_step_name)
        after_parallel = skip_parallel_steps(remaining_steps, all_parallel_steps)

        execute_steps_recursive(
          after_parallel,
          exec,
          step_index,
          workflow_def,
          config,
          final_ctx
        )

      {:goto, target_step, goto_ctx} ->
        index = {step_index, workflow_def}

        case find_jump_target(target_step, remaining_steps, parallel_step_name, index) do
          {:ok, target_steps} ->
            {:ok, exec} =
              save_data_as_context(
                config,
                exec,
                goto_ctx,
                :drop,
                {parallel_step_name, target_step}
              )

            execute_steps_recursive(
              target_steps,
              exec,
              step_index,
              workflow_def,
              config,
              goto_ctx
            )

          # Not saved, as for an `into:` that fails: the run keeps its record
          # of the lanes, so a retry runs `into:` again on their results and
          # doesn't start them a second time, or make a jump that was refused.
          {:error, reason} ->
            handle_step_failure(
              exec,
              %{type: "parallel_goto_error", message: reason},
              workflow_def,
              config
            )
        end

      {:error, error} ->
        handle_step_failure(exec, error, workflow_def, config)
    end
  end

  # A lane hands back what it produced, not what it was started with: its data
  # less every key it left as the block found it. A lane's data is as stored,
  # so the block's is put the same way to compare. A lane can't hand back that
  # it removed a key.
  defp lane_outputs(results, started_with) do
    started_with = stored(started_with)

    Map.new(results, fn
      {lane, {:ok, data}} ->
        {lane, {:ok, Map.reject(data, &left_alone?(&1, started_with))}}

      failed ->
        failed
    end)
  end

  defp stored(data), do: data |> sanitize_for_json() |> Jason.encode!() |> Jason.decode!()

  defp left_alone?({key, value}, started_with), do: Map.fetch(started_with, key) == {:ok, value}

  # Apply the into function, or put each lane under the block's name.
  # A named block: each lane goes under the block's name. Every lane finished
  # (one that didn't has failed the block), so that is its data; a block that
  # collects says how each lane ended.
  defp apply_parallel_into(nil, base_ctx, results, %{result_key: result_key} = opts) do
    collect? = opts[:error_strategy] == :collect

    lanes =
      Map.new(results, fn
        {lane, {:ok, data}} when collect? -> {lane, {:ok, data}}
        {lane, {:ok, data}} -> {lane, data}
        {lane, {:error, reason}} when collect? -> {lane, {:error, reason}}
        # Only an optional lane gets here failed: the block did without it,
        # and hands on its `default:`, put as a lane's stored data would be.
        {lane, {:error, _reason}} -> {lane, stored(Map.get(opts[:defaults] || %{}, lane))}
      end)

    {:ok, base_ctx |> Map.delete(to_string(result_key)) |> Map.put(result_key, lanes)}
  end

  defp apply_parallel_into(into_fn, base_ctx, results, opts)
       when is_function(into_fn, 2) do
    # User callbacks get raw {:ok, value} / {:error, reason} tuples so they
    # can pattern-match cleanly — this is the intended ergonomic API.
    # Any tuples that leak into the callback's return are sanitized at the
    # save boundary (save_data_as_context -> sanitize_for_json), so storage
    # can't crash regardless of what shape the user returns.
    # What `into:` returns is the user's data, like a step's result.
    case into_fn.(base_ctx, Map.new(results, fn {lane, result} -> {to_string(lane), result} end)) do
      {:ok, data} when is_run_data(data) ->
        {:ok, EngineState.strip(data)}

      {:goto, step, data} when is_atom(step) and is_run_data(data) ->
        {:goto, step, EngineState.strip(data)}

      {:error, _reason} = error ->
        error

      # Unmatched, it would crash the worker like the throw below.
      other ->
        {:error, invalid_into_return(other, opts)}
    end
  catch
    # A throw or an exit too: uncaught, it would fail the run from the worker,
    # past its compensations.
    kind, reason -> {:error, caught_error(kind, reason, __STACKTRACE__)}
  end

  defp invalid_into_return(returned, opts) do
    %{
      type: "parallel_into_error",
      message:
        "into: of parallel #{inspect(opts[:original_name])} must return {:ok, data}, " <>
          "{:error, reason} or {:goto, step, data}, with data a map, " <>
          "got: #{inspect(returned, limit: 5, printable_limit: 200)}"
    }
  end

  # Normalize error to map format
  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error) when is_binary(error), do: %{type: "error", message: error}

  defp normalize_error(error) when is_atom(error),
    do: %{type: "error", message: Atom.to_string(error)}

  defp normalize_error(error), do: %{type: "error", message: inspect(error)}

  # Get the returns key from step opts (default to original_name)
  defp get_returns_key(%{opts: opts}) do
    opts[:returns] || opts[:original_name]
  end

  defp skip_parallel_steps(remaining_steps, all_parallel_step_names) do
    Enum.reject(remaining_steps, fn step ->
      step.name in all_parallel_step_names
    end)
  end

  defp find_jump_target(target_step, remaining_steps, current_step, {step_index, workflow_def}) do
    with :ok <- validate_target_exists(target_step, step_index),
         :ok <- validate_not_self(target_step, current_step),
         :ok <- validate_forward_jump(target_step, current_step, step_index),
         :ok <- validate_same_arm(target_step, current_step, workflow_def.steps) do
      find_target_in_remaining(target_step, remaining_steps)
    end
  end

  # The steps of every arm of a branch, and of every lane of a block, sit side
  # by side in the definition. A run that landed in one from outside it would
  # run on through the arms after it, or run a lane's steps in the block's own
  # run. A step can jump on within its own arm, or out of it.
  defp validate_same_arm(target_step, current_step, steps) do
    entered =
      Enum.find(steps, fn block ->
        Enum.any?(arms(block), &(target_step in &1 and current_step not in &1))
      end)

    if entered do
      {:error,
       "Cannot jump from :#{current_step} to :#{target_step}, a step inside :#{entered.name}. " <>
         "Jump to :#{entered.name}, or to a step outside it."}
    else
      :ok
    end
  end

  defp arms(%{type: :branch, opts: %{clauses: clauses}}), do: Enum.map(clauses, &elem(&1, 1))
  defp arms(%{type: :parallel, opts: %{lanes: lanes}}), do: Enum.map(lanes, &elem(&1, 2))
  defp arms(_step), do: []

  defp validate_target_exists(target_step, step_index) do
    if Map.has_key?(step_index, target_step) do
      :ok
    else
      {:error, "Target step :#{target_step} does not exist in workflow"}
    end
  end

  defp validate_not_self(target_step, current_step) do
    if target_step == current_step do
      {:error, "Cannot jump to self (:#{current_step})"}
    else
      :ok
    end
  end

  defp validate_forward_jump(target_step, current_step, step_index) do
    if Map.get(step_index, target_step) <= Map.get(step_index, current_step) do
      {:error,
       "Cannot jump backwards from :#{current_step} to :#{target_step}. " <>
         "Decision steps can only jump forward."}
    else
      :ok
    end
  end

  defp find_target_in_remaining(target_step, remaining_steps) do
    case Enum.drop_while(remaining_steps, fn s -> s.name != target_step end) do
      [] -> {:error, "Target step :#{target_step} not found in remaining steps"}
      target_steps -> {:ok, target_steps}
    end
  end

  defp decision_error(from_step, target_step, reason) do
    %{
      type: "decision_error",
      message: reason,
      from_step: Atom.to_string(from_step),
      target_step: Atom.to_string(target_step)
    }
  end

  # Runs at every step boundary, so it's also where a cancelled run stops.
  defp update_current_step(config, execution, step_name) do
    execution
    |> Ecto.Changeset.change(current_step: Atom.to_string(step_name))
    |> cas_update!(config)
  end

  # Compare-and-set on status: the write only lands if the row's status is
  # still the one this executor read. Operators (cancel) and the queue
  # (stale-lock recovery) also write this row; when they got there first the
  # run is theirs and we must not overwrite their decision. `force: true`
  # makes even a no-change write hit the database, so the check always runs.
  defp cas_update(%Ecto.Changeset{} = changeset, config, opts \\ []) do
    guarded = %{changeset | filters: Map.merge(changeset.filters, cas_filters(changeset.data))}

    case Repo.update(guarded, config, [stale_error_field: :status, force: true] ++ opts) do
      {:error, %Ecto.Changeset{errors: errors} = failed} ->
        if match?({_, [stale: true]}, errors[:status]),
          do: {:error, :superseded},
          else: {:error, failed}

      ok ->
        ok
    end
  end

  # Inside the step loop there is nothing left to do once superseded, so
  # unwind straight to run_until_superseded/3.
  # A new owner sets the status back to :running, so a worker that was taken
  # over can only be told apart by its claim's token.
  defp cas_filters(%WorkflowExecution{status: status, lock_token: token}) when token != nil,
    do: %{status: status, lock_token: token}

  defp cas_filters(%{status: status}), do: %{status: status}

  defp cas_update!(changeset, config) do
    case cas_update(changeset, config) do
      {:error, :superseded} -> throw(:durable_superseded)
      result -> result
    end
  end

  @doc false
  # Writes how an attempt ended, if it's still open. Recovery or a cancel may
  # have closed the row while the body ran: then the attempt is over, the end
  # event was theirs to send, and this worker stops (run_segment/4).
  def finish_attempt!(changeset, config) do
    case cas_update(changeset, config) do
      {:error, :superseded} -> throw(:durable_attempt_closed)
      result -> result
    end
  end

  # Saves data as the workflow context in DB (for persistence/resume), and
  # with it, in the same write, the engine's state: the mark that a context
  # was saved, the step this is the result of, and what the step's body left
  # there (the children it started).
  defp save_data_as_context(config, execution, data, markers \\ :drop, done \\ nil) do
    # Persist the step's cumulative context — everything the user wrote via
    # put_context/2 during the step body PLUS everything they returned from
    # the step. Step return wins on key collision because the return value
    # is the step's explicit contract.
    #
    # Rationale: Context is cumulative. Before this change, put_context/2
    # writes were silently dropped unless the user also returned those keys,
    # which made the put_context API a footgun.
    process_ctx = Process.get(:durable_context, %{})

    # As stored: string keys at every depth, and what the step returned over
    # what it put.
    merged = process_ctx |> stored() |> Map.merge(stored(data)) |> EngineState.strip()

    engine_state =
      execution.engine_state
      |> finish_wait_markers(markers)
      # What an attempt deleted is in this save, or was never to be. A run
      # that came back for its result loaded it with the rest of its state.
      |> EngineState.without_dropped()
      |> record_saved(merged)

    engine_state =
      if done,
        do: Map.put(engine_state, @done, done_record(done)),
        else: Map.delete(engine_state, @done)

    # Forced: what the row holds is what this save worked out, whatever the
    # struct in hand had.
    saved =
      execution
      |> Ecto.Changeset.change(context: merged)
      |> Ecto.Changeset.force_change(:engine_state, engine_state)
      |> cas_update!(config)

    # The process's context is now the run's, until the next step begins: a
    # run that fails before then (its deadline, a branch's `on:`) hands its
    # compensations what was saved, not what the last step was handed.
    Process.put(:durable_context, merged)
    saved
  end

  # What a save hands the next step in the same pass: the context it wrote,
  # which is what the step would be handed had the run been reloaded.
  defp passed_on(exec, workflow_def), do: restore_lane_keys(exec.context, workflow_def)

  defp done_record({step, arm}),
    do: %{"step" => Atom.to_string(step), "arm" => Atom.to_string(arm)}

  defp done_record(step), do: %{"step" => Atom.to_string(step)}

  # A step that's suspending again still needs them when it re-runs. Kept once
  # it's finished, a marker would stand in for a later wait's own.
  defp finish_wait_markers(engine_state, :keep), do: engine_state

  defp finish_wait_markers(engine_state, :drop),
    do: EngineState.without_wait_markers(engine_state)

  defp mark_completed(config, execution, final_data) do
    # Sanitize before persisting — the final step may return data containing
    # raw tuples (e.g., child executions in a parallel block complete with
    # {:ok, value} that gets unwrapped but sometimes leaks through).
    safe_final = final_data |> sanitize_for_json() |> EngineState.strip()

    # A finished run's context is its result, and is no step's data any more:
    # the records that went with the last save go, in the same write.
    engine_state = Map.drop(execution.engine_state, [@done, @string_keys, @atom_twins])

    {:ok, execution} =
      execution
      |> WorkflowExecution.status_changeset(:completed, %{
        context: safe_final,
        completed_at: DateTime.utc_now(),
        current_step: nil
      })
      |> Ecto.Changeset.change(locked_by: nil, locked_at: nil, scheduled_at: nil)
      |> Ecto.Changeset.force_change(:engine_state, engine_state)
      |> cas_update!(config)

    DurablePubSub.broadcast_workflow(config, :workflow_completed, workflow_event(execution))

    maybe_notify_parent(config, execution, :completed, safe_final)

    {:ok, execution}
  end

  # `rollback_at` is when a halted run is to be undone if nobody has acted by
  # then (`on_failure: [rollback_after: ms]`). It's kept in `scheduled_at`,
  # which means nothing else on a failed run; the timeout sweep reads it.
  defp mark_failed(config, execution, error, rollback_at \\ nil) do
    # Sanitize the error before persisting — a step crash may hand us a map
    # containing tuples, PIDs, or functions (via stacktrace, raw values, etc).
    # Postgres JSONB can't store those, so we recursively replace unencodable
    # leaves with their inspect/1 string. If save STILL fails we fall back to
    # a minimal diagnostic error so the workflow is never left as a zombie.
    safe_error = storable_error(error)

    result =
      try do
        execution
        |> WorkflowExecution.status_changeset(:failed, %{
          error: safe_error,
          completed_at: DateTime.utc_now()
        })
        |> Ecto.Changeset.change(locked_by: nil, locked_at: nil, scheduled_at: rollback_at)
        |> cas_update!(config)
      rescue
        e ->
          fallback = %{
            type: "unrecorded_error",
            message:
              "Workflow failed, but original error could not be persisted: #{Exception.message(e)}",
            original_error_inspect: inspect(error, limit: :infinity)
          }

          execution
          |> WorkflowExecution.status_changeset(:failed, %{
            error: fallback,
            completed_at: DateTime.utc_now()
          })
          |> Ecto.Changeset.change(locked_by: nil, locked_at: nil, scheduled_at: nil)
          |> Repo.update(config)
      end

    case result do
      {:ok, execution} ->
        DurablePubSub.broadcast_workflow(config, :workflow_failed, workflow_event(execution))
        maybe_notify_parent(config, execution, :failed, safe_error)
        {:error, safe_error}

      {:error, changeset} ->
        # Last resort — we can't even save the fallback. Log and move on so
        # the worker doesn't crash.
        require Logger

        Logger.error(
          "[Durable] Failed to mark workflow #{execution.id} as failed: #{inspect(changeset)}"
        )

        {:error, safe_error}
    end
  end

  @doc false
  # What a caught error is stored as: the exception's type and message (an
  # exit or a throw made readable) and the stack — app, file and line per
  # frame — as text. Frames are as deep as the VM's `:backtrace_depth`.
  def caught_error(kind, reason, stacktrace) do
    {type, message} =
      case kind do
        :error ->
          exception = Exception.normalize(:error, reason, stacktrace)
          {inspect(exception.__struct__), Exception.message(exception)}

        :exit ->
          {"exit", Exception.format_exit(reason)}

        :throw ->
          {"throw", inspect(reason)}
      end

    %{type: type, message: message, stacktrace: Exception.format_stacktrace(stacktrace)}
  end

  # An error as a map Jason can encode, whatever a step or compensation returned.
  @doc false
  @spec storable_error(term()) :: map()
  def storable_error(error) do
    case error |> normalize_error() |> sanitize_for_json() do
      map when is_map(map) and not is_struct(map) -> map
      # A date or a decimal is JSON, but not the object the column has to load.
      other -> %{type: "error", message: inspect(other)}
    end
  end

  @json_scalars [Date, DateTime, NaiveDateTime, Time, Decimal]

  # Recursively convert a term into something Jason can encode. Tuples become
  # lists, non-Date/DateTime atoms pass through, and anything else exotic
  # (PIDs, ports, functions, refs) is replaced by its inspect/1 form.
  @doc false
  @spec sanitize_for_json(term()) :: term()
  def sanitize_for_json(%module{} = struct) when module in @json_scalars, do: struct

  def sanitize_for_json(%_{} = struct),
    do: sanitize_for_json(Map.from_struct(struct))

  # A key written both ways (`:id` put on data that has "id") is stored once,
  # with the atom's value: the atom is the one the step just wrote.
  def sanitize_for_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> is_atom(k) end)
    |> Map.new(fn {k, v} -> {sanitize_json_key(k), sanitize_for_json(v)} end)
  end

  def sanitize_for_json(list) when is_list(list) do
    if List.improper?(list), do: inspect(list), else: Enum.map(list, &sanitize_for_json/1)
  end

  def sanitize_for_json(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&sanitize_for_json/1)
  end

  def sanitize_for_json(term) when is_binary(term), do: storable_string(term)

  def sanitize_for_json(term) when is_number(term) or is_boolean(term) or is_nil(term), do: term

  def sanitize_for_json(term) when is_atom(term) do
    string = Atom.to_string(term)
    if String.contains?(string, <<0>>), do: storable_string(string), else: term
  end

  def sanitize_for_json(term), do: inspect(term)

  defp sanitize_json_key(k) when is_binary(k), do: storable_string(k)
  defp sanitize_json_key(k) when is_atom(k), do: k |> Atom.to_string() |> storable_string()
  defp sanitize_json_key(k), do: inspect(k)

  # jsonb can't hold a NUL, and JSON can't hold bytes that aren't UTF-8.
  defp storable_string(string) do
    if String.valid?(string), do: String.replace(string, <<0>>, "\uFFFD"), else: inspect(string)
  end

  # ============================================================================
  # Parent Notification (Orchestration)
  # ============================================================================

  @doc false
  # Also called by the sweeps and the worker, which fail runs the executor can't.
  def maybe_notify_parent(_config, %{parent_workflow_id: nil}, _status, _data), do: :ok

  def maybe_notify_parent(config, execution, status, data) do
    # Check for parallel child notification first (uses __parallel_done: events)
    parallel_event_name = "__parallel_done:#{execution.id}"

    parallel_pending =
      Repo.one(
        config,
        from(p in PendingEvent,
          where:
            p.workflow_id == ^execution.parent_workflow_id and
              p.event_name == ^parallel_event_name and
              p.status == :pending,
          # `limit: 1` keeps `Repo.one` from RAISING if a duplicate parallel
          # event ever exists (e.g. a re-run of fan_out before context
          # committed). One pending event per child is the norm; defending the
          # claim path against the pathological case avoids crashing the child's
          # whole completion handler.
          limit: 1
        )
      )

    if parallel_pending do
      notify_parallel_parent(config, execution, parallel_pending, status, data)
    else
      notify_orchestration_parent(config, execution, status, data)
    end
  end

  # Notify parent via WaitGroup (parallel child completion).
  #
  # Three updates run inside one transaction:
  #
  #   1. Mark the child's PendingEvent as :received.
  #   2. Lock the WaitGroup row (FOR UPDATE), merge the event into
  #      received_events, flip to :completed when the wait condition is
  #      satisfied. The lock is what closes the lost-update race that
  #      previously allowed concurrent siblings to overwrite each other.
  #   3. If the group just transitioned to :completed, flip the parent
  #      :waiting -> :pending so the queue poller picks it up.
  #
  # If any stage fails the whole transaction rolls back, so the system
  # never observes "event :received but wait group not updated" or "wait
  # group complete but parent still :waiting" — the states zombie
  # detection later misreads as a crash.
  defp notify_parallel_parent(config, execution, pending_event, status, data) do
    payload = Durable.Orchestration.build_result_payload(status, data)
    parent_id = execution.parent_workflow_id

    multi =
      Ecto.Multi.new()
      |> lock_run(parent_id)
      |> Ecto.Multi.update(:event, PendingEvent.receive_changeset(pending_event, payload))
      |> Ecto.Multi.run(:wait_group, fn repo, _ ->
        WaitGroup.add_event_locked(
          repo,
          pending_event.wait_group_id,
          pending_event.event_name,
          payload
        )
      end)
      |> Ecto.Multi.run(:stopped, fn repo, %{wait_group: wg_result} ->
        stop_block_on_failure(repo, execution, status, wg_result)
      end)
      |> Ecto.Multi.run(:parent, fn repo, %{wait_group: wg_result, stopped: stopped} ->
        if wg_result.just_completed or stopped != nil do
          # The results are read from the children's rows, so the events' copies
          # of each branch's output have no place in the parent's data.
          resume_parent_in_multi(repo, parent_id, %{})
        else
          {:ok, %{no_op: true}}
        end
      end)

    case Repo.transaction(config, multi) do
      {:ok, %{parent: parent, stopped: stopped}} ->
        for cancelled <- stopped || [], do: close_out_cancelled(config, cancelled)
        DurablePubSub.wake(config, parent)

      {:error, stage, reason, _} ->
        Logger.error(
          "[Durable] failed to atomically fulfill parallel child event + wait group + resume parent: " <>
            "stage=#{stage} reason=#{inspect(reason)} parent=#{parent_id}"
        )

        {:error, reason}
    end
  end

  # Resume a parent (or any waiting workflow) inside an Ecto.Multi.run.
  # Mirrors the body of `resume_workflow/3` minus the standalone Repo.update,
  # so the resume composes into a transaction with the upstream event /
  # wait group updates.
  # A failed branch under :fail_fast ends the block now, and so does one that
  # was cancelled: to the block it is an error too. In the same transaction
  # as the parent's resume, so the parent finds every branch finished. nil when
  # the block carries on.
  defp stop_block_on_failure(repo, branch, status, %{just_completed: false, wait_group: group})
       when status in [:failed, :cancelled] and group.status == :pending do
    parent = EngineState.adopt(repo, repo.get(WorkflowExecution, branch.parent_workflow_id))
    block = (parent && parent.engine_state) || %{}

    # A lane the block can do without doesn't end it.
    optional? = get_in(block, ["__parallel_children", branch.id, "optional"])

    if block["__parallel_error_strategy"] == "fail_fast" && !optional? do
      {:ok, _} =
        group
        |> Ecto.Changeset.change(status: :completed, completed_at: DateTime.utc_now())
        |> repo.update()

      repo.update_all(
        from(e in PendingEvent, where: e.wait_group_id == ^group.id and e.status == :pending),
        set: [status: :cancelled, completed_at: DateTime.utc_now()]
      )

      {:ok, cancel_siblings(repo, branch, Map.keys(block["__parallel_children"]))}
    else
      {:ok, nil}
    end
  end

  defp stop_block_on_failure(_repo, _branch, _status, _wait_group), do: {:ok, nil}

  defp cancel_siblings(repo, branch, branch_ids) do
    now = DateTime.utc_now()

    query =
      from(w in WorkflowExecution,
        where: w.id in ^branch_ids and w.id != ^branch.id,
        where: w.status in [:pending, :running, :waiting],
        select: w
      )

    {_count, cancelled} =
      repo.update_all(query,
        set: [
          status: :cancelled,
          error: %{type: "cancelled", message: "another branch of the parallel block failed"},
          completed_at: now,
          updated_at: now,
          locked_by: nil,
          locked_at: nil,
          lock_token: nil
        ]
      )

    cancelled
  end

  @doc false
  # `additional_context` is the user's data: an event's payload under its name.
  def resume_parent_in_multi(repo, workflow_id, additional_context) do
    safe_context = additional_context |> sanitize_for_json() |> EngineState.strip()

    case EngineState.adopt(repo, repo.get(WorkflowExecution, workflow_id)) do
      nil ->
        {:error, :workflow_not_found}

      %WorkflowExecution{status: :waiting} = exec ->
        new_context = Map.merge(exec.context || %{}, safe_context)

        exec
        |> Ecto.Changeset.change(
          context: new_context,
          status: :pending,
          scheduled_at: nil,
          locked_by: nil,
          locked_at: nil
        )
        |> repo.update()

      %WorkflowExecution{status: status} ->
        # Already moved on (cancelled, completed, etc.). Tolerate; the
        # upstream event/wait group state is still committed by the
        # surrounding Multi.
        {:ok, %{status: status, no_op: true}}
    end
  end

  # Notify parent via orchestration (call_workflow child completion)
  defp notify_orchestration_parent(config, execution, status, data) do
    event_name = Durable.Orchestration.child_event_name(execution.id)
    payload = Durable.Orchestration.build_result_payload(status, data)

    # Find and fulfill the pending event on the parent workflow
    query =
      from(p in PendingEvent,
        where:
          p.workflow_id == ^execution.parent_workflow_id and
            p.event_name == ^event_name and
            p.status == :pending
      )

    case Repo.one(config, query) do
      nil ->
        # Parent not waiting (fire-and-forget case, or already timed out).
        # Log this as an orphan completion — useful when investigating why
        # a parent never received its child's result.
        if execution.parent_workflow_id do
          Logger.warning(
            "[Durable] child completion arrived for non-waiting parent — " <>
              "child=#{execution.id} parent=#{execution.parent_workflow_id} " <>
              "event=#{event_name} status=#{status}"
          )
        end

        :ok

      pending_event ->
        # Atomic: fulfill the pending event AND transition the parent back
        # to :pending in a single transaction. Before this change a crash
        # between the two updates left the event :received but the parent
        # stuck in :waiting (Bug M-3).
        parent = Repo.get(config, WorkflowExecution, execution.parent_workflow_id)
        parent = EngineState.adopt(config, parent)
        result = build_parent_result(parent, execution.id, payload)
        atomic_fulfill_event_and_resume_parent(config, pending_event, parent, result)
    end
  end

  @doc false
  # Everything that changes a wait and its run takes the run's row first. In any
  # other order, two of them can deadlock.
  @spec lock_run(Ecto.Multi.t(), String.t()) :: Ecto.Multi.t()
  def lock_run(multi, workflow_id) do
    Ecto.Multi.run(multi, :locked_run, fn repo, _changes ->
      {:ok,
       repo.one(
         from(w in WorkflowExecution,
           where: w.id == ^workflow_id,
           lock: "FOR UPDATE",
           select: w.id
         )
       )}
    end)
  end

  # `result` is the engine's own: the child's result, under the child's names.
  defp atomic_fulfill_event_and_resume_parent(config, pending_event, parent, result) do
    safe_result = sanitize_for_json(result)

    multi =
      Ecto.Multi.new()
      |> lock_run(parent.id)
      |> Ecto.Multi.run(:event, fn repo, _changes ->
        {:ok, receive_if_pending(repo, pending_event)}
      end)
      |> Ecto.Multi.run(:parent, fn repo, %{event: received} ->
        # The lock makes the child's own notice and settle_child/2 take turns,
        # so the second one finds the wait answered. It was read before the
        # lock: by now the parent may be in another wait, not to be ended here.
        case received && repo.get(WorkflowExecution, parent.id) do
          false ->
            {:ok, %{no_op: true}}

          nil ->
            {:error, :parent_not_found}

          %WorkflowExecution{status: :waiting} = exec ->
            exec
            |> Ecto.Changeset.change(
              engine_state: Map.merge(exec.engine_state, safe_result),
              status: :pending,
              scheduled_at: nil,
              locked_by: nil,
              locked_at: nil
            )
            |> repo.update()

          %WorkflowExecution{status: status} ->
            # Parent already moved on (cancelled, completed, etc.). Tolerate;
            # the event is still marked :received via the Multi above.
            {:ok, %{status: status, no_op: true}}
        end
      end)

    case Repo.transaction(config, multi) do
      {:ok, %{parent: parent}} ->
        DurablePubSub.wake(config, parent)

      {:error, stage, reason, _} ->
        Logger.error(
          "[Durable] failed to atomically fulfill child event + resume parent: " <>
            "stage=#{stage} reason=#{inspect(reason)} parent=#{parent.id}"
        )

        {:error, reason}
    end
  end

  # Marks the event received if it still waits. Whether it did.
  defp receive_if_pending(repo, %PendingEvent{id: id} = event) do
    now = DateTime.utc_now()

    {count, _} =
      repo.update_all(from(p in PendingEvent, where: p.id == ^id and p.status == :pending),
        set: [
          status: :received,
          payload: event.payload || %{},
          completed_at: now,
          updated_at: now
        ]
      )

    count == 1
  end

  # What the parent's engine state gets: the child's result under the ref the
  # parent called it by
  defp build_parent_result(parent, child_id, payload) do
    # Find which ref this child belongs to by looking for __child:ref = child_id
    ref =
      Enum.find_value(parent.engine_state, fn
        {"__child:" <> ref_str, ^child_id} -> ref_str
        _ -> nil
      end)

    if ref do
      %{
        "__child_done:#{ref}" => payload,
        Durable.Orchestration.child_event_name(child_id) => payload
      }
    else
      %{Durable.Orchestration.child_event_name(child_id) => payload}
    end
  end

  # ============================================================================
  # Cascade Cancellation (Orchestration)
  # ============================================================================

  @doc false
  # What follows a cancel: tell subscribers, and cancel the run's children.
  @spec after_cancel(Config.t(), WorkflowExecution.t(), boolean()) :: :ok
  def after_cancel(config, cancelled, close_attempt \\ true) do
    close_out_cancelled(config, cancelled, close_attempt)
    # A parent waiting on this run would otherwise wait forever.
    maybe_notify_parent(config, cancelled, :cancelled, cancelled.error)
    :ok
  end

  defp close_out_cancelled(config, cancelled, close_attempt \\ true) do
    # Its node may be gone, leaving nobody else to close its attempt.
    if close_attempt, do: StepRunner.close_cancelled(config, cancelled.id)
    # Left open, an input would stay in the inbox with nobody waiting for it.
    :ok = Durable.Wait.cancel_pending_waits(config, cancelled.id)
    DurablePubSub.broadcast_workflow(config, :workflow_cancelled, workflow_event(cancelled))
    cancel_child_workflows(config, cancelled.id)
  end

  # A step returned {:cancel, reason, scope}. Cancel the scope's run as
  # Durable.cancel/2 would (the cascade reaches every run under it), then this
  # run, which the cascade misses when the target or a run in between already
  # finished. Cancelling clears the lock token, so the worker's ack/nack is a
  # no-op. A parallel step defaults to :workflow: a cancelled branch would
  # otherwise fail a :fail_fast parent and run its compensations.
  defp cancel_from_step(config, execution, reason, scope) do
    scope = scope || if(parallel_branch?(execution), do: :workflow, else: :run)
    target = cancel_target(config, execution, scope)

    # Once this run is cancelled, its worker kills this process at the next
    # heartbeat. The cascade has to outlive that, or the rest of it never happens.
    config.name
    |> Durable.Supervisor.task_supervisor_name()
    |> Task.Supervisor.async_nolink(fn ->
      _ = cancel_workflow(target.id, reason, durable: config.name)
      _ = cancel_workflow(execution.id, reason, durable: config.name)
    end)
    |> Task.await(:infinity)

    {:error, %{type: "cancelled", message: reason}}
  end

  # :run stays put; :workflow climbs out of parallel branches; :root climbs
  # to the run with no parent.
  defp cancel_target(config, execution, scope) do
    with true <- climbs?(scope, execution),
         %WorkflowExecution{} = parent <- parent_run(config, execution) do
      cancel_target(config, parent, scope)
    else
      _ -> execution
    end
  end

  defp climbs?(:run, _execution), do: false
  defp climbs?(:workflow, execution), do: parallel_branch?(execution)
  defp climbs?(:root, _execution), do: true

  defp parent_run(_config, %{parent_workflow_id: nil}), do: nil

  defp parent_run(config, %{parent_workflow_id: id}),
    do: EngineState.adopt(config, Repo.get(config, WorkflowExecution, id))

  defp parallel_branch?(execution), do: is_map_key(execution.engine_state, "__parallel_step")

  defp cancel_child_workflows(config, parent_id) do
    query =
      from(w in WorkflowExecution,
        where: w.parent_workflow_id == ^parent_id,
        where: w.status in [:pending, :running, :waiting]
      )

    children = Repo.all(config, query)

    Enum.each(children, fn child ->
      cancel_workflow(child.id, "parent_cancelled", durable: config.name)
    end)
  end

  # ============================================================================
  # Compensation/Saga Support
  # ============================================================================

  # A run that fails is left failed, to be retried or rolled back by hand,
  # unless the workflow rolls back on failure or the step asked for it.
  defp handle_step_failure(execution, error, workflow_def, config) do
    # `error` is a map column: a step's `{:error, "declined"}` must become a
    # map here, or the failed/compensated write is rejected and the run stays
    # :running.
    error = storable_error(error)

    if workflow_def.opts[:on_failure] == :rollback or asks_rollback?(error),
      do: compensate_or_fail(execution, error, workflow_def, config),
      else: mark_failed(config, execution, error, rollback_at(execution, workflow_def))
  end

  # A lane has nothing of its own to undo: its block's run is the one that waits.
  defp rollback_at(execution, %{opts: %{on_failure: [rollback_after: ms]}}) do
    unless parallel_branch?(execution), do: DateTime.add(DateTime.utc_now(), ms, :millisecond)
  end

  defp rollback_at(_execution, _workflow_def), do: nil

  # `{:rollback, reason}` from a step, or from a lane's step by way of its block.
  defp asks_rollback?(error), do: "rollback" in [error[:type], error["type"]]

  defp compensate_or_fail(execution, error, workflow_def, config) do
    case build_compensation_stack(execution.id, workflow_def, config) do
      [] -> mark_failed(config, execution, error)
      stack -> undo_once_settled(execution, error, stack, workflow_def, config)
    end
  end

  defp undo_once_settled(execution, error, stack, workflow_def, config) do
    case settles_at(config, execution) do
      nil -> run_compensations(execution, error, stack, workflow_def, config)
      at -> undo_later(config, execution, error, at)
    end
  end

  # When the last step of a run under this one can still finish. A stopped
  # run's worker is told at its next heartbeat, and until then its step runs
  # on: undone before that, the run would miss what the step did. nil when
  # nothing under it was stopped in the last heartbeat.
  #
  # ponytail: a stopped run that was waiting, with no worker, makes the undo
  # wait as well. Record whether a worker had it when it was stopped if that
  # wait matters.
  defp settles_at(config, execution) do
    beat = config.heartbeat_interval
    since = DateTime.add(DateTime.utc_now(), -beat, :millisecond)
    root = execution.root_workflow_id || execution.id

    stopped =
      from(w in WorkflowExecution,
        where: w.root_workflow_id == ^root and w.id != ^execution.id,
        where: w.status == :cancelled and not is_nil(w.started_at) and w.completed_at > ^since,
        select: max(w.completed_at)
      )

    with %DateTime{} = last <- Repo.one(config, stopped),
         do: DateTime.add(last, beat, :millisecond)
  end

  # Back on its queue to be undone at `at`, as `queue_rollback/3` leaves a run
  # that failed. The state is read back: this process may hold less of it.
  defp undo_later(config, execution, error, at) do
    engine_state = stored(config, execution.id).engine_state

    {:ok, _} =
      execution
      |> Ecto.Changeset.change(
        status: :pending,
        scheduled_at: at,
        locked_by: nil,
        locked_at: nil,
        lock_token: nil
      )
      |> Ecto.Changeset.force_change(
        :engine_state,
        Map.put(engine_state, @rollback, %{"error" => error, "status" => "failed"})
      )
      |> without_key(execution)
      |> cas_update!(config)

    {:error, error}
  end

  # The run as it was last saved.
  defp stored(config, workflow_id), do: Repo.get(config, WorkflowExecution, workflow_id)

  # `rollback_workflow/2` asked: undo the run, keeping the error it failed with.
  defp roll_back(execution, workflow_def, config) do
    {%{"error" => error, "status" => was}, engine_state} =
      Map.pop(execution.engine_state, @rollback)

    # The marker goes in the write that takes the run out of :running. A
    # worker lost after it then leaves a run that failed while compensating,
    # not one the next claim carries on with, a cancelled run's steps and all.
    {:ok, execution} =
      execution
      |> WorkflowExecution.compensating_changeset()
      |> Ecto.Changeset.change(engine_state: engine_state)
      |> cas_update!(config)

    # A cancel left open the step its worker had (cancel_run/3). That worker
    # has stopped by now, so what is still open was lost with its node.
    StepRunner.close_cancelled(config, execution.id)

    case build_compensation_stack(execution.id, workflow_def, config) do
      [] -> nothing_to_undo(config, execution, error, was)
      stack -> run_compensations(execution, error, stack, workflow_def, config)
    end
  end

  # The undos of a run that completed.
  defp undone(workflow_id) do
    from(s in StepExecution,
      where: s.workflow_id == ^workflow_id and s.is_compensation and s.status == :completed
    )
  end

  defp nothing_to_undo(config, execution, error, was) do
    cond do
      # Every undo completed before the rollback lost its worker: it ends here.
      Repo.aggregate(config, undone(execution.id), :count) > 0 ->
        run_compensations(execution, error, [], nil, config)

      was == "cancelled" ->
        back_to_cancelled(config, execution, error)

      true ->
        mark_failed(config, execution, error)
    end
  end

  # A cancelled run that turned out to have nothing to undo.
  defp back_to_cancelled(config, execution, error) do
    {:ok, _} =
      execution
      |> WorkflowExecution.status_changeset(:cancelled, %{
        error: error,
        completed_at: DateTime.utc_now()
      })
      |> Ecto.Changeset.change(locked_by: nil, locked_at: nil, scheduled_at: nil)
      |> cas_update!(config)

    {:error, error}
  end

  # Builds the compensation stack from completed steps in reverse order
  defp build_compensation_stack(workflow_id, workflow_def, config) do
    # Get completed non-compensation steps, less the ones already undone: a
    # rollback that lost its worker part-way is asked for again, or handed to
    # another node, and an undo that completed must not run twice.
    query =
      from(s in StepExecution,
        as: :step,
        where: s.workflow_id == ^workflow_id,
        where: s.status == :completed,
        where: s.is_compensation == false,
        where: not exists(undone_since(workflow_id)),
        order_by: [desc: s.completed_at],
        select: s.step_name
      )

    # A step that completed twice (its lock was lost before the run moved on,
    # so it ran again) is still one step to undo.
    completed_steps = config |> Repo.all(query) |> Enum.uniq()

    # Map to steps that have compensations
    Enum.flat_map(completed_steps, &find_step_compensation(&1, workflow_def))
  end

  # A completed undo of the step in the outer query, no older than the step.
  defp undone_since(workflow_id) do
    from(u in StepExecution,
      where: u.workflow_id == ^workflow_id and u.is_compensation and u.status == :completed,
      where: u.compensation_for == parent_as(:step).step_name,
      where: u.completed_at >= parent_as(:step).completed_at
    )
  end

  # A stored name is matched against the code's steps, never made an atom: a
  # row from a deploy that had a step this one hasn't names nothing here.
  defp find_step_compensation(step_name, workflow_def) do
    step_def = Enum.find(workflow_def.steps, &(Atom.to_string(&1.name) == step_name))
    get_compensation_for_step(step_def, workflow_def.compensations)
  end

  defp get_compensation_for_step(%{name: name, opts: %{compensate: comp_name}}, compensations)
       when not is_nil(comp_name) do
    case Map.get(compensations, comp_name) do
      nil -> []
      compensation -> [{name, compensation}]
    end
  end

  defp get_compensation_for_step(_step_def, _compensations), do: []

  # Runs compensations in order and handles results
  defp run_compensations(execution, original_error, compensation_stack, workflow_def, config) do
    # Mark workflow as compensating. The error goes on the row now: a node
    # that stops hands the rollback to another (release_node_jobs/2), which
    # has only the row to tell it why the run is being undone.
    {:ok, exec} =
      execution
      |> WorkflowExecution.compensating_changeset()
      |> Ecto.Changeset.change(error: original_error)
      |> without_key(execution)
      |> cas_update!(config)

    # A run that failed as it resumed (a parallel failure, its deadline, a
    # timed-out input) hasn't run a step in this process, so its data isn't here.
    data =
      if Context.context() == %{},
        do: config |> stored(exec.id) |> data_of(),
        else: Context.context()

    # A compensation is handed its data as a step is: as it is stored.
    Process.put(:durable_context, data |> stored() |> restore_lane_keys(workflow_def))

    # Run each compensation, collecting results
    results =
      Enum.map(compensation_stack, fn {step_name, compensation} ->
        result = CompensationRunner.execute(compensation, exec.id, step_name, config)

        %{
          step: Atom.to_string(step_name),
          compensation: Atom.to_string(compensation.name),
          result: format_compensation_result(result)
        }
      end)

    # Check if any compensations failed
    failed_count = Enum.count(results, &(&1.result.status == "failed"))

    finished =
      if failed_count > 0 do
        WorkflowExecution.compensation_failed_changeset(exec, results, original_error)
      else
        exec
        |> WorkflowExecution.compensated_changeset(results)
        |> Ecto.Changeset.change(error: original_error)
      end

    {:ok, finished} =
      finished
      |> Ecto.Changeset.change(locked_by: nil, locked_at: nil, scheduled_at: nil)
      |> cas_update!(config)

    maybe_notify_parent(config, finished, :failed, original_error)
    {:error, original_error}
  end

  defp format_compensation_result({:ok, _output}), do: %{status: "completed"}
  defp format_compensation_result({:error, error}), do: %{status: "failed", error: error}

  # A retry or a snooze: back to :pending until `delay_ms` from now (no later
  # than the run's deadline), with the worker freed. The claim query skips the
  # row until then, and the next claim carries on at the same step.
  #
  # The next attempt starts from the context this one ended with: the stored
  # context (which keeps a parallel branch's marker) plus the attempt's own,
  # put_context/2 writes included. Keys are strings, so an atom and a string
  # copy of one key can't both be stored.
  defp park(config, execution, delay_ms) do
    release(config, execution, Process.get(:durable_context, %{}),
      scheduled_at: park_until(execution, delay_ms)
    )
  end

  defp park_until(execution, delay_ms) do
    at = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
    deadline = execution.deadline_at
    if deadline && DateTime.after?(at, deadline), do: deadline, else: at
  end

  @doc false
  # Telling a parent happens after the child's own commit, so it can be lost
  # with the connection. It's idempotent, so the sweep just says it again.
  @spec redeliver_lost_notices(Config.t(), pos_integer()) :: :ok
  def redeliver_lost_notices(%Config{} = config, older_than_seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_seconds, :second)

    query =
      from(c in WorkflowExecution,
        join: p in PendingEvent,
        on: p.workflow_id == c.parent_workflow_id,
        where: p.status == :pending and c.status in @ended,
        where: fragment("coalesce(?, ?)", c.completed_at, c.updated_at) < ^cutoff,
        where:
          p.event_name == fragment("'__parallel_done:' || ?::text", c.id) or
            p.event_name == fragment("'__child_done:' || ?::text", c.id),
        select: c
      )

    config
    |> Repo.all(query)
    |> Enum.each(fn child ->
      {status, data} = notice_for(child)
      maybe_notify_parent(config, child, status, data)
    end)
  rescue
    error ->
      Logger.error("[Durable] redelivering lost notices failed: #{Exception.message(error)}")
  end

  defp notice_for(%{status: :completed} = child),
    do: {:completed, EngineState.strip(child.context)}

  defp notice_for(%{status: :cancelled} = child), do: {:cancelled, child.error}
  defp notice_for(child), do: {:failed, child.error}

  @doc false
  # The connection went while recording this attempt, which says nothing about
  # the step. Like a lost worker it uses no attempt, and the run goes back on its
  # queue. If the database is still away, the stale-lock sweep does this later.
  # A rollback goes back to be rolled back, as a stopping node hands one back.
  @spec connection_lost(map(), Exception.t(), Config.t()) :: :waiting | :fenced
  def connection_lost(job, exception, %Config{} = config) do
    {:ok, run} = load_execution(config, job.id)

    if run.lock_token == job[:lock_token] and run.status in [:running, :compensating],
      do: release_after_lost_connection(config, run, exception),
      else: :fenced
  end

  defp release_after_lost_connection(config, run, exception) do
    error = %{type: "worker_lost", message: Exception.message(exception)}
    closed = StepRunner.close_attempts(config, [run.id], :failed, error)
    outcome = requeue(config, run, nil, back_to_undo(run))

    retry =
      if outcome == :waiting,
        do: &StepRunner.retry_after_lost(config, &1),
        else: fn _row -> nil end

    StepRunner.report_closed(config, closed, :failed, error, retry)
    outcome
  end

  @doc false
  # The process running this claim died, so nothing recorded how its attempt
  # ended. The attempt counts: it's closed as failed and the run goes back on
  # its queue, where the next claim retries the step or, out of attempts, fails
  # the run the normal way, compensations and all (StepRunner.execute/5).
  #
  # A process lost outside a step (between two, in a branch's `on:`, in a
  # parallel `into:`) has no attempt to count, and nothing says the workflow's
  # code is at fault: a deploy or an out-of-memory kill does this. The run goes
  # back on its queue and carries on. Code that dies every time would go round
  # for ever, so the third loss in a row at one step comes back
  # `{:error, error}` for the poller to fail the run, without compensating:
  # no step failed that its compensations answer for. A compensation that died
  # comes back the same way.
  @spec attempt_died(map(), map(), Config.t()) :: :waiting | :fenced | {:error, map()}
  def attempt_died(job, error, %Config{} = config) do
    {:ok, run} = load_execution(config, job.id)

    cond do
      run.lock_token == job[:lock_token] and run.status in [:running, :compensating] ->
        close_and_requeue(config, run, error)

      # Ended while this attempt ran (a cancel, say, clears the lock). No other
      # worker can have a row open, and nobody else will close this one.
      run.status in @ended ->
        StepRunner.close_running(config, [run.id], :failed, error)
        :fenced

      true ->
        :fenced
    end
  end

  @losses_allowed 3

  defp close_and_requeue(config, run, error) do
    closed = StepRunner.close_attempts(config, [run.id], :failed, error)
    delay = delay_after_death(config, run)

    outcome =
      cond do
        run.status != :running -> {:error, error}
        closed != [] -> requeue(config, run, delay)
        lost_in_a_row(config, run) >= @losses_allowed -> {:error, error}
        true -> requeue(config, run, nil)
      end

    # The run itself may be out of attempts, and so has no retry to report.
    backoff = if outcome == :waiting, do: delay
    StepRunner.report_closed(config, closed, :failed, error, fn _row -> backoff end)
    outcome
  end

  # Records this loss and counts the run's latest losses at the step it is at,
  # since it was last retried. A loss at another step in between starts again.
  defp lost_in_a_row(config, run) do
    Activity.record(config, "worker_lost",
      workflow_id: run.id,
      queue: run.queue,
      details: %{step: run.current_step}
    )

    since = run.retried_at || run.inserted_at

    [workflow_id: run.id, kinds: ["worker_lost"], since: since, durable: config.name]
    |> Activity.list!()
    |> Enum.take_while(&(&1.details["step"] == run.current_step))
    |> length()
  end

  # A run being rolled back goes back with its marker, or the next claim would
  # run its steps (rule 19). Its error has been on the row since it began.
  defp back_to_undo(%{status: :compensating} = run) do
    marker = %{"error" => run.error || %{}, "status" => "failed"}
    [engine_state: Map.put(run.engine_state, @rollback, marker)]
  end

  defp back_to_undo(_run), do: []

  # The context stays as it was last saved: the attempt that died changed nothing.
  defp requeue(config, run, delay, changes \\ []) do
    run
    |> Ecto.Changeset.change(
      [
        status: :pending,
        scheduled_at: requeue_at(run, delay),
        locked_by: nil,
        locked_at: nil,
        lock_token: nil
      ] ++ changes
    )
    |> cas_update(config)
    |> case do
      {:ok, requeued} ->
        DurablePubSub.broadcast_workflow(config, :workflow_parked, workflow_event(requeued))
        DurablePubSub.wake(config, requeued)
        :waiting

      _superseded ->
        :fenced
    end
  end

  # Nothing to wait for is ready now, whatever the database's clock says.
  defp requeue_at(_run, delay_ms) when delay_ms in [nil, 0], do: nil
  defp requeue_at(run, delay_ms), do: park_until(run, delay_ms)

  defp delay_after_death(config, run) do
    with {:ok, workflow_def} <- get_workflow_definition_from_execution(run),
         %{} = step <- Enum.find(workflow_def.steps, &(to_string(&1.name) == run.current_step)) do
      StepRunner.delay_after_death(step, run.id, config)
    else
      _no_such_step -> nil
    end
  end

  # Where this step has to run, when that isn't where the run is now: its own
  # `queue:`, or the queue the run started on. An unnamed branch only picks a
  # clause, so it runs where it is, and the clause's steps move for
  # themselves. A named one decides in a step, which moves like any step.
  defp queue_move(%{type: :branch, opts: opts}, _execution, _config)
       when not is_map_key(opts, :decider),
       do: nil

  defp queue_move(step, execution, config) do
    queue = to_string(step.opts[:queue] || execution.home_queue || execution.queue)
    # A stopping node doesn't start another step: it goes back for another node.
    if queue != execution.queue or Drainer.stopping?(config.name), do: queue
  end

  # Hands the run to another queue before `step`, so the step takes a slot
  # there. No `scheduled_at`: it's ready now, and a run already under way goes
  # by its age, ahead of runs started after it.
  defp move_to_queue(config, execution, step, queue, data) do
    home = execution.home_queue || execution.queue

    {:waiting, moved} =
      release(config, execution, data,
        queue: queue,
        home_queue: if(queue != home, do: home),
        current_step: Atom.to_string(step.name),
        scheduled_at: nil
      )

    DurablePubSub.wake(config, moved)
    {:waiting, moved}
  end

  # Back to :pending with the worker freed, keeping `data` for the next claim.
  defp release(config, execution, data, attrs) do
    context = execution.context |> Map.merge(stored(data)) |> EngineState.strip()

    # Without the record of a step's result: the run moves on to another
    # step, or runs this one again.
    engine_state =
      execution.engine_state |> Map.drop([@atom_keys, @done]) |> record_saved(context)

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(
        [context: context, status: :pending, locked_by: nil, locked_at: nil] ++ attrs
      )
      |> Ecto.Changeset.force_change(:engine_state, engine_state)
      |> cas_update!(config)

    DurablePubSub.broadcast_workflow(config, :workflow_parked, workflow_event(execution))
    {:waiting, execution}
  end

  defp handle_sleep(config, execution, opts) do
    wake_at = calculate_wake_time(opts)

    # Clear the lock alongside the :waiting + scheduled_at update. The
    # SleepWaker eventually flips this row back to :pending so the queue
    # poller can re-claim it; if the lock weren't cleared here it would
    # sit stale on the row until either stale-lock recovery (which only
    # acts on :running) or the (already-fixed) zombie sweeper got to it.
    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(
        status: :waiting,
        scheduled_at: wake_at,
        locked_by: nil,
        locked_at: nil
      )
      |> cas_update!(config)

    DurablePubSub.broadcast_workflow(config, :workflow_waiting, workflow_event(execution))

    {:waiting, execution}
  end

  defp handle_wait_for_event(config, execution, opts) do
    event_name = Keyword.fetch!(opts, :event_name)
    timeout_at = calculate_timeout_at(opts)

    # Create pending event record
    attrs = %{
      workflow_id: execution.id,
      event_name: event_name,
      step_name: execution.current_step,
      timeout_at: timeout_at,
      timeout_value: serialize_timeout_value(Keyword.get(opts, :timeout_value)),
      wait_type: :single
    }

    # An event sent before the run got here (`send_event(..., buffer: true)`,
    # a keyed start with `on_duplicate: {:send_event, name}`) resumes it now.
    {execution, _event} =
      enter_wait(config, execution, fn -> insert_event!(config, attrs) end, [event_name])

    DurablePubSub.broadcast_workflow(config, :workflow_waiting, workflow_event(execution))

    {:waiting, execution}
  end

  defp handle_wait_for_input(config, execution, opts) do
    input_name = Keyword.fetch!(opts, :input_name)
    timeout_at = calculate_timeout_at(opts)

    # Create pending input record
    attrs = %{
      workflow_id: execution.id,
      input_name: input_name,
      step_name: execution.current_step,
      input_type: Keyword.get(opts, :type, :free_text),
      prompt: Keyword.get(opts, :prompt),
      fields: Keyword.get(opts, :fields),
      metadata: Keyword.get(opts, :metadata),
      timeout_at: timeout_at,
      timeout_value: serialize_timeout_value(Keyword.get(opts, :timeout_value)),
      on_timeout: Keyword.get(opts, :on_timeout, :resume)
    }

    {execution, pending_input} =
      enter_wait(config, execution, fn ->
        {:ok, input} = %PendingInput{} |> PendingInput.changeset(attrs) |> Repo.insert(config)
        input
      end)

    DurablePubSub.broadcast_workflow(config, :workflow_waiting, workflow_event(execution))
    DurablePubSub.broadcast_input(config, :input_requested, pending_input_event(pending_input))

    {:waiting, execution}
  end

  defp handle_wait_for_any(config, execution, opts) do
    handle_wait_group(config, execution, opts, :any)
  end

  defp handle_wait_for_all(config, execution, opts) do
    handle_wait_group(config, execution, opts, :all)
  end

  defp handle_wait_group(config, execution, opts, wait_type) do
    event_names = Keyword.fetch!(opts, :event_names)
    timeout_at = calculate_timeout_at(opts)

    # Create wait group record
    group_attrs = %{
      workflow_id: execution.id,
      step_name: execution.current_step,
      wait_type: wait_type,
      event_names: event_names,
      timeout_at: timeout_at,
      timeout_value: serialize_timeout_value(Keyword.get(opts, :timeout_value))
    }

    # Events kept before the run got here are handed over now, as for
    # wait_for_event. Once a wait_for_any has its answer, the events kept for
    # its other names find no wait and stay kept.
    insert_group = fn ->
      {:ok, wait_group} =
        %WaitGroup{}
        |> WaitGroup.changeset(group_attrs)
        |> Repo.insert(config)

      for event_name <- event_names do
        insert_event!(config, %{
          workflow_id: execution.id,
          event_name: event_name,
          step_name: execution.current_step,
          wait_group_id: wait_group.id,
          wait_type: wait_type,
          timeout_at: timeout_at,
          timeout_value: serialize_timeout_value(Keyword.get(opts, :timeout_value))
        })
      end

      wait_group
    end

    {execution, _group} = enter_wait(config, execution, insert_group, event_names)

    DurablePubSub.broadcast_workflow(config, :workflow_waiting, workflow_event(execution))

    {:waiting, execution}
  end

  # The column holds UTC at microsecond precision, and takes nothing else.
  defp as_stored_time(%DateTime{} = datetime) do
    utc = DateTime.shift_zone!(datetime, "Etc/UTC")
    %{utc | microsecond: {elem(utc.microsecond, 0), 6}}
  end

  defp calculate_wake_time(opts) do
    cond do
      Keyword.has_key?(opts, :until) ->
        as_stored_time(opts[:until])

      Keyword.has_key?(opts, :duration_ms) ->
        DateTime.add(DateTime.utc_now(), opts[:duration_ms], :millisecond)

      Keyword.has_key?(opts, :seconds) ->
        DateTime.add(DateTime.utc_now(), opts[:seconds], :second)

      Keyword.has_key?(opts, :minutes) ->
        DateTime.add(DateTime.utc_now(), opts[:minutes] * 60, :second)

      Keyword.has_key?(opts, :hours) ->
        DateTime.add(DateTime.utc_now(), opts[:hours] * 3600, :second)

      Keyword.has_key?(opts, :days) ->
        DateTime.add(DateTime.utc_now(), opts[:days] * 86_400, :second)

      true ->
        DateTime.add(DateTime.utc_now(), 60, :second)
    end
  end

  defp calculate_timeout_at(opts) do
    case Keyword.get(opts, :timeout) do
      nil ->
        nil

      timeout_ms when is_integer(timeout_ms) ->
        DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond)
    end
  end

  # A copy of the wait's `:timeout_value` for the wait's row, to show what it
  # will resume with. The wait returns the call's own value, never this copy.
  # Every value is wrapped, so a map of the user's with an "__atom__" key isn't
  # taken for the wrapper.
  defp serialize_timeout_value(nil), do: nil

  defp serialize_timeout_value(value) when is_atom(value),
    do: %{"__atom__" => Atom.to_string(value)}

  defp serialize_timeout_value(value),
    do: %{"__value__" => sanitize_for_json(value)}

  # ============================================================================
  # PubSub event builders
  # ============================================================================

  defp workflow_event(%WorkflowExecution{} = execution) do
    %{
      id: execution.id,
      workflow_module: execution.workflow_module,
      workflow_name: execution.workflow_name,
      status: execution.status,
      queue: execution.queue,
      current_step: execution.current_step,
      started_at: execution.started_at,
      completed_at: execution.completed_at,
      inserted_at: execution.inserted_at,
      updated_at: execution.updated_at
    }
  end

  defp pending_input_event(%PendingInput{} = pending) do
    %{
      id: pending.id,
      workflow_id: pending.workflow_id,
      input_name: pending.input_name,
      step_name: pending.step_name,
      input_type: pending.input_type,
      status: pending.status,
      prompt: pending.prompt,
      timeout_at: pending.timeout_at,
      inserted_at: pending.inserted_at
    }
  end
end
