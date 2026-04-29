defmodule DurableDashboard.Metrics do
  @moduledoc """
  Dashboard-specific aggregation queries for the overview metrics page.

  These are presentation-layer computations — time-windowed throughput,
  success rates, duration percentiles — that don't belong in the Durable
  runtime API (`Durable.Query`). They only read from the existing
  `WorkflowExecution` and `StepExecution` schemas.
  """

  alias Durable.Config
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query

  @doc """
  Workflow throughput bucketed by 5-minute intervals.

  Returns a list of `%{time: iso8601, count: integer}` maps ordered by time,
  covering the last `window_minutes`.
  """
  def throughput(durable, window_minutes \\ 60) do
    config = Config.get(durable)
    since = DateTime.add(DateTime.utc_now(), -window_minutes, :minute)

    query =
      from(w in WorkflowExecution,
        where: w.inserted_at >= ^since,
        select: {
          fragment(
            "date_trunc('minute', ? - (EXTRACT(MINUTE FROM ?) :: integer % 5) * interval '1 minute')",
            w.inserted_at,
            w.inserted_at
          ),
          count(w.id)
        },
        group_by:
          fragment(
            "date_trunc('minute', ? - (EXTRACT(MINUTE FROM ?) :: integer % 5) * interval '1 minute')",
            w.inserted_at,
            w.inserted_at
          ),
        order_by:
          fragment(
            "date_trunc('minute', ? - (EXTRACT(MINUTE FROM ?) :: integer % 5) * interval '1 minute')",
            w.inserted_at,
            w.inserted_at
          )
      )

    Durable.Repo.all(config, query)
    |> Enum.map(fn {time, count} ->
      %{time: format_datetime(time), count: count}
    end)
  end

  @doc """
  Status breakdown for the given time window.

  Returns `%{"completed" => N, "failed" => N, ...}`.
  """
  def status_breakdown(durable, window_minutes \\ 1440) do
    config = Config.get(durable)
    since = DateTime.add(DateTime.utc_now(), -window_minutes, :minute)

    query =
      from(w in WorkflowExecution,
        where: w.inserted_at >= ^since,
        group_by: w.status,
        select: {w.status, count(w.id)}
      )

    Durable.Repo.all(config, query)
    |> Map.new(fn {status, count} -> {to_string(status), count} end)
  end

  @doc """
  Duration percentiles (p50, p95, p99) from completed workflows in the window.

  Uses PostgreSQL's `percentile_cont` ordered-set aggregate function.
  Returns `%{p50: ms, p95: ms, p99: ms}` or zeroed values if no data.
  """
  def duration_percentiles(durable, window_minutes \\ 1440) do
    config = Config.get(durable)
    since = DateTime.add(DateTime.utc_now(), -window_minutes, :minute)

    query =
      from(w in WorkflowExecution,
        where:
          w.status == :completed and
            w.started_at >= ^since and
            not is_nil(w.started_at) and
            not is_nil(w.completed_at),
        select: %{
          p50:
            fragment(
              "COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000), 0)",
              w.completed_at,
              w.started_at
            ),
          p95:
            fragment(
              "COALESCE(percentile_cont(0.95) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000), 0)",
              w.completed_at,
              w.started_at
            ),
          p99:
            fragment(
              "COALESCE(percentile_cont(0.99) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (? - ?)) * 1000), 0)",
              w.completed_at,
              w.started_at
            )
        }
      )

    case Durable.Repo.one(config, query) do
      nil -> %{p50: 0, p95: 0, p99: 0}
      result -> %{p50: round(result.p50), p95: round(result.p95), p99: round(result.p99)}
    end
  end

  @doc """
  Queue depth — count of pending + running workflows per queue.

  Returns `%{"default" => 5, "priority" => 2}`.
  """
  def queue_depth(durable) do
    config = Config.get(durable)

    query =
      from(w in WorkflowExecution,
        where: w.status in [:pending, :running],
        group_by: w.queue,
        select: {w.queue, count(w.id)}
      )

    Durable.Repo.all(config, query)
    |> Map.new()
  end

  @doc """
  Top failing workflow names in the last 24 hours.

  Returns `[%{name: "process_order", count: 12}, ...]` ordered by count desc.
  """
  def top_failing(durable, limit \\ 5) do
    config = Config.get(durable)
    since = DateTime.add(DateTime.utc_now(), -1440, :minute)

    query =
      from(w in WorkflowExecution,
        where: w.status == :failed and w.inserted_at >= ^since,
        group_by: w.workflow_name,
        select: {w.workflow_name, count(w.id)},
        order_by: [desc: count(w.id)],
        limit: ^limit
      )

    Durable.Repo.all(config, query)
    |> Enum.map(fn {name, count} -> %{name: name, count: count} end)
  end

  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
  defp format_datetime(other), do: to_string(other)
end
