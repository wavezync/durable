defmodule Durable.Queue.Sampler do
  @moduledoc """
  Once a minute, records every queue's depth — ready, scheduled, running,
  waiting — in `durable.queue_samples`, so backlog can be charted over time
  (`Durable.Stats.queue_history/1`).

  Every node runs a sampler; the row for a queue and minute is written by
  whichever gets there first (`ON CONFLICT DO NOTHING`), so the cluster keeps
  one sample per minute however many nodes there are. Samples and
  `Durable.Activity` rows older than #{7} days are deleted on the way.
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias Durable.Config
  alias Durable.Repo
  alias Durable.Storage.Schemas.{ActivityEvent, QueueSample, WorkflowExecution}

  @keep_s 7 * 86_400

  def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :config))

  @impl true
  def init(%Config{} = config) do
    schedule_next()
    {:ok, config}
  end

  @impl true
  def handle_info(:sample, config) do
    safely(fn -> sample(config) end)
    schedule_next()
    {:noreply, config}
  end

  @doc """
  Writes this minute's sample for every queue, unless another node already
  has. Returns the samples it computed.
  """
  @spec sample(Config.t()) :: [map()]
  def sample(%Config{} = config) do
    now = DateTime.utc_now()
    minute = %{DateTime.truncate(now, :second) | second: 0}

    counts =
      config
      |> Repo.all(
        from(w in WorkflowExecution,
          where: w.status in [:pending, :running, :waiting],
          group_by: w.queue,
          select:
            {w.queue,
             %{
               ready:
                 filter(
                   count(w.id),
                   w.status == :pending and (is_nil(w.scheduled_at) or w.scheduled_at <= ^now)
                 ),
               scheduled: filter(count(w.id), w.status == :pending and w.scheduled_at > ^now),
               running: filter(count(w.id), w.status == :running),
               waiting: filter(count(w.id), w.status == :waiting)
             }}
        )
      )
      |> Map.new()

    empty = %{ready: 0, scheduled: 0, running: 0, waiting: 0}

    rows =
      (Enum.map(Map.keys(config.queues), &to_string/1) ++ Map.keys(counts))
      |> Enum.uniq()
      |> Enum.map(&Map.merge(Map.get(counts, &1, empty), %{queue: &1, at: minute}))

    Repo.insert_all(config, QueueSample, rows, on_conflict: :nothing)

    cutoff = DateTime.add(now, -@keep_s, :second)
    Repo.delete_all(config, from(s in QueueSample, where: s.at < ^cutoff))
    Repo.delete_all(config, from(a in ActivityEvent, where: a.at < ^cutoff))

    rows
  end

  # Just after the next minute boundary, so every node samples the same minute.
  defp schedule_next do
    ms = 60_000 - rem(System.os_time(:millisecond), 60_000) + 500
    Process.send_after(self(), :sample, ms)
  end

  # History is advisory; a database blip must never crash Durable's tree.
  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.debug("[Durable] queue sampler: #{Exception.message(e)}")
  end
end
