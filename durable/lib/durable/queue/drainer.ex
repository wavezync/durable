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

  # Past the grace period, the time the hand-back has: killed sooner, by its
  # supervisor, with the hand-back still on the wire, the node left its runs
  # locked until `stale_lock_timeout`. A second wasn't always enough: a poller
  # that answers the drain late uses half of it (`drain/2`), and a database
  # that is busy as a node stops can take the rest.
  # ponytail: fixed, make it an option if a platform's own limit is tighter.
  @hand_back_ms 5_000

  @spec child_spec(Config.t()) :: Supervisor.child_spec()
  def child_spec(%Config{} = config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      shutdown: config.shutdown_grace_period + @hand_back_ms
    }
  end

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config)

  @doc false
  # Read before every step, so it's a persistent_term. It holds `false`, or
  # when the drain began (monotonic ms): both are immediates, so changing it
  # doesn't trigger a global GC.
  @spec stopping?(atom()) :: boolean()
  def stopping?(name), do: :persistent_term.get({__MODULE__, name}, false) != false

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
      unless stopping?(config.name),
        do: :persistent_term.put({__MODULE__, config.name}, System.monotonic_time(:millisecond))

      unfinished =
        config.queues
        |> Map.keys()
        |> Task.async_stream(&Manager.drain(config.name, &1, timeout),
          # At least one: a node with no queues has nothing to wait for, and
          # 0 is refused.
          max_concurrency: max(map_size(config.queues), 1),
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

  # A drain begun before the stop (`Durable.drain/1` from a `preStop` hook)
  # has used some of the grace period already: this waits for what's left, or
  # the platform's limit would kill the node before it hands its runs back.
  @impl true
  def terminate(_reason, config) do
    case drain(config, grace_left(config)) do
      :ok -> :ok
      {:error, :timeout} -> hand_back_running(config)
    end
  end

  defp grace_left(config) do
    case :persistent_term.get({__MODULE__, config.name}, false) do
      false ->
        config.shutdown_grace_period

      began ->
        max(config.shutdown_grace_period - (System.monotonic_time(:millisecond) - began), 0)
    end
  end

  # Its workers are stopped, then their runs go back on their queues. Without
  # this, those runs would sit locked until `stale_lock_timeout`. Stopped
  # first: a step still running once its run was back could run beside the
  # next node's, and steps that held every connection of the pool left none
  # for the hand-back, so it never happened.
  defp hand_back_running(config) do
    stop_workers(config)

    case Adapter.default_adapter().release_node_jobs(config, config.node_id) do
      {:ok, count} ->
        Logger.warning(
          "[Durable] #{count} run(s) outlasted the #{config.shutdown_grace_period} ms " <>
            "shutdown grace period and went back on their queues"
        )

        for queue <- Map.keys(config.queues) do
          DurablePubSub.broadcast_wake(config, to_string(queue))
        end

      # They stay locked until `stale_lock_timeout`, and the node still stops.
      {:error, reason} ->
        Logger.error("[Durable] couldn't hand back this node's runs: #{inspect(reason)}")
    end
  end

  # Killed, as their supervisor would after its own wait: a worker stuck in a
  # write never gets to a shutdown signal. Its step's task dies with it.
  #
  # The pollers go first. One busy in a slow query answers the drain after it
  # has timed out, unpaused, and its next claim came after the hand-back: that
  # run stayed locked by a node that was gone. A claim killed on its way is
  # cancelled, and one that landed is a run the hand-back finds running.
  defp stop_workers(config) do
    kill(Manager.pollers(config))
    kill(Manager.workers(config))
  end

  defp kill(pids) do
    refs = Enum.map(pids, &Process.monitor/1)
    Enum.each(pids, &Process.exit(&1, :kill))
    for ref <- refs, do: receive(do: ({:DOWN, ^ref, :process, _pid, _reason} -> :ok))
  end
end
