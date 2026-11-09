defmodule Durable.Queue.Drainer do
  @moduledoc false
  # Lets running work finish when a node stops, so a deploy doesn't leave runs
  # locked until `stale_lock_timeout`.
  #
  # Started last under `Queue.Manager`, so it's the first thing stopped, while
  # every poller and worker is still alive. All queues drain at once: stopped
  # one at a time, later queues would keep claiming while earlier ones waited,
  # and each would get its own grace period.
  #
  # While a node drains, a run finishes its current step and goes back on its
  # queue for another node (`Executor.queue_move/3`), and steps can see it with
  # `Durable.Context.shutting_down?/0`.

  use GenServer

  require Logger

  alias Durable.Config
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Queue.Adapter
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

  @doc false
  # Read before every step, so it's a persistent_term. Booleans are immediates,
  # so flipping one doesn't trigger a global GC.
  @spec stopping?(atom()) :: boolean()
  def stopping?(name), do: :persistent_term.get({__MODULE__, name}, false)

  @doc false
  @spec reset(atom()) :: :ok
  def reset(name), do: :persistent_term.put({__MODULE__, name}, false)

  @doc false
  # Stops this node claiming and waits for its workers, on every queue at once.
  @spec drain(Config.t(), non_neg_integer()) :: :ok | {:error, :timeout}
  def drain(%Config{queue_enabled: false}, _timeout), do: :ok

  def drain(%Config{} = config, timeout) do
    meta = %{durable: config.name, node_id: config.node_id}

    :telemetry.span([:durable, :node, :drain], meta, fn ->
      :persistent_term.put({__MODULE__, config.name}, true)

      unfinished =
        config.queues
        |> Map.keys()
        |> Task.async_stream(&Manager.drain(config.name, &1, timeout),
          max_concurrency: map_size(config.queues),
          timeout: timeout + 500,
          on_timeout: :kill_task,
          ordered: false
        )
        |> Enum.count(&(&1 != {:ok, :ok}))

      result = if unfinished == 0, do: :ok, else: {:error, :timeout}
      {result, Map.put(meta, :result, result)}
    end)
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    {:ok, config}
  end

  @impl true
  def terminate(_reason, config) do
    case drain(config, config.shutdown_grace_period) do
      :ok -> :ok
      {:error, :timeout} -> hand_back_running(config)
    end
  end

  # Its workers are about to be killed. Without this, their runs would sit
  # locked until `stale_lock_timeout`. Clearing the fencing token means a worker
  # still finishing up can't record anything over the next claim.
  defp hand_back_running(config) do
    {:ok, count} = Adapter.default_adapter().release_node_jobs(config, config.node_id)

    Logger.warning(
      "[Durable] #{count} run(s) outlasted the #{config.shutdown_grace_period} ms " <>
        "shutdown grace period and went back on their queues"
    )

    for queue <- Map.keys(config.queues) do
      DurablePubSub.broadcast_wake(config, to_string(queue))
    end
  end
end
