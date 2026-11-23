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

  # These columns hold UTC in a type with no zone, so the database's own clock
  # has to be read as UTC too, whatever its TimeZone setting.
  @utc_now "(NOW() AT TIME ZONE 'UTC')"
  @utc_clock "(clock_timestamp() AT TIME ZONE 'UTC')"

  # What a run put back on its queue is set to, and what is read of it.
  @release [status: :pending, locked_by: nil, locked_at: nil, lock_token: nil]
  @released [:id, :queue, :current_step, :retried_at, :inserted_at, :parent_workflow_id]

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
        AND (w.scheduled_at IS NULL OR w.scheduled_at <= #{@utc_now})
        AND (w.locked_by IS NULL OR w.locked_at < #{@utc_now} - INTERVAL '#{config.stale_lock_timeout} seconds')
        AND NOT EXISTS (
          SELECT 1 FROM #{prefix}.queues q WHERE q.name = $1 AND q.paused_at IS NOT NULL
        )
        -- A run_again run waits until the run it's behind has ended, and a
        -- step it was cancelled in has stopped (`Keys.settles_at/2`). A run
        -- never waits behind itself.
        AND NOT EXISTS (
          SELECT 1 FROM #{prefix}.workflow_executions h
          WHERE h.id = w.runs_after_id AND h.id <> w.id
            AND (h.status IN ('pending', 'running', 'waiting', 'compensating')
              OR (h.status = 'cancelled'
                AND h.completed_at > #{@utc_now} - INTERVAL '#{config.heartbeat_interval} milliseconds'
                AND EXISTS (
                  SELECT 1 FROM #{prefix}.step_executions s
                  WHERE s.workflow_id = h.id AND (s.status = 'running'
                    OR (s.status = 'cancelled' AND s.completed_at >= h.completed_at))
                )))
        )
      ORDER BY w.priority DESC, COALESCE(w.scheduled_at, w.inserted_at) ASC, w.inserted_at ASC
      LIMIT $2
      FOR UPDATE SKIP LOCKED
    )
    UPDATE #{prefix}.workflow_executions
    SET locked_by = $3, locked_at = #{@utc_now}, status = 'running', lock_token = gen_random_uuid()
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

  # A finished run's lock is cleared in one conditional UPDATE, on the claim's
  # token and on the run having ended: a claim taken since the worker finished
  # isn't stomped, and a run still `running` keeps its lock, so the stale
  # sweep can find it. The executor clears the lock as it ends a run; this is
  # for a row it left one on.
  #
  # Retried when the database is away for a moment, and reported if it stays
  # away: the lock then waits for the stale sweep.
  defp ack_with_retry(%Config{} = config, job_id, attempt, max_attempts, lock_token) do
    ended =
      from(w in still_claimed(job_id, lock_token),
        where: w.status not in [:running, :compensating]
      )

    case Repo.update_all(config, ended, set: [locked_by: nil, locked_at: nil]) do
      {1, _} ->
        :ok

      {0, _} ->
        if Repo.get(config, WorkflowExecution, job_id), do: :ok, else: {:error, :not_found}
    end
  rescue
    error ->
      if attempt < max_attempts do
        Process.sleep(:rand.uniform(50) * attempt)
        ack_with_retry(config, job_id, attempt + 1, max_attempts, lock_token)
      else
        ack_failed(config, job_id, attempt, Exception.message(error))
      end
  end

  defp ack_failed(config, job_id, attempts, reason) do
    :telemetry.execute(
      [:durable, :queue, :ack_failed],
      %{count: 1, attempts: attempts},
      %{job_id: job_id, reason: reason, durable: config.name}
    )

    Logger.error("[Durable] ack failed after #{attempts} attempts for job #{job_id}: #{reason}")

    Durable.Activity.record(config, "ack_failed",
      workflow_id: job_id,
      details: %{attempts: attempts, reason: reason}
    )

    {:error, reason}
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
          fail_unrecorded(config, execution, Executor.storable_error(reason), lock_token)
        end
    end
  end

  # A conditional UPDATE: a cancel or a takeover that lands after the row was
  # read wins, and this writes nothing. The run, its open attempt and the
  # activity are written in one transaction: nothing sweeps a failed run, so an
  # attempt left `running` on one would stay so.
  defp fail_unrecorded(config, execution, error, lock_token) do
    now = DateTime.utc_now()

    {:ok, failed} =
      Repo.transaction(config, fn ->
        {_count, failed} =
          fail_runs(
            config,
            from(w in still_claimed(execution.id, lock_token),
              where: w.status in [:running, :compensating]
            ),
            error,
            completed_at: now,
            updated_at: now,
            # On a failed run this is when to roll it back (the timeout sweep),
            # and what a retry's backoff or a delayed start left there isn't.
            scheduled_at: nil,
            locked_by: nil,
            locked_at: nil,
            lock_token: nil
          )

        # What raised has reported this attempt's end already, as an :exception.
        StepRunner.close_attempts(config, Enum.map(failed, & &1.id), :failed, error)

        if execution.status == :compensating,
          do: Enum.each(failed, &rollback_interrupted(config, &1, error))

        failed
      end)

    # The executor never got to tell a parent waiting on this run.
    for run <- failed, do: Executor.maybe_notify_parent(config, run, :failed, run.error)

    :ok
  end

  # Fails the runs of `query` in the executor's place, with `error`. A run that
  # was being rolled back keeps the error it has: that is why it is being
  # undone, and `Durable.rollback/2` ends the run with it once it has finished
  # the job. What cut the rollback short goes on the undo's own row, which the
  # caller closes with `error`, and in the activity (`rollback_interrupted/3`).
  defp fail_runs(config, query, error, set) do
    query
    |> select([w], w)
    |> update([w], set: ^[{:status, :failed} | set])
    |> update([w],
      set: [
        error:
          fragment(
            "CASE WHEN ? = 'compensating' THEN COALESCE(?, ?) ELSE ? END",
            w.status,
            w.error,
            type(^error, w.error),
            type(^error, w.error)
          )
      ]
    )
    |> then(&Repo.update_all(config, &1, []))
  end

  defp rollback_interrupted(config, run, error) do
    Durable.Activity.record(config, "rollback_interrupted",
      workflow_id: run.id,
      queue: run.queue,
      details: %{
        reason: error["type"] || error[:type],
        message: error["message"] || error[:message]
      }
    )
  end

  defp still_claimed(id, nil), do: from(w in WorkflowExecution, where: w.id == ^id)

  defp still_claimed(id, lock_token),
    do: from(w in WorkflowExecution, where: w.id == ^id and w.lock_token == ^lock_token)

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
          # Conditional, so a run that ended or changed hands since it was
          # read isn't reopened.
          Repo.update_all(
            config,
            from(w in still_claimed(execution.id, lock_token),
              where: w.status in [:pending, :running, :waiting, :compensating]
            ),
            set: [
              status: :pending,
              scheduled_at: run_at,
              locked_by: nil,
              locked_at: nil,
              lock_token: nil,
              updated_at: DateTime.utc_now()
            ]
          )

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
        select: struct(w, ^@released)
      )

    # The step may be fine: an outage or a frozen VM takes every lock at once.
    # So this uses no attempt, but the row is closed and counted on its own
    # (StepRunner), or a step that takes its node down would run forever.
    error = %{
      type: "worker_lost",
      message: "the worker running this attempt stopped responding"
    }

    with {:ok, runs} <-
           release_runs(config, query, :failed, error,
             retry: &StepRunner.retry_after_lost(config, &1),
             count_losses: true
           ) do
      let_go_of_lost(config, cutoff)
      {:ok, length(runs)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # A run lost between two steps (its node died saving a step's result, say)
  # has no attempt to count. Each loss counts at the step it's at, as a worker
  # that outlives its task counts one (`Executor.lost_too_often?/2`), and the
  # third in a row fails the run, so one that takes its node down every time
  # can't go round for ever. In the transaction that puts it back, before a
  # poller can claim it.
  defp fail_looping(config, runs, closed) do
    in_a_step = MapSet.new(closed, & &1.workflow_id)

    case for(r <- runs, r.id not in in_a_step, Executor.lost_too_often?(config, r), do: r.id) do
      [] ->
        []

      ids ->
        now = DateTime.utc_now()

        error = %{
          type: "worker_lost",
          message: "the run lost its worker three times in a row at the same step"
        }

        query = from(w in WorkflowExecution, where: w.id in ^ids)

        {_count, failed} =
          fail_runs(config, query, error, completed_at: now, updated_at: now, scheduled_at: nil)

        failed
    end
  end

  @doc false
  # A worker that stopped (or a caller running it inline) lets go of a run that
  # was cancelled to be undone while it ran (`Executor.cancel_run/3` leaves the
  # lock, with no token, until then), so its undo can be claimed now.
  @impl true
  def let_go(%Config{} = config, job_id) do
    {_count, runs} =
      Repo.update_all(
        config,
        from(w in WorkflowExecution,
          where: w.id == ^job_id and w.status == :pending,
          where: is_nil(w.lock_token) and not is_nil(w.locked_by),
          select: w
        ),
        set: [locked_by: nil, locked_at: nil]
      )

    for run <- runs, do: Durable.PubSub.wake(config, run)
    :ok
  rescue
    _error -> :ok
  end

  # An undo a worker kept from being claimed (`Executor.cancel_run/3`), when
  # that worker is lost: let go of with the rest of what it held.
  defp let_go_of_lost(config, cutoff) do
    {_count, runs} =
      Repo.update_all(
        config,
        from(w in WorkflowExecution,
          where: w.status == :pending and is_nil(w.lock_token) and not is_nil(w.locked_by),
          where: w.locked_at < ^cutoff,
          select: w
        ),
        set: [locked_by: nil, locked_at: nil]
      )

    for run <- runs, do: Durable.PubSub.wake(config, run)
  end

  @impl true
  def release_node_jobs(%Config{} = config, node_id) when is_binary(node_id) do
    running =
      from(w in WorkflowExecution,
        where: w.status == :running and w.locked_by == ^node_id,
        select: struct(w, ^@released)
      )

    # A run being rolled back goes back to be rolled back, not to run: with
    # the marker `Durable.rollback/2` leaves (Executor.roll_back/3), so the
    # node that claims it undoes what is left and never runs a step.
    compensating =
      from(w in WorkflowExecution,
        where: w.status == :compensating and w.locked_by == ^node_id,
        select: struct(w, ^@released),
        update: [
          set: [
            engine_state:
              fragment(
                "jsonb_set(?, '{__rollback__}', jsonb_build_object('error', coalesce(?, '{}'), 'status', 'failed'))",
                w.engine_state,
                w.error
              )
          ]
        ]
      )

    # A deploy isn't the step's fault: :snoozed doesn't use an attempt.
    stopped = %{type: "node_stopped", message: "the node stopped before this attempt finished"}

    # Undos its workers kept from being claimed while their steps ran.
    to_undo =
      from(w in WorkflowExecution,
        where: w.status == :pending and is_nil(w.lock_token) and w.locked_by == ^node_id
      )

    with {:ok, runs} <- release_runs(config, running, :snoozed, stopped),
         {:ok, rollbacks} <- release_runs(config, compensating, :snoozed, stopped) do
      Repo.update_all(config, to_undo, set: [locked_by: nil, locked_at: nil])
      {:ok, length(runs) + length(rollbacks)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Back to :pending with the lock cleared, and the attempts those runs had
  # in flight closed with them. Clearing the fencing token means the next claim
  # stamps a fresh one, and the old worker's can never match again. The runs
  # it handled. `count_losses:` fails the runs that are lost too often.
  defp release_runs(config, query, step_status, error, opts \\ []) do
    result =
      Repo.transaction(config, fn ->
        {_count, runs} =
          Repo.update_all(config, where(query, [w], is_nil(w.runs_after_id)), set: @release)

        closed = StepRunner.close_attempts(config, Enum.map(runs, & &1.id), step_status, error)
        failed = if opts[:count_losses], do: fail_looping(config, runs, closed), else: []
        {runs, closed, failed}
      end)

    with {:ok, {runs, closed, failed}} <- result do
      StepRunner.report_closed(
        config,
        closed,
        step_status,
        error,
        opts[:retry] || fn _ -> nil end
      )

      for run <- failed, do: Executor.maybe_notify_parent(config, run, :failed, run.error)
      {:ok, runs ++ release_waiters(config, query)}
    end
  end

  # A run_again run claimed before it took its key (it has no attempt yet)
  # goes back to wait for it. One run waits per key: if a newer start waits
  # there already, that one has the newer input and this one is cancelled, as
  # `Executor.wait_behind/3` does. One by one, so a run that can't go back
  # holds up none of the others.
  defp release_waiters(config, query) do
    waiting = query |> exclude(:update) |> where([w], not is_nil(w.runs_after_id))

    for run <- Repo.all(config, waiting),
        released_waiter?(config, where(query, [w], w.id == ^run.id), run.id),
        do: run
  end

  defp released_waiter?(config, query, id) do
    {count, _} = Repo.update_all(config, query, set: @release)
    count == 1
  rescue
    error in Postgrex.Error ->
      if error.postgres.code != :unique_violation, do: reraise(error, __STACKTRACE__)

      _ =
        Executor.cancel_workflow(id, "a newer start is waiting for the key", durable: config.name)

      false
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

    rollbacks = Repo.all(config, compensating_zombies)
    zombie_ids = Repo.all(config, waiting_zombies) ++ rollbacks

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

      # Still as they were found: one that was resumed or finished meanwhile
      # isn't a zombie any more.
      {count, zombies} =
        fail_runs(
          config,
          from(w in WorkflowExecution,
            where: w.id in ^zombie_ids and w.status in [:waiting, :compensating],
            where: w.updated_at < ^cutoff
          ),
          zombie_error,
          # As in fail_unrecorded/4: not a time to roll back at.
          scheduled_at: nil,
          locked_by: nil,
          locked_at: nil,
          completed_at: now,
          updated_at: now
        )

      zombie_ids = Enum.map(zombies, & &1.id)
      StepRunner.close_running(config, zombie_ids, :failed, zombie_error)
      for run <- zombies, run.id in rollbacks, do: rollback_interrupted(config, run, zombie_error)
      Enum.each(zombies, &Executor.maybe_notify_parent(config, &1, :failed, &1.error))

      if count > 0 do
        Logger.warning(
          "[Durable] Zombie recovery marked #{count} workflow(s) as :failed: #{inspect(zombie_ids)}"
        )
      end

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
    #   3. Merge `__sleep_satisfied__: <current_step>` into engine_state so the
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
        AND scheduled_at <= #{@utc_clock}
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
        engine_state = jsonb_set(
          w.engine_state,
          '{__sleep_satisfied__}',
          to_jsonb(w.current_step),
          true
        ),
        updated_at = #{@utc_clock}
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
  # a refresh that touches 0 rows is classified: `:fenced` means the row has
  # another token now (another worker's, or none since it was released) and the
  # caller should abort to avoid a double-execution; `:cancelled` means the
  # caller should stop the step; `:not_found` is a benign miss (the caller's own
  # executor just completed, parked or suspended the run, or it's gone).
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

  # A token that isn't ours any more, whatever the status, is a claim that is
  # gone: taken over, or put back for another claim by a stale sweep. Seen as
  # :not_found, the step would run on, holding its slot. With our token the
  # run is ours to settle: we just finished it, parked it or made it wait.
  defp classify_lost_lock(config, job_id, lock_token) do
    case Repo.get(config, WorkflowExecution, job_id) do
      %WorkflowExecution{status: :cancelled} ->
        {:error, :cancelled}

      # Cancelled with `rollback: true`: back on its queue at once, to be
      # undone once this worker has stopped (`Executor.cancel_run/3`). Stopped
      # as a cancel, the worker closes the step it had.
      %WorkflowExecution{status: :pending, engine_state: %{"__rollback__" => _}} ->
        {:error, :cancelled}

      %WorkflowExecution{lock_token: current} when current != lock_token ->
        {:error, :fenced}

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

  # Postgrex has decoded the jsonb already. A bare value is one 2.0 wrote where
  # a map goes, read as the schema reads it (`JsonMap.load/1`): raising here,
  # after the claim had committed, left every run it took with it locked and
  # without a worker until `stale_lock_timeout`, and then took them again.
  defp decode_json(nil), do: %{}
  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value), do: %{"value" => value}
end
