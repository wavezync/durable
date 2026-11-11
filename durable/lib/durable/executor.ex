defmodule Durable.Executor do
  @moduledoc """
  The main workflow executor.

  Responsible for:
  - Starting new workflow executions
  - Executing workflow steps sequentially
  - Managing workflow state and context
  - Handling workflow suspension and resumption
  """

  alias Durable.Config
  alias Durable.Context
  alias Durable.Definition.Workflow
  alias Durable.Executor.CompensationRunner
  alias Durable.Executor.StepRunner
  alias Durable.Keys
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Queue.Drainer
  alias Durable.Repo
  alias Durable.Storage.Schemas.PendingEvent
  alias Durable.Storage.Schemas.PendingInput
  alias Durable.Storage.Schemas.StepExecution
  alias Durable.Storage.Schemas.WaitGroup
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query

  require Logger

  # Context key every save records the run's top-level string keys under, so
  # that the data comes back the shape it left in (see restore_keys/1).
  @string_keys "__string_keys__"
  # What 1.5.0 recorded on a park instead. Kept for runs parked over an upgrade.
  @atom_keys "__atom_keys__"

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

  def storable_input(input) do
    case sanitize_for_json(input) do
      map when not is_struct(map) -> {:ok, map}
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
    cancellable =
      from(w in WorkflowExecution,
        where: w.id == ^workflow_id and w.status in [:pending, :running, :waiting],
        select: w
      )

    case Repo.update_all(config, cancellable,
           set: [
             status: :cancelled,
             error: error,
             completed_at: now,
             updated_at: now,
             locked_by: nil,
             locked_at: nil,
             lock_token: nil
           ]
         ) do
      {1, [cancelled]} ->
        after_cancel(config, cancelled)
        :ok

      {0, _} ->
        if Repo.get(config, WorkflowExecution, workflow_id),
          do: {:error, :already_completed},
          else: {:error, :not_found}
    end
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
         {:ok, retried} <- reset_for_retry(config, execution) do
      DurablePubSub.broadcast_workflow(config, :workflow_retried, workflow_event(retried))
      DurablePubSub.wake(config, retried)
      {:ok, workflow_id}
    end
  end

  defp ensure_retryable(:failed), do: :ok

  defp ensure_retryable(status) when status in [:compensated, :compensation_failed],
    do: {:error, :rolled_back}

  defp ensure_retryable(_status), do: {:error, :not_failed}

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
      parallel_children(execution.context) ->
        retry_parallel_block(config, execution, retry_attrs)

      execution.key && not execution.holds_key ->
        retry_and_retake(config, execution, retry_attrs)

      execution.key ->
        retry_holder(config, execution, retry_attrs)

      true ->
        execution
        |> Ecto.Changeset.change([status: :pending] ++ retry_attrs)
        |> cas_update(config)
        |> not_failed_if_superseded()
    end
  end

  # Reopens a run that holds its key, only if it still does: a start may be
  # taking the key from it right now, and reopened regardless, the two would
  # both run. If the key went, this is a retry that has to take it back.
  defp retry_holder(config, execution, retry_attrs) do
    changeset = Ecto.Changeset.change(execution, [status: :pending] ++ retry_attrs)

    case cas_update(%{changeset | filters: %{holds_key: true}}, config) do
      {:error, :superseded} ->
        case load_execution(config, execution.id) do
          {:ok, %{status: :failed, holds_key: false} = lost} ->
            retry_and_retake(config, lost, retry_attrs)

          _retried_or_gone ->
            {:error, :not_failed}
        end

      result ->
        result
    end
  end

  # A run whose key moved to another run takes it back by the start rules
  # (releasing a closed holder `reuse:` lets go) in the same transaction that
  # reopens it, or the retry is refused with {:key_taken, holder_id}.
  defp retry_and_retake(config, execution, retry_attrs) do
    workflow_def = definition_or_nil(execution)

    {:ok, result} =
      Repo.transaction(config, fn ->
        with {:ok, key_attrs} <- Keys.retake(config, execution, workflow_def) do
          execution
          |> Ecto.Changeset.change([status: :pending] ++ retry_attrs ++ key_attrs)
          |> Ecto.Changeset.unique_constraint(:key,
            name: :workflow_executions_key_holder_index
          )
          |> cas_update(config, mode: :savepoint)
          |> not_failed_if_superseded()
          |> key_taken_if_conflict(config, execution)
        end
      end)

    result
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

  defp parallel_children(context),
    do: Map.get(context, "__parallel_children") || Map.get(context, :__parallel_children)

  # A run that failed inside a parallel block is waiting on a WaitGroup of
  # child runs. Re-queue only the children that failed, re-open their
  # completion events and the group, and park the parent in :waiting again —
  # the last child to finish wakes it, exactly as on the first pass.
  defp retry_parallel_block(config, parent, retry_attrs) do
    Repo.transaction(config, fn -> reopen_parallel_block(config, parent, retry_attrs) end)
  end

  defp reopen_parallel_block(config, parent, retry_attrs) do
    key_attrs =
      case Keys.retake(config, parent, definition_or_nil(parent)) do
        {:ok, attrs} -> attrs
        {:error, reason} -> config.repo.rollback(reason)
      end

    child_ids = Map.keys(parallel_children(parent.context))

    group_id =
      Map.get(parent.context, "__parallel_wait_group_id") ||
        Map.get(parent.context, :__parallel_wait_group_id)

    now = DateTime.utc_now()

    children =
      Repo.all(
        config,
        from(c in WorkflowExecution,
          where: c.id in ^child_ids and c.status != :completed,
          select: {c.id, c.status}
        )
      )

    if Enum.any?(children, fn {_, s} -> s in [:compensated, :compensation_failed] end),
      do: config.repo.rollback(:rolled_back)

    failed_ids = for {id, s} <- children, s in [:failed, :cancelled], do: id
    events = Enum.map(failed_ids, &"__parallel_done:#{&1}")

    Repo.update_all(config, from(c in WorkflowExecution, where: c.id in ^failed_ids),
      set: [status: :pending, updated_at: now] ++ retry_attrs
    )

    Repo.update_all(
      config,
      from(e in PendingEvent, where: e.wait_group_id == ^group_id and e.event_name in ^events),
      set: [status: :pending, payload: nil, completed_at: nil, updated_at: now]
    )

    group = Repo.get(config, WaitGroup, group_id)

    {:ok, _} =
      group
      |> Ecto.Changeset.change(
        status: :pending,
        completed_at: nil,
        received_events: Map.drop(group.received_events, events)
      )
      |> Repo.update(config)

    parent
    |> Ecto.Changeset.change([status: :waiting] ++ retry_attrs ++ key_attrs)
    |> Ecto.Changeset.unique_constraint(:key, name: :workflow_executions_key_holder_index)
    |> cas_update(config, mode: :savepoint)
    |> not_failed_if_superseded()
    |> key_taken_if_conflict(config, parent)
    |> case do
      {:ok, retried} -> retried
      {:error, reason} -> config.repo.rollback(reason)
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
         true <- execution.status not in [:pending, :running, :waiting] || {:error, :not_finished},
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
  """
  @spec execute_workflow(String.t(), Config.t()) ::
          {:ok, map()} | {:waiting, map()} | {:error, term()}
  def execute_workflow(workflow_id, %Config{} = config) do
    with {:ok, execution} <- load_execution(config, workflow_id),
         true <- execution.status in [:pending, :running] || {:error, :superseded},
         {:ok, workflow_def} <- definition_or_leave(config, execution),
         {:ok, execution} <- take_waiting_key(config, execution, workflow_def),
         resumed = execution.current_step != nil,
         {:ok, execution} <- mark_running(config, execution) do
      # Set workflow ID for logging/observability
      Context.set_workflow_id(execution.id)

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
      if past_deadline_by?(execution, @missing_code_grace_ms),
        do: time_out_without_code(config, execution),
        else: leave_for_its_code(config, execution, reason)
    end
  end

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
    parallel_step_flag =
      Map.get(execution.context, "__parallel_step") ||
        Map.get(execution.context, :__parallel_step)

    if parallel_step_flag do
      result = execute_parallel_step(execution, workflow_def, config)
      Context.cleanup()
      result
    else
      # Pipeline model: start with workflow input or restored context
      initial_data =
        if execution.context != %{} do
          restore_keys(execution.context)
        else
          execution.input
        end

      # Execute steps with pipeline data flow
      result = execute_steps(workflow_def.steps, execution, config, initial_data)

      # Cleanup
      Context.cleanup()

      result
    end
  end

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp string_key_names(map), do: for({key, _} <- map, is_binary(key), do: key)

  # Top-level context keys come back from JSON as strings. Every save records
  # which were strings, so a step sees the same data however the run got back
  # to it: a retry, a wait, a queue move, a crash (a first step still reads
  # input["id"]). What the record doesn't list becomes an atom if the code knows
  # it, which covers what was merged in after the save, such as a wait's answer.
  # A run saved before the record existed has every key treated that way.
  defp restore_keys(%{@string_keys => strings} = context) when is_list(strings) do
    {kept, others} = context |> Map.delete(@string_keys) |> Map.split(strings)
    others |> atomize_keys() |> Map.merge(kept)
  end

  defp restore_keys(%{@atom_keys => atom_keys} = context) when is_list(atom_keys) do
    context
    |> Map.delete(@atom_keys)
    |> Map.new(fn {key, value} ->
      if key in atom_keys, do: {Context.known_key(key), value}, else: {key, value}
    end)
  end

  defp restore_keys(context), do: atomize_keys(context)

  # Atomize top-level keys in map (for context restored from DB)
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {Context.known_key(key), value}
      {key, value} -> {key, value}
    end)
  end

  @doc """
  Resumes a waiting workflow.

  ## Options

  - `:inline` - If true, execute synchronously instead of via queue (default: false).
    Runs until the run finishes or parks: a retry, snooze, wait or move to a
    step's queue is left for the queue
  - `:durable` - The Durable instance name (default: Durable)
  """
  @spec resume_workflow(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resume_workflow(workflow_id, additional_context \\ %{}, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)
    # Sanitize at the API boundary — callers (provide_input, send_event,
    # timeout workers) supply maps that can carry arbitrary user terms.
    safe_additional = sanitize_for_json(additional_context)

    with {:ok, execution} <- load_execution(config, workflow_id),
         true <- execution.status == :waiting || {:error, :not_waiting},
         {:ok, resumed} <- mark_resumed(config, execution, safe_additional) do
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
  defp mark_resumed(config, execution, additional_context) do
    execution
    |> Ecto.Changeset.change(
      context: Map.merge(execution.context || %{}, additional_context),
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
      %WorkflowExecution{} = execution -> {:ok, execution}
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
    error = %{
      type: "timeout",
      message:
        "the run passed its #{format_timeout(workflow_def.opts[:timeout])} timeout " <>
          "before #{step.name}"
    }

    fail_at(execution, step, error, workflow_def, config)
  end

  # The TimeoutWorker resumes a run whose `on_timeout: :fail` wait timed out
  # with the error under `__fail__`, so the run fails here, in the executor,
  # rather than being written off from outside.
  defp resume_failure(%{context: %{"__fail__" => error}}), do: error
  defp resume_failure(_execution), do: nil

  # Fail the run at `step` the way a failed step would — so its compensations
  # run — and stop any child runs it waited on.
  defp fail_at(execution, step, error, workflow_def, config) do
    cancel_child_workflows(config, execution.id)

    {:ok, exec} =
      execution
      |> Ecto.Changeset.change(
        current_step: Atom.to_string(step.name),
        # A retried run must not fail again on the same marker.
        context: Map.delete(execution.context || %{}, "__fail__")
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

  defp execute_steps(steps, execution, config, initial_data) do
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
      run_steps(steps, steps_to_run, execution, workflow_def, config, initial_data)
    end
  end

  # A resumed run picks up at its current step, found by name. The steps of
  # every branch clause sit side by side in the definition, so a run that
  # stopped inside a branch goes on with the rest of its own clause and then
  # whatever follows the block.
  defp steps_to_resume(steps, nil), do: steps

  defp steps_to_resume(steps, current) do
    rest = Enum.drop_while(steps, &(Atom.to_string(&1.name) != current))

    case Enum.find(steps, &(&1.type == :branch and named?(&1.opts[:all_steps], current))) do
      nil ->
        rest

      branch ->
        rest_of_clause(branch, current, steps) ++
          Enum.reject(rest, &(&1.name in branch.opts[:all_steps]))
    end
  end

  defp rest_of_clause(branch, current, steps) do
    branch.opts[:clauses]
    |> Enum.find_value(fn {_pattern, names} -> if named?(names, current), do: names end)
    |> Enum.drop_while(&(Atom.to_string(&1) != current))
    |> Enum.map(fn name -> Enum.find(steps, &(&1.name == name)) end)
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

    case StepRunner.execute(step, data, exec.id, config, exec.deadline_at) do
      {:ok, new_data} ->
        # Save data as context and continue to next step
        # save_data_as_context merges orchestration keys from process dict
        {:ok, exec} = save_data_as_context(config, exec, new_data)
        # Pass the DB-persisted context forward (includes orchestration keys)
        execute_steps_recursive(
          remaining_steps,
          exec,
          step_index,
          workflow_def,
          config,
          exec.context
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

      {wait_type, opts}
      when wait_type in [:sleep, :wait_for_event, :wait_for_input, :wait_for_any, :wait_for_all] ->
        # Save current data before waiting
        {:ok, exec} = save_data_as_context(config, exec, data, :keep)
        handle_wait_result(config, exec, wait_type, opts)

      {:call_workflow, opts} ->
        {:ok, exec} = save_data_as_context(config, exec, data, :keep)
        handle_call_workflow(config, exec, opts)

      {:error, error} ->
        handle_step_failure(exec, error, workflow_def, config)

      {:cancel, reason, scope} ->
        cancel_from_step(config, exec, reason, scope)

      {:park, delay_ms} ->
        park(config, exec, delay_ms)
    end
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
    {:ok, exec} = save_data_as_context(config, exec, data)

    case find_jump_target(target_step, remaining_steps, step.name, step_index) do
      {:ok, target_steps} ->
        # Use the merged exec.context (prior put_context writes + goto data),
        # not the goto's raw data — otherwise put_context writes from prior
        # steps would silently vanish across the goto boundary.
        execute_steps_recursive(
          target_steps,
          exec,
          step_index,
          workflow_def,
          config,
          exec.context
        )

      {:error, reason} ->
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
  # wait on a run that's still :running. Returns the waiting run and what
  # `insert_wait` returned.
  defp enter_wait(config, execution, insert_wait) do
    {:ok, entered} =
      Repo.transaction(config, fn ->
        wait = insert_wait.()

        {:ok, waiting} =
          execution
          |> Ecto.Changeset.change(status: :waiting, scheduled_at: nil)
          |> cas_update!(config)

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
        notify_orchestration_parent(config, child, :completed, child.context)

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

          {:decision, exec, step, target_step, new_data} ->
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
      if pattern == value, do: steps
    end)
  end

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

    case StepRunner.execute(step, data, exec.id, config, exec.deadline_at) do
      {:ok, new_data} ->
        {:ok, exec} = save_data_as_context(config, exec, new_data)

        execute_branch_steps_sequential(
          rest,
          exec,
          step_index,
          workflow_def,
          config,
          exec.context
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

      {:error, error} ->
        handle_step_failure(exec, error, workflow_def, config)

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
    parallel_step_names = opts[:steps] || []
    all_parallel_steps = opts[:all_steps] || []
    error_strategy = opts[:error_strategy] || :fail_fast
    into_fn = opts[:into_fn]

    # Find actual step definitions for parallel steps
    ordered_steps = find_ordered_steps(remaining_steps, parallel_step_names)

    # Save data before parallel execution
    {:ok, exec} = save_data_as_context(config, exec, data)

    # Check if we're resuming after fan-in (all children completed)
    # Context may have atom or string keys depending on whether it came from
    # a changeset (atom) or from DB deserialization (string)
    has_children =
      Map.get(exec.context, "__parallel_children") ||
        Map.get(exec.context, :__parallel_children)

    if has_children do
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
        {child.id, Atom.to_string(step.name), returns_key}
      end)

    # Build event names and children metadata map
    event_names = Enum.map(children_meta, fn {id, _, _} -> "__parallel_done:#{id}" end)

    children_map =
      Map.new(children_meta, fn {id, step_name, returns_key} ->
        returns_str = if is_atom(returns_key), do: Atom.to_string(returns_key), else: returns_key
        {id, %{"step_name" => step_name, "returns_key" => returns_str}}
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

    # Store parallel metadata in parent context for resume
    parallel_context = %{
      "__parallel_children" => children_map,
      "__parallel_wait_group_id" => wait_group.id,
      "__parallel_error_strategy" => Atom.to_string(error_strategy)
    }

    {:ok, exec} =
      exec
      |> Ecto.Changeset.change(
        context:
          (exec.context || %{})
          |> Map.merge(parallel_context)
          |> Map.put(@string_keys, string_key_names(exec.context || %{})),
        status: :waiting,
        scheduled_at: nil
      )
      |> cas_update!(config)

    exec
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
      input: data,
      context:
        parent_context
        |> Map.put("__parallel_step", Atom.to_string(step.name))
        |> Map.put(@string_keys, string_key_names(parent_context)),
      parent_workflow_id: parent_exec.id,
      root_workflow_id: parent_exec.root_workflow_id || parent_exec.id,
      trigger: :parent,
      current_step: Atom.to_string(step.name),
      # A branch is part of the run, so the run's deadline stops it too.
      deadline_at: parent_exec.deadline_at
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> Repo.insert(config)
  end

  # Execute a single parallel step (called when a child execution is picked up)
  # The marker stays in the saved context: without it, a branch that wakes up
  # would run as a whole workflow and repeat every step after the block.
  defp save_branch_context(config, execution, data, step_name) do
    save_data_as_context(config, execution, Map.put(data, "__parallel_step", step_name))
  end

  defp execute_parallel_step(execution, workflow_def, config) do
    step_name_str =
      Map.get(execution.context, "__parallel_step") ||
        Map.get(execution.context, :__parallel_step)

    step_name = String.to_existing_atom(step_name_str)

    step_def = Enum.find(workflow_def.steps, &(&1.name == step_name))

    cond do
      is_nil(step_def) ->
        mark_failed(config, execution, %{
          type: "parallel_step_not_found",
          message: "Step #{step_name} not found in workflow"
        })

      # An `on_timeout: :fail` wait timed out. Run again, the step would only
      # ask again, for ever.
      error = resume_failure(execution) ->
        {:ok, execution} =
          execution
          |> Ecto.Changeset.change(context: Map.delete(execution.context, "__fail__"))
          |> cas_update!(config)

        mark_failed(config, execution, error)

      true ->
        run_parallel_step(execution, step_def, step_name_str, config)
    end
  end

  defp run_parallel_step(execution, step_def, step_name_str, config) do
    # Merge the inherited parent context into the pipeline data so that
    # get_context/1 inside the step body resolves keys set by prior
    # put_context/2 calls in the parent's non-parallel steps.
    #
    # StepRunner will Process.put(:durable_context, data) before running
    # the body, which is why we need these keys to live inside `data`.
    # The __parallel_step marker is internal plumbing — strip it from
    # what the user sees.
    data =
      execution.context
      |> Map.drop(["__parallel_step", :__parallel_step, @atom_keys])
      |> Map.merge(execution.input)
      |> restore_keys()

    case StepRunner.execute(step_def, data, execution.id, config, execution.deadline_at) do
      {:ok, output_data} ->
        mark_completed(config, execution, output_data)

      {:error, error} ->
        mark_failed(config, execution, error)

      {:cancel, reason, scope} ->
        cancel_from_step(config, execution, reason, scope)

      {:park, delay_ms} ->
        park(config, execution, delay_ms)

      {wait_type, wait_opts}
      when wait_type in [:sleep, :wait_for_event, :wait_for_input, :wait_for_any, :wait_for_all] ->
        {:ok, exec} = save_branch_context(config, execution, data, step_name_str)
        handle_wait_result(config, exec, wait_type, wait_opts)

      {:call_workflow, call_opts} ->
        {:ok, exec} = save_branch_context(config, execution, data, step_name_str)
        handle_call_workflow(config, exec, call_opts)

      {:decision, _target, _data} ->
        mark_failed(config, execution, %{
          type: "parallel_decision_not_supported",
          message: "decisions not supported in parallel blocks"
        })
    end
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

    children_map =
      Map.get(exec.context, "__parallel_children") ||
        Map.get(exec.context, :__parallel_children)

    error_strategy_str =
      Map.get(exec.context, "__parallel_error_strategy") ||
        Map.get(exec.context, :__parallel_error_strategy) ||
        "fail_fast"

    error_strategy = String.to_existing_atom(error_strategy_str)
    # When into_fn is provided, always collect all results
    effective_strategy = if into_fn, do: :complete_all, else: error_strategy

    # Load all child executions and build results
    results = build_results_from_children(children_map, config)

    # Clean parallel metadata from context before continuing
    # Drop both string and atom keys since context may have either
    clean_ctx =
      exec.context
      |> Map.drop([
        "__parallel_children",
        "__parallel_wait_group_id",
        "__parallel_error_strategy",
        :__parallel_children,
        :__parallel_wait_group_id,
        :__parallel_error_strategy
      ])

    # Check for fail_fast
    errors = Enum.filter(results, fn {_key, result} -> match?({:error, _}, result) end)

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
        exec: exec,
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
      returns_key = String.to_atom(meta["returns_key"])

      case Repo.get(config, WorkflowExecution, child_id) do
        %{status: :completed, context: ctx} ->
          {returns_key, {:ok, ctx}}

        %{status: status, error: error}
        when status in [:failed, :cancelled, :compensation_failed] ->
          {returns_key, {:error, error || %{type: "child_failed", message: "#{status}"}}}

        _ ->
          {returns_key, {:error, %{type: "child_incomplete", message: "child not finished"}}}
      end
    end)
  end

  defp find_ordered_steps(remaining_steps, step_names) do
    steps_to_execute =
      Enum.filter(remaining_steps, fn step -> step.name in step_names end)

    Enum.map(step_names, fn name ->
      Enum.find(steps_to_execute, fn s -> s.name == name end)
    end)
    |> Enum.reject(&is_nil/1)
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

    case apply_parallel_into(into_fn, base_ctx, results) do
      {:ok, final_ctx} ->
        {:ok, exec} = save_data_as_context(config, exec, final_ctx)
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
        {:ok, exec} = save_data_as_context(config, exec, goto_ctx)

        case find_jump_target(target_step, remaining_steps, parallel_step_name, step_index) do
          {:ok, target_steps} ->
            execute_steps_recursive(
              target_steps,
              exec,
              step_index,
              workflow_def,
              config,
              goto_ctx
            )

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

  # Apply into function or default to __results__
  defp apply_parallel_into(nil, base_ctx, results) do
    # No into function - add results to __results__ key
    # Serialize tuples to lists for JSON storage
    serialized_results = serialize_parallel_results(results)
    {:ok, Map.put(base_ctx, :__results__, serialized_results)}
  end

  defp apply_parallel_into(into_fn, base_ctx, results) when is_function(into_fn, 2) do
    # User callbacks get raw {:ok, value} / {:error, reason} tuples so they
    # can pattern-match cleanly — this is the intended ergonomic API.
    # Any tuples that leak into the callback's return are sanitized at the
    # save boundary (save_data_as_context -> sanitize_for_json), so storage
    # can't crash regardless of what shape the user returns.
    into_fn.(base_ctx, results)
  catch
    # A throw or an exit too: uncaught, it would fail the run from the worker,
    # past its compensations.
    kind, reason -> {:error, caught_error(kind, reason, __STACKTRACE__)}
  end

  # Serialize tagged tuples to lists for JSON storage
  # {:ok, data} -> ["ok", data], {:error, reason} -> ["error", reason]
  defp serialize_parallel_results(results) do
    Map.new(results, fn {key, value} ->
      serialized_key = if is_atom(key), do: Atom.to_string(key), else: key

      serialized_value =
        case value do
          {:ok, data} -> ["ok", data]
          {:error, reason} -> ["error", serialize_error_reason(reason)]
          other -> other
        end

      {serialized_key, serialized_value}
    end)
  end

  # Serialize error reasons that might contain atoms
  defp serialize_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_error_reason(reason) when is_map(reason), do: reason
  defp serialize_error_reason(reason) when is_binary(reason), do: reason
  defp serialize_error_reason(reason), do: inspect(reason)

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

  defp find_jump_target(target_step, remaining_steps, current_step, step_index) do
    with :ok <- validate_target_exists(target_step, step_index),
         :ok <- validate_not_self(target_step, current_step),
         :ok <- validate_forward_jump(target_step, current_step, step_index) do
      find_target_in_remaining(target_step, remaining_steps)
    end
  end

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

  # Saves data as the workflow context in DB (for persistence/resume)
  # Also merges orchestration keys from process dict to ensure child workflow
  # references are persisted through DB round-trips
  defp save_data_as_context(config, execution, data, markers \\ :drop) do
    # Persist the step's cumulative context — everything the user wrote via
    # put_context/2 during the step body PLUS everything they returned from
    # the step. Step return wins on key collision because the return value
    # is the step's explicit contract.
    #
    # Rationale: Context is cumulative. Before this change, put_context/2
    # writes were silently dropped unless the user also returned those keys,
    # which made the put_context API a footgun.
    process_ctx = Process.get(:durable_context, %{})

    # Merge preserving key shapes: step return wins over prior writes on
    # collision. We deliberately don't atomize keys here — users may return
    # maps with mixed atom/string keys (e.g., via Helpers.assign/3 layered
    # on top of string-keyed DB-round-tripped input) and atomize_keys/1
    # deduplicates non-deterministically via Map.new, which corrupted
    # values in the branch DSL path.
    merged =
      process_ctx
      |> Map.merge(data)
      |> sanitize_for_json()
      |> finish_wait_markers(markers)

    # The record of its key shapes is stored, but the next step mustn't see it.
    with {:ok, saved} <-
           execution
           |> Ecto.Changeset.change(
             context: Map.put(merged, @string_keys, string_key_names(merged))
           )
           |> cas_update!(config) do
      {:ok, %{saved | context: merged}}
    end
  end

  # A step that's suspending again still needs them when it re-runs. Kept once
  # it's finished, a marker would stand in for a later wait's own.
  defp finish_wait_markers(context, :keep), do: context
  defp finish_wait_markers(context, :drop), do: StepRunner.without_wait_markers(context)

  defp mark_completed(config, execution, final_data) do
    # Sanitize before persisting — the final step may return data containing
    # raw tuples (e.g., child executions in a parallel block complete with
    # {:ok, value} that gets unwrapped but sometimes leaks through).
    safe_final = sanitize_for_json(final_data)

    {:ok, execution} =
      execution
      |> WorkflowExecution.status_changeset(:completed, %{
        context: safe_final,
        completed_at: DateTime.utc_now(),
        current_step: nil
      })
      # Forced: the in-memory context lacks the stored record of key shapes
      # (save_data_as_context/3), so it can look unchanged when the row isn't.
      |> Ecto.Changeset.force_change(:context, safe_final)
      |> Ecto.Changeset.change(locked_by: nil, locked_at: nil, scheduled_at: nil)
      |> cas_update!(config)

    DurablePubSub.broadcast_workflow(config, :workflow_completed, workflow_event(execution))

    maybe_notify_parent(config, execution, :completed, safe_final)

    {:ok, execution}
  end

  defp mark_failed(config, execution, error) do
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
        |> Ecto.Changeset.change(locked_by: nil, locked_at: nil, scheduled_at: nil)
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

  def sanitize_for_json(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {sanitize_json_key(k), sanitize_for_json(v)} end)
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
  defp sanitize_json_key(k) when is_atom(k), do: sanitize_for_json(k)
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
  # A failed branch under :fail_fast ends the block now. In the same transaction
  # as the parent's resume, so the parent finds every branch finished. nil when
  # the block carries on.
  defp stop_block_on_failure(repo, branch, :failed, %{just_completed: false, wait_group: group})
       when group.status == :pending do
    parent = repo.get(WorkflowExecution, branch.parent_workflow_id)

    if parent && parent.context["__parallel_error_strategy"] == "fail_fast" do
      {:ok, _} =
        group
        |> Ecto.Changeset.change(status: :completed, completed_at: DateTime.utc_now())
        |> repo.update()

      repo.update_all(
        from(e in PendingEvent, where: e.wait_group_id == ^group.id and e.status == :pending),
        set: [status: :cancelled, completed_at: DateTime.utc_now()]
      )

      {:ok, cancel_siblings(repo, branch, Map.keys(parent.context["__parallel_children"]))}
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
  def resume_parent_in_multi(repo, workflow_id, additional_context) do
    safe_context = sanitize_for_json(additional_context)

    case repo.get(WorkflowExecution, workflow_id) do
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
        result_context = build_parent_result_context(parent, execution.id, payload)
        atomic_fulfill_event_and_resume_parent(config, pending_event, parent, result_context)
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

  defp atomic_fulfill_event_and_resume_parent(config, pending_event, parent, result_context) do
    safe_context = sanitize_for_json(result_context)

    multi =
      Ecto.Multi.new()
      |> lock_run(parent.id)
      |> Ecto.Multi.update(
        :event,
        PendingEvent.receive_changeset(pending_event, pending_event.payload || %{})
      )
      |> Ecto.Multi.run(:parent, fn repo, _changes ->
        # The lock makes the child's own notice and settle_child/2 take turns,
        # so the second one sees the parent moved on.
        case repo.get(WorkflowExecution, parent.id) do
          nil ->
            {:error, :parent_not_found}

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

  # Build context update for parent with child result stored under the right key
  defp build_parent_result_context(parent, child_id, payload) do
    parent_context = parent.context || %{}

    # Find which ref this child belongs to by looking for __child:ref = child_id
    ref =
      Enum.find_value(parent_context, fn
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
  @spec after_cancel(Config.t(), WorkflowExecution.t()) :: :ok
  def after_cancel(config, cancelled) do
    close_out_cancelled(config, cancelled)
    # A parent waiting on this run would otherwise wait forever.
    maybe_notify_parent(config, cancelled, :cancelled, cancelled.error)
    :ok
  end

  defp close_out_cancelled(config, cancelled) do
    # Its node may be gone, leaving nobody else to close its attempt.
    StepRunner.close_cancelled(config, cancelled.id)
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
  defp parent_run(config, %{parent_workflow_id: id}), do: Repo.get(config, WorkflowExecution, id)

  defp parallel_branch?(execution),
    do:
      Map.has_key?(execution.context, "__parallel_step") or
        Map.has_key?(execution.context, :__parallel_step)

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

  # Handles step failure by running compensations if needed
  defp handle_step_failure(execution, error, workflow_def, config) do
    # `error` is a map column: a step's `{:error, "declined"}` must become a
    # map here, or the failed/compensated write is rejected and the run stays
    # :running.
    error = storable_error(error)

    # Get the compensation stack from completed steps
    compensation_stack = build_compensation_stack(execution.id, workflow_def, config)

    if compensation_stack == [] do
      # No compensations to run - just mark as failed
      mark_failed(config, execution, error)
    else
      # Run compensations
      run_compensations(execution, error, compensation_stack, workflow_def, config)
    end
  end

  # Builds the compensation stack from completed steps in reverse order
  defp build_compensation_stack(workflow_id, workflow_def, config) do
    # Get completed non-compensation steps
    query =
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id,
        where: s.status == :completed,
        where: s.is_compensation == false,
        order_by: [desc: s.completed_at],
        select: s.step_name
      )

    # A step that completed twice (its lock was lost before the run moved on,
    # so it ran again) is still one step to undo.
    completed_steps = config |> Repo.all(query) |> Enum.uniq()

    # Map to steps that have compensations
    completed_steps
    |> Enum.map(&String.to_atom/1)
    |> Enum.flat_map(&find_step_compensation(&1, workflow_def))
  end

  defp find_step_compensation(step_name, workflow_def) do
    step_def = Enum.find(workflow_def.steps, &(&1.name == step_name))
    get_compensation_for_step(step_name, step_def, workflow_def.compensations)
  end

  defp get_compensation_for_step(step_name, %{opts: %{compensate: comp_name}}, compensations)
       when not is_nil(comp_name) do
    case Map.get(compensations, comp_name) do
      nil -> []
      compensation -> [{step_name, compensation}]
    end
  end

  defp get_compensation_for_step(_step_name, _step_def, _compensations), do: []

  # Runs compensations in order and handles results
  defp run_compensations(execution, original_error, compensation_stack, _workflow_def, config) do
    # Mark workflow as compensating
    {:ok, exec} =
      execution
      |> WorkflowExecution.compensating_changeset()
      |> cas_update!(config)

    # A run that failed as it resumed (a parallel failure, its deadline, a
    # timed-out input) hasn't run a step in this process, so its data isn't here.
    if Context.context() == %{}, do: Process.put(:durable_context, restore_keys(exec.context))

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

  defp notice_for(%{status: :completed} = child), do: {:completed, child.context}
  defp notice_for(%{status: :cancelled} = child), do: {:cancelled, child.error}
  defp notice_for(child), do: {:failed, child.error}

  @doc false
  # The connection went while recording this attempt, which says nothing about
  # the step. Like a lost worker it uses no attempt, and the run goes back on its
  # queue. If the database is still away, the stale-lock sweep does this later.
  @spec connection_lost(map(), Exception.t(), Config.t()) :: :waiting | :fenced
  def connection_lost(job, exception, %Config{} = config) do
    {:ok, run} = load_execution(config, job.id)

    if run.lock_token == job[:lock_token] and run.status == :running,
      do: release_after_lost_connection(config, run, exception),
      else: :fenced
  end

  defp release_after_lost_connection(config, run, exception) do
    error = %{type: "worker_lost", message: Exception.message(exception)}
    closed = StepRunner.close_attempts(config, [run.id], :failed, error)
    outcome = requeue(config, run, nil)

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
  # Anything that died outside a step (a branch's `on:`, a parallel `into:`, a
  # process a finished step left linked) has no attempts to run out, and run
  # again would crash the same way. The run goes back marked to fail, so the
  # next claim fails it in the executor, compensations and all. A compensation
  # that died comes back `{:error, error}` for the poller to fail the run.
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

  defp close_and_requeue(config, run, error) do
    closed = StepRunner.close_attempts(config, [run.id], :failed, error)
    delay = delay_after_death(config, run)

    outcome =
      cond do
        run.status != :running -> {:error, error}
        closed != [] -> requeue(config, run, delay)
        true -> requeue(config, run, nil, Map.put(run.context, "__fail__", storable_error(error)))
      end

    # The run itself may be out of attempts, and so has no retry to report.
    backoff = if outcome == :waiting, do: delay
    StepRunner.report_closed(config, closed, :failed, error, fn _row -> backoff end)
    outcome
  end

  # The context stays as it was last saved: the attempt that died changed nothing.
  defp requeue(config, run, delay, context \\ nil) do
    run
    |> Ecto.Changeset.change(
      context: context || run.context,
      status: :pending,
      scheduled_at: requeue_at(run, delay),
      locked_by: nil,
      locked_at: nil,
      lock_token: nil
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
  # `queue:`, or the queue the run started on. A branch only picks a clause, so
  # it runs where it is, and the clause's steps move for themselves.
  defp queue_move(%{type: :branch}, _execution, _config), do: nil

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
    context =
      execution.context
      |> string_keys()
      |> Map.merge(string_keys(data))
      |> Map.delete(@atom_keys)
      |> Map.put(@string_keys, string_key_names(data))

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(
        [context: sanitize_for_json(context), status: :pending, locked_by: nil, locked_at: nil] ++
          attrs
      )
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

    {execution, _event} = enter_wait(config, execution, fn -> insert_event!(config, attrs) end)

    # An event sent before the run got here (`send_event(..., buffer: true)`,
    # a keyed start with `on_duplicate: {:send_event, name}`) resumes it now.
    Durable.Wait.deliver_buffered(config, execution.id, event_name)

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

    {execution, _group} =
      enter_wait(config, execution, fn ->
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
      end)

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

  # Serialize a user-supplied timeout_value for JSONB storage in PendingInput /
  # PendingEvent / WaitGroup rows. Users naturally pass idiomatic Elixir shapes
  # like `{:error, :timeout}` or `%{nested: {:tuple}}`; sanitize_for_json/1
  # normalizes tuples to lists and exotic terms (PIDs, functions, refs) to
  # their inspect/1 form so Postgrex never crashes on encode.
  defp serialize_timeout_value(nil), do: nil

  defp serialize_timeout_value(value) when is_map(value) and not is_struct(value),
    do: sanitize_for_json(value)

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
