defmodule Durable.Queue.Adapters.Postgres do
  @moduledoc """
  PostgreSQL-based queue adapter using the workflow_executions table.

  Uses `FOR UPDATE SKIP LOCKED` for atomic job claiming without blocking.
  This ensures that multiple pollers can safely claim jobs without
  processing the same job twice.
  """

  @behaviour Durable.Queue.Adapter

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Executor.StepRunner
  alias Durable.Repo
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WorkflowExecution}

  import Ecto.Query

  require Logger

  @impl true
  def fetch_jobs(%Config{} = config, queue, limit, node_id)
      when is_binary(queue) and limit > 0 do
    case Repo.query(config, claim_sql(config), [queue, limit, node_id]) do
      {:ok, %{rows: rows, columns: columns}} ->
        rows
        |> Enum.map(&parse_row(&1, columns))
        # Re-sort in Elixir since UPDATE doesn't preserve order. Sorting is
        # stable, so this is by priority and then by when each became ready.
        |> Enum.sort_by(& &1.ready_at, NaiveDateTime)
        |> Enum.sort_by(&(-&1.priority))

      # A queue that can't claim looks just like an idle one, so say so.
      {:error, reason} ->
        Logger.error("[Durable] couldn't claim jobs from queue #{queue}: #{inspect(reason)}")

        :telemetry.execute(
          [:durable, :queue, :claim_failed],
          %{count: 1},
          %{durable: config.name, queue: queue, reason: reason}
        )

        []
    end
  end

  # Its ORDER BY is the order of `workflow_executions_claim_index`, so a claim
  # reads only the rows it takes, however deep the backlog is. Change them
  # together.
  @doc false
  def claim_sql(%Config{} = config) do
    prefix = config.prefix

    # Use raw SQL for FOR UPDATE SKIP LOCKED which Ecto doesn't support directly
    """
    WITH claimable AS (
      SELECT w.id FROM #{prefix}.workflow_executions w
      WHERE w.status = 'pending'
        AND w.queue = $1
        AND (w.scheduled_at IS NULL OR w.scheduled_at <= NOW())
        AND (w.locked_by IS NULL OR w.locked_at < NOW() - INTERVAL '#{config.stale_lock_timeout} seconds')
        AND NOT EXISTS (
          SELECT 1 FROM #{prefix}.queues q WHERE q.name = $1 AND q.paused_at IS NOT NULL
        )
        -- A run_again run waits until the run it's behind has ended.
        AND NOT EXISTS (
          SELECT 1 FROM #{prefix}.workflow_executions h
          WHERE h.id = w.runs_after_id
            AND h.status IN ('pending', 'running', 'waiting', 'compensating')
        )
      ORDER BY w.priority DESC, COALESCE(w.scheduled_at, w.inserted_at) ASC, w.inserted_at ASC
      LIMIT $2
      FOR UPDATE SKIP LOCKED
    )
    UPDATE #{prefix}.workflow_executions
    SET locked_by = $3, locked_at = NOW(), status = 'running', lock_token = gen_random_uuid()
    WHERE id IN (SELECT id FROM claimable)
    RETURNING id, workflow_module, workflow_name, queue, priority, input, context, scheduled_at, COALESCE(scheduled_at, inserted_at) AS ready_at, current_step, lock_token;
    """
  end

  @impl true
  def ack(%Config{} = config, job_id) when is_binary(job_id) do
    ack_with_retry(config, job_id, _attempt = 1, _max_attempts = 3, nil)
  end

  # Fencing-aware ack. When the caller supplies the `lock_token` it claimed
  # with, an ack from a worker whose claim was already superseded (stale
  # recovery + reclaim by another worker) is a no-op instead of stomping the
  # new owner's lock.
  def ack(%Config{} = config, job_id, lock_token) when is_binary(job_id) do
    ack_with_retry(config, job_id, 1, 3, lock_token)
  end

  # Retry the ack on transient failures (DB blip, connection lost). If we
  # gave up here, the workflow would stay locked until stale-recovery
  # released it 5 minutes later — at which point it would silently re-execute
  # because there's no idempotency key (Bug M-5). The retry buys us time;
  # the telemetry surfaces persistent failures so operators can intervene.
  defp ack_with_retry(%Config{} = config, job_id, attempt, max_attempts, lock_token) do
    case Repo.get(config, WorkflowExecution, job_id) do
      nil ->
        {:error, :not_found}

      execution ->
        ack_loaded(config, execution, job_id, attempt, max_attempts, lock_token)
    end
  end

  defp ack_loaded(config, execution, job_id, attempt, max_attempts, lock_token) do
    if fenced?(execution, lock_token) do
      # Another worker owns this row now (stale recovery + reclaim); our ack
      # would stomp their claim — no-op.
      :ok
    else
      case execution
           |> WorkflowExecution.unlock_changeset()
           |> Repo.update(config) do
        {:ok, _} ->
          :ok

        {:error, _reason} when attempt < max_attempts ->
          backoff_ms = :rand.uniform(50) * attempt
          Process.sleep(backoff_ms)
          ack_with_retry(config, job_id, attempt + 1, max_attempts, lock_token)

        {:error, reason} ->
          :telemetry.execute(
            [:durable, :queue, :ack_failed],
            %{count: 1, attempts: attempt},
            %{job_id: job_id, reason: reason, durable: config.name}
          )

          Logger.error(
            "[Durable] ack failed after #{attempt} attempts for job #{job_id}: " <>
              inspect(reason)
          )

          Durable.Activity.record(config, "ack_failed",
            workflow_id: job_id,
            details: %{attempts: attempt, reason: inspect(reason)}
          )

          {:error, reason}
      end
    end
  end

  @impl true
  def nack(%Config{} = config, job_id, reason) when is_binary(job_id) do
    do_nack(config, job_id, reason, nil)
  end

  def nack(%Config{} = config, job_id, reason, lock_token) when is_binary(job_id) do
    do_nack(config, job_id, reason, lock_token)
  end

  defp do_nack(config, job_id, reason, lock_token) do
    case Repo.get(config, WorkflowExecution, job_id) do
      nil ->
        {:error, :not_found}

      execution ->
        # Only a run still :running or :compensating needs failing here — the
        # worker crashed before the executor could record an outcome. Anything
        # else was settled by the executor (failed, compensated, cancelled,
        # waiting) and must not be overwritten.
        if fenced?(execution, lock_token) or execution.status not in [:running, :compensating] do
          :ok
        else
          fail_unrecorded(config, execution, Executor.storable_error(reason))
        end
    end
  end

  defp fail_unrecorded(config, execution, error) do
    with {:ok, failed} <-
           execution
           |> Ecto.Changeset.change(
             status: :failed,
             error: error,
             completed_at: DateTime.utc_now(),
             locked_by: nil,
             locked_at: nil,
             lock_token: nil
           )
           |> Repo.update(config) do
      # The executor never got to tell a parent waiting on this run.
      Executor.maybe_notify_parent(config, failed, :failed, error)
    end

    :ok
  end

  @impl true
  def reschedule(%Config{} = config, job_id, run_at) when is_binary(job_id) do
    do_reschedule(config, job_id, run_at, nil)
  end

  def reschedule(%Config{} = config, job_id, run_at, lock_token) when is_binary(job_id) do
    do_reschedule(config, job_id, run_at, lock_token)
  end

  defp do_reschedule(config, job_id, run_at, lock_token) do
    case Repo.get(config, WorkflowExecution, job_id) do
      nil ->
        {:error, :not_found}

      # Only a run that's still going can be put back on the queue. A finished
      # run may have lost its workflow key to a newer run, and reopening it
      # here would run it alongside that run, without the key.
      %{status: status} when status not in [:pending, :running, :waiting, :compensating] ->
        {:error, :finished}

      execution ->
        if fenced?(execution, lock_token) do
          :ok
        else
          execution
          |> Ecto.Changeset.change(
            status: :pending,
            scheduled_at: run_at,
            locked_by: nil,
            locked_at: nil,
            lock_token: nil
          )
          |> Repo.update(config)

          :ok
        end
    end
  end

  # A fenced row is one whose current lock_token differs from the token the
  # caller claimed with. `nil` token = legacy/un-fenced caller → never fenced.
  defp fenced?(_execution, nil), do: false
  defp fenced?(%WorkflowExecution{lock_token: current}, token), do: current != token

  @impl true
  def recover_stale_locks(%Config{} = config, timeout_seconds) when timeout_seconds > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_seconds, :second)

    query =
      from(w in WorkflowExecution,
        where: w.status == :running,
        where: not is_nil(w.locked_by),
        where: w.locked_at < ^cutoff,
        select: w.id
      )

    # The attempt in flight died with its worker, so it counts against the
    # step's retries. Left :running, a step that takes its node down would
    # run again after every recovery, forever.
    release_runs(config, query, :failed, %{
      type: "worker_lost",
      message: "the worker running this attempt stopped responding"
    })
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def release_node_jobs(%Config{} = config, node_id) when is_binary(node_id) do
    query =
      from(w in WorkflowExecution,
        where: w.status == :running and w.locked_by == ^node_id,
        select: w.id
      )

    # A deploy isn't the step's fault: :snoozed doesn't use an attempt.
    release_runs(config, query, :snoozed, %{
      type: "node_stopped",
      message: "the node stopped before this attempt finished"
    })
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Back to :pending with the lock cleared, and the attempts those runs had
  # in flight closed with them. Clearing the fencing token means the next claim
  # stamps a fresh one, and the old worker's can never match again.
  defp release_runs(config, query, step_status, error) do
    Repo.transaction(config, fn ->
      {count, ids} =
        Repo.update_all(config, query,
          set: [status: :pending, locked_by: nil, locked_at: nil, lock_token: nil]
        )

      StepRunner.close_running(config, ids, step_status, error)
      count
    end)
  end

  @impl true
  def recover_zombie_workflows(%Config{} = config, timeout_seconds) when timeout_seconds > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_seconds, :second)

    # Two zombie classes:
    #
    #   1. :waiting workflows with no pending inputs or events to ever unblock them.
    #   2. :compensating workflows whose lock went stale (Bug M-1: the
    #      compensation crashed mid-rollback). A live compensation's worker
    #      heartbeats, so its lock stays fresh; a step row left :running says
    #      nothing, because a killed compensation leaves exactly that.
    #
    # Executions with a healthy lock heartbeat are excluded — those are still
    # being actively processed by some worker.
    waiting_zombies =
      from(w in WorkflowExecution,
        as: :workflow,
        where: w.status == :waiting,
        where: w.updated_at < ^cutoff,
        where: is_nil(w.locked_by) or w.locked_at < ^cutoff,
        # Sleeping workflows (`sleep/1` / `schedule_at/1`) carry a non-nil
        # scheduled_at and are revived by the SleepWaker, not the zombie
        # sweeper. Excluding them here prevents a multi-minute sleep from
        # being misclassified as a crash and marked :failed.
        where: is_nil(w.scheduled_at),
        where:
          not exists(
            from(p in PendingInput,
              where: p.workflow_id == parent_as(:workflow).id and p.status == :pending
            )
          ),
        where:
          not exists(
            from(e in PendingEvent,
              where: e.workflow_id == parent_as(:workflow).id and e.status == :pending
            )
          ),
        select: w.id
      )

    compensating_zombies =
      from(w in WorkflowExecution,
        as: :workflow,
        where: w.status == :compensating,
        where: w.updated_at < ^cutoff,
        where: is_nil(w.locked_by) or w.locked_at < ^cutoff,
        select: w.id
      )

    zombie_ids = Repo.all(config, waiting_zombies) ++ Repo.all(config, compensating_zombies)

    if zombie_ids == [] do
      {:ok, 0}
    else
      now = DateTime.utc_now()

      zombie_error = %{
        "type" => "zombie_detected",
        "message" =>
          "Workflow was in :waiting or :compensating status with no active work for longer than the stale lock timeout. Likely crashed during a state transition.",
        "detected_at" => DateTime.to_iso8601(now)
      }

      {count, zombies} =
        Repo.update_all(
          config,
          from(w in WorkflowExecution, where: w.id in ^zombie_ids, select: w),
          set: [
            status: :failed,
            error: zombie_error,
            locked_by: nil,
            locked_at: nil,
            completed_at: now,
            updated_at: now
          ]
        )

      StepRunner.close_running(config, zombie_ids, :failed, zombie_error)
      Enum.each(zombies, &Executor.maybe_notify_parent(config, &1, :failed, zombie_error))

      Logger.warning(
        "[Durable] Zombie recovery marked #{count} workflow(s) as :failed: #{inspect(zombie_ids)}"
      )

      {:ok, count}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def wake_sleeping_workflows(%Config{} = config, batch_size)
      when is_integer(batch_size) and batch_size > 0 do
    prefix = config.prefix

    # Atomically wake any rows whose sleep has elapsed:
    #
    #   1. Flip status :waiting -> :pending so the queue poller can claim them.
    #   2. Clear the lock (set NULL) so a stale `locked_by` from the
    #      worker that originally suspended them doesn't keep them invisible
    #      to fetch_jobs after the wake.
    #   3. Merge `__sleep_satisfied__: <current_step>` into context so the
    #      step body's next sleep/schedule_at call returns immediately
    #      instead of re-throwing.
    #
    # FOR UPDATE SKIP LOCKED keeps multiple SleepWakers (across nodes)
    # from contending on the same rows; if a competitor is mid-update,
    # we just skip and pick the row up next tick.
    # `clock_timestamp()` rather than `NOW()` so the comparison reflects
    # the *real* wall clock, not the transaction-start snapshot. This
    # matters for two cases: (1) the SQL Sandbox-based test suite, where
    # one transaction wraps the whole test and NOW() would be from
    # before the row's scheduled_at was set; and (2) any future caller
    # that wraps the sweep in a longer-running transaction. In normal
    # production calls the two are essentially identical.
    # `current_step IS NOT NULL` is a safety guard: the marker we stamp is
    # `__sleep_satisfied__ => current_step`, and `Wait.sleep_satisfied?/0`
    # only matches when that value equals the running step's name. A row with
    # a NULL current_step would get an empty-string marker that never matches,
    # so the woken step would re-throw its sleep and re-suspend every tick — a
    # busy churn. A legitimately sleeping row always has current_step set
    # (the executor stamps it before each step), so excluding NULL ones costs
    # nothing and removes the churn failure mode.
    #
    # `scheduled_at = NULL` on wake keeps the invariant that scheduled_at is
    # non-null ONLY while a row is genuinely sleeping — so a later
    # event/input/wait-group suspend (which sets :waiting) can never be
    # mistaken for an elapsed sleep and prematurely woken.
    sql = """
    WITH wakeable AS (
      SELECT id FROM #{prefix}.workflow_executions
      WHERE status = 'waiting'
        AND scheduled_at IS NOT NULL
        AND scheduled_at <= clock_timestamp()
        AND current_step IS NOT NULL
      ORDER BY scheduled_at ASC
      LIMIT $1
      FOR UPDATE SKIP LOCKED
    )
    UPDATE #{prefix}.workflow_executions w
    SET status = 'pending',
        scheduled_at = NULL,
        locked_by = NULL,
        locked_at = NULL,
        context = jsonb_set(
          COALESCE(w.context, '{}'::jsonb),
          '{__sleep_satisfied__}',
          to_jsonb(w.current_step),
          true
        ),
        updated_at = clock_timestamp()
    WHERE w.id IN (SELECT id FROM wakeable);
    """

    case Repo.query(config, sql, [batch_size]) do
      {:ok, %{num_rows: count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def heartbeat(%Config{} = config, job_id) when is_binary(job_id) do
    do_heartbeat(config, job_id, nil)
  end

  # Fencing-aware heartbeat. When the worker passes the token it claimed with,
  # a refresh that touches 0 rows is classified: `:fenced` means another worker
  # now owns this row (running with a different token) and the caller should
  # abort to avoid a double-execution; `:cancelled` means the caller should stop
  # the step; `:not_found` is a benign miss (the row completed/suspended, or was
  # released but not yet reclaimed).
  def heartbeat(%Config{} = config, job_id, lock_token) when is_binary(job_id) do
    do_heartbeat(config, job_id, lock_token)
  end

  defp do_heartbeat(config, job_id, lock_token) do
    now = DateTime.utc_now()

    base =
      from(w in WorkflowExecution,
        where: w.id == ^job_id,
        where: w.status in [:running, :compensating]
      )

    guarded =
      if lock_token, do: from(w in base, where: w.lock_token == ^lock_token), else: base

    {count, _} = Repo.update_all(config, guarded, set: [locked_at: now])

    cond do
      count == 1 -> :ok
      is_nil(lock_token) -> {:error, :not_found}
      true -> classify_lost_lock(config, job_id, lock_token)
    end
  rescue
    # A pool refusing requests for a few seconds mustn't cost the step in
    # flight. The next tick tries again; the stale timeout covers a real outage.
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp classify_lost_lock(config, job_id, lock_token) do
    case Repo.get(config, WorkflowExecution, job_id) do
      %WorkflowExecution{status: status, lock_token: current}
      when status in [:running, :compensating] and current != lock_token ->
        {:error, :fenced}

      %WorkflowExecution{status: :cancelled} ->
        {:error, :cancelled}

      _ ->
        {:error, :not_found}
    end
  end

  @impl true
  def get_stats(%Config{} = config, queue) when is_binary(queue) do
    base_query = from(w in WorkflowExecution, where: w.queue == ^queue)

    pending_query = from(w in base_query, where: w.status == :pending)
    pending = Repo.aggregate(config, pending_query, :count)

    running_query = from(w in base_query, where: w.status == :running)
    running = Repo.aggregate(config, running_query, :count)

    completed_query = from(w in base_query, where: w.status == :completed)
    completed = Repo.aggregate(config, completed_query, :count)

    failed_query = from(w in base_query, where: w.status == :failed)
    failed = Repo.aggregate(config, failed_query, :count)

    waiting_query = from(w in base_query, where: w.status == :waiting)
    waiting = Repo.aggregate(config, waiting_query, :count)

    scheduled_query =
      from(w in base_query,
        where: w.status == :pending,
        where: not is_nil(w.scheduled_at),
        where: w.scheduled_at > ^DateTime.utc_now()
      )

    scheduled = Repo.aggregate(config, scheduled_query, :count)

    %{
      queue: queue,
      pending: pending,
      running: running,
      completed: completed,
      failed: failed,
      waiting: waiting,
      scheduled: scheduled,
      total: pending + running + completed + failed + waiting
    }
  end

  # Private functions

  defp parse_row(row, columns) do
    columns
    |> Enum.zip(row)
    |> Map.new(fn {col, val} -> {String.to_atom(col), val} end)
    |> decode_job()
  end

  defp decode_job(job) do
    %{
      id: decode_uuid(job.id),
      workflow_module: job.workflow_module,
      workflow_name: job.workflow_name,
      queue: job.queue,
      priority: job.priority,
      input: decode_json(job.input),
      context: decode_json(job.context),
      scheduled_at: job.scheduled_at,
      ready_at: job.ready_at,
      current_step: job.current_step,
      lock_token: decode_uuid(job.lock_token)
    }
  end

  defp decode_uuid(<<_::128>> = binary) do
    Ecto.UUID.cast!(binary)
  end

  defp decode_uuid(uuid) when is_binary(uuid), do: uuid

  defp decode_json(nil), do: %{}
  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)
end
