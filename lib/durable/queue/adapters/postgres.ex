defmodule Durable.Queue.Adapters.Postgres do
  @moduledoc """
  PostgreSQL-based queue adapter using the workflow_executions table.

  Uses `FOR UPDATE SKIP LOCKED` for atomic job claiming without blocking.
  This ensures that multiple pollers can safely claim jobs without
  processing the same job twice.
  """

  @behaviour Durable.Queue.Adapter

  alias Durable.Config
  alias Durable.Storage.Schemas.WorkflowExecution
  alias Ecto.Adapters.SQL

  import Ecto.Query

  @impl true
  def fetch_jobs(%Config{} = config, queue, limit, node_id)
      when is_binary(queue) and limit > 0 do
    repo = config.repo
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

    case SQL.query(repo, sql, [queue, limit, node_id]) do
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
    repo = config.repo

    case repo.get(WorkflowExecution, job_id) do
      nil ->
        {:error, :not_found}

      execution ->
        execution
        |> WorkflowExecution.unlock_changeset()
        |> repo.update()

        :ok
    end
  end

  @impl true
  def nack(%Config{} = config, job_id, reason) when is_binary(job_id) do
    repo = config.repo

    case repo.get(WorkflowExecution, job_id) do
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
        |> repo.update()

        :ok
    end
  end

  @impl true
  def reschedule(%Config{} = config, job_id, run_at) when is_binary(job_id) do
    repo = config.repo

    case repo.get(WorkflowExecution, job_id) do
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
        |> repo.update()

        :ok
    end
  end

  @impl true
  def recover_stale_locks(%Config{} = config, timeout_seconds) when timeout_seconds > 0 do
    repo = config.repo
    cutoff = DateTime.add(DateTime.utc_now(), -timeout_seconds, :second)

    {count, _} =
      from(w in WorkflowExecution,
        where: w.status == :running,
        where: not is_nil(w.locked_by),
        where: w.locked_at < ^cutoff
      )
      |> repo.update_all(
        set: [
          status: :pending,
          locked_by: nil,
          locked_at: nil
        ]
      )

    {:ok, count}
  end

  @impl true
  def heartbeat(%Config{} = config, job_id) when is_binary(job_id) do
    repo = config.repo
    now = DateTime.utc_now()

    {count, _} =
      from(w in WorkflowExecution,
        where: w.id == ^job_id,
        where: w.status == :running
      )
      |> repo.update_all(set: [locked_at: now])

    if count == 1 do
      :ok
    else
      {:error, :not_found}
    end
  end

  @impl true
  def get_stats(%Config{} = config, queue) when is_binary(queue) do
    repo = config.repo
    base_query = from(w in WorkflowExecution, where: w.queue == ^queue)

    pending =
      from(w in base_query, where: w.status == :pending)
      |> repo.aggregate(:count)

    running =
      from(w in base_query, where: w.status == :running)
      |> repo.aggregate(:count)

    completed =
      from(w in base_query, where: w.status == :completed)
      |> repo.aggregate(:count)

    failed =
      from(w in base_query, where: w.status == :failed)
      |> repo.aggregate(:count)

    waiting =
      from(w in base_query, where: w.status == :waiting)
      |> repo.aggregate(:count)

    scheduled =
      from(w in base_query,
        where: w.status == :pending,
        where: not is_nil(w.scheduled_at),
        where: w.scheduled_at > ^DateTime.utc_now()
      )
      |> repo.aggregate(:count)

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
