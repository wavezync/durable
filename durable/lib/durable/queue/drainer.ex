defmodule Durable.Queue.Drainer do
  @moduledoc false
  # Lets running work finish when a node stops, so a deploy doesn't leave runs
  # locked until `stale_lock_timeout`.
  #
  # Started last under `Queue.Manager`, so it's the first thing stopped, while
  # every poller and worker is still alive. All queues drain at once: stopped
  # one at a time, later queues would keep claiming while earlier ones waited,
  # and each would get its own grace period.

  use GenServer

  require Logger

  alias Durable.Config
  alias Durable.Queue.Manager

  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      shutdown: config.shutdown_grace_period + 1_000
    }
  end

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    {:ok, config}
  end

  @impl true
  def terminate(_reason, config) do
    grace = config.shutdown_grace_period

    unfinished =
      config.queues
      |> Map.keys()
      |> Task.async_stream(&Manager.drain(config.name, &1, grace),
        max_concurrency: map_size(config.queues),
        timeout: grace + 500,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.count(&(&1 != {:ok, :ok}))

    if unfinished > 0 do
      Logger.warning(
        "[Durable] #{unfinished} queue(s) still had running work after #{grace} ms; " <>
          "those runs are taken over after stale_lock_timeout"
      )
    end
  end
end
