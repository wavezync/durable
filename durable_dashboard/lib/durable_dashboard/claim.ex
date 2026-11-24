defmodule DurableDashboard.Claim do
  @moduledoc false
  # What a run's lock says about the worker that has it, for the run page and
  # the run list: who holds it, whether that's a caller running it inline,
  # whether a worker that was stopped mid-step still has it (ARCHITECTURE rule
  # 30), and whether a worker's heartbeat is late. Times are Durable's
  # (`DurableDashboard.Clock`), the clock `locked_at` was written by.

  # A heartbeat counts as late past two intervals: one can be a slow query.
  @late_after_beats 2

  @doc "`{node, inline?}` for a `locked_by`: a caller running a run inline claims it as `node/inline`."
  @spec owner(String.t() | nil) :: {String.t(), boolean()} | nil
  def owner(nil), do: nil

  def owner(locked_by) when is_binary(locked_by) do
    case String.split(locked_by, "/inline") do
      [node, ""] -> {node, true}
      _ -> {locked_by, false}
    end
  end

  @doc """
  A cancelled run whose worker hasn't stopped its step yet: `%{node:, inline?:,
  until:}`, where `until` is when its lock goes stale, the latest it can hold
  anything up. nil otherwise.
  """
  @spec stopping(map(), Durable.Config.t() | nil, DateTime.t()) :: map() | nil
  def stopping(%{locked_by: by, locked_at: %DateTime{} = at} = run, %{} = config, now) do
    until = DateTime.add(at, config.stale_lock_timeout, :second)
    {node, inline?} = owner(by)

    if kept?(run) and DateTime.after?(until, now),
      do: %{node: node, inline?: inline?, until: until}
  end

  def stopping(_run, _config, _now), do: nil

  # A run read through `Durable.Query` says so; the row itself has no token.
  defp kept?(%{kept_lock: kept}), do: kept

  defp kept?(%{locked_by: by, lock_token: nil, status: status}),
    do: by != nil and status in [:pending, :cancelled]

  defp kept?(_run), do: false

  @doc """
  A running run whose worker hasn't refreshed its lock for two heartbeats:
  `%{node:, inline?:, silent_s:, stops_by:}`. A worker that can't reach the
  database stops its step by `stops_by`, a heartbeat before its lock goes
  stale, and the run goes back on its queue. nil otherwise.
  """
  @spec late(map(), Durable.Config.t() | nil, DateTime.t()) :: map() | nil
  def late(%{status: status, locked_by: by, locked_at: %DateTime{} = at}, %{} = config, now)
      when status in [:running, :compensating] and is_binary(by) do
    silent_ms = DateTime.diff(now, at, :millisecond)
    {node, inline?} = owner(by)

    if silent_ms > @late_after_beats * config.heartbeat_interval do
      stops_by =
        DateTime.add(
          at,
          config.stale_lock_timeout * 1_000 - config.heartbeat_interval,
          :millisecond
        )

      %{node: node, inline?: inline?, silent_s: div(silent_ms, 1_000), stops_by: stops_by}
    end
  end

  def late(_run, _config, _now), do: nil

  @doc """
  For a run of a key that is due but not running: the other run of the key
  whose stopped worker it waits for (rule 30), with `stopping/3`'s facts.
  nil when nothing holds it back.
  """
  @spec held_back_by(map(), atom(), Durable.Config.t() | nil, DateTime.t()) :: map() | nil
  def held_back_by(%{status: :pending, key: key} = run, durable, %{} = config, now)
      when is_binary(key) do
    with {:ok, runs} <-
           Durable.list_executions(
             durable: durable,
             key: key,
             workflow_name: run.workflow_name,
             status: [:cancelled, :pending],
             limit: 50
           ),
         %{} = other <- Enum.find(runs, &(&1.id != run.id and stopping(&1, config, now))) do
      Map.put(stopping(other, config, now), :run, other)
    else
      _ -> nil
    end
  end

  def held_back_by(_run, _durable, _config, _now), do: nil
end
