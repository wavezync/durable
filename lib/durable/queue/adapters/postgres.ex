defmodule Durable.Queue.Adapters.Postgres do
  @moduledoc """
  PostgreSQL-based queue adapter using the workflow_executions table.

  Uses `FOR UPDATE SKIP LOCKED` for atomic job claiming without blocking.
  This ensures that multiple pollers can safely claim jobs without
  processing the same job twice.
  """

  @behaviour Durable.Queue.Adapter

  alias Durable.Config
  alias Durable.Repo
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, StepExecution, WorkflowExecution}

  import Ecto.Query

  require Logger

  @impl true
  def fetch_jobs(%Config{} = config, queue, limit, node_id)
      when is_binary(queue) and limit > 0 do
    prefix = config.prefix

    # Use raw SQL for FOR UPDATE SKIP LOCKED which Ecto doesn't support directly
    sql = """
    WITH claimable AS (
      SELECT id FROM #{prefix}.workflow_executions
      WHERE status = 'pending'
        AND queue = $1
        AND (scheduled_at IS NULL OR scheduled_at <= NOW())
        AND (locked_by IS NULL OR locked_at < NOW() - INTERVAL '#{config.stale_lock_timeout} seconds')
      ORDER BY priority DESC, scheduled_at ASC NULLS FIRST, inserted_at ASC
      LIMIT $2
      FOR UPDATE SKIP LOCKED
    )
    UPDATE #{prefix}.workflow_executions
    SET locked_by = $3, locked_at = NOW(), status = 'running'
    WHERE id IN (SELECT id FROM claimable)
    RETURNING id, workflow_module, workflow_name, queue, priority, input, context, scheduled_at, current_step;
    """

    case Repo.query(config, sql, [queue, limit, node_id]) do
      {:ok, %{rows: rows, columns: columns}} ->
        rows
        |> Enum.map(&parse_row(&1, columns))
        # Re-sort in Elixir since UPDATE doesn't preserve order
        |> Enum.sort_by(fn job -> {-job.priority, job.scheduled_at} end)

      {:error, _reason} ->
        []
    end
  end

  @impl true
  def ack(%Config{} = config, job_id) when is_binary(job_id) do
    ack_with_retry(config, job_id, _attempt = 1, _max_attempts = 3)
  end

  # Retry the ack on transient failures (DB blip, connection lost). If we
  # gave up here, the workflow would stay locked until stale-recovery
  # released it 5 minutes later — at which point it would silently re-execute
  # because there's no idempotency key (Bug M-5). The retry buys us time;
  # the telemetry surfaces persistent failures so operators can intervene.
  defp ack_with_retry(%Config{} = config, job_id, attempt, max_attempts) do
    case Repo.get(config, WorkflowExecution, job_id) do
      nil ->
        {:error, :not_found}

      execution ->
        case execution
             |> WorkflowExecution.unlock_changeset()
             |> Repo.update(config) do
          {:ok, _} ->
            :ok

          {:error, _reason} when attempt < max_attempts ->
            backoff_ms = :rand.uniform(50) * attempt
            Process.sleep(backoff_ms)
            ack_with_retry(config, job_id, attempt + 1, max_attempts)

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

            {:error, reason}
        end
    end
  end

  @impl true
  def nack(%Config{} = config, job_id, reason) when is_binary(job_id) do
    case Repo.get(config, WorkflowExecution, job_id) do
      nil ->
        {:error, :not_found}

      execution ->
        error = normalize_error(reason)

        execution
        |> Ecto.Changeset.change(
          status: :failed,
          error: error,
          completed_at: DateTime.utc_now(),
          locked_by: nil,
          locked_at: nil
        )
        |> Repo.update(config)

        :ok
    end
  end

  @impl true
  def reschedule(%Config{} = config, job_id, run_at) when is_binary(job_id) do
    case Repo.get(config, WorkflowExecution, job_id) do
      nil ->
        {:error, :not_found}

      execution ->
        execution
        |> Ecto.Changeset.change(
          status: :pending,
          scheduled_at: run_at,
          locked_by: nil,
          locked_at: nil
        )
        |> Repo.update(config)

        :ok
    end
  end

  @impl true
  def recover_stale_locks(%Config{} = config, timeout_seconds) when timeout_seconds > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_seconds, :second)

    query =
      from(w in WorkflowExecution,
        where: w.status == :running,
        where: not is_nil(w.locked_by),
        where: w.locked_at < ^cutoff
      )

    {count, _} =
      Repo.update_all(
        config,
        query,
        set: [
          status: :pending,
          locked_by: nil,
          locked_at: nil
        ]
      )

    {:ok, count}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def recover_zombie_workflows(%Config{} = config, timeout_seconds) when timeout_seconds > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_seconds, :second)

    # Two zombie classes:
    #
    #   1. :waiting workflows with no pending inputs or events to ever unblock them.
    #   2. :compensating workflows with no actively running compensation step
    #      (Bug M-1: the compensation handler crashed mid-rollback).
    #
    # Executions with a healthy lock heartbeat are excluded — those are still
    # being actively processed by some worker.
    waiting_zombies =
      from(w in WorkflowExecution,
        as: :workflow,
        where: w.status == :waiting,
        where: w.updated_at < ^cutoff,
        where: is_nil(w.locked_by) or w.locked_at < ^cutoff,
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
        where:
          not exists(
            from(s in StepExecution,
              where: s.workflow_id == parent_as(:workflow).id and s.status == :running
            )
          ),
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

      {count, _} =
        Repo.update_all(
          config,
          from(w in WorkflowExecution, where: w.id in ^zombie_ids),
          set: [
            status: :failed,
            error: zombie_error,
            locked_by: nil,
            locked_at: nil,
            completed_at: now,
            updated_at: now
          ]
        )

      Logger.warning(
        "[Durable] Zombie recovery marked #{count} workflow(s) as :failed: #{inspect(zombie_ids)}"
      )

      {:ok, count}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def heartbeat(%Config{} = config, job_id) when is_binary(job_id) do
    now = DateTime.utc_now()

    query =
      from(w in WorkflowExecution,
        where: w.id == ^job_id,
        where: w.status == :running
      )

    {count, _} = Repo.update_all(config, query, set: [locked_at: now])

    if count == 1 do
      :ok
    else
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
      current_step: job.current_step
    }
  end

  defp decode_uuid(<<_::128>> = binary) do
    Ecto.UUID.cast!(binary)
  end

  defp decode_uuid(uuid) when is_binary(uuid), do: uuid

  defp decode_json(nil), do: %{}
  defp decode_json(value) when is_map(value), do: value
  defp decode_json(value) when is_binary(value), do: Jason.decode!(value)

  defp normalize_error(reason) when is_map(reason), do: reason

  defp normalize_error(reason) when is_binary(reason) do
    %{type: "error", message: reason}
  end

  defp normalize_error(reason) do
    %{type: "error", message: inspect(reason)}
  end
end
