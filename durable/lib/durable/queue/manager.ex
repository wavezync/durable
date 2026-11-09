defmodule Durable.Queue.Manager do
  @moduledoc """
  Supervises queue pollers and worker supervisors.

  The Manager creates a supervision tree for each configured queue:
  - A DynamicSupervisor for workers
  - A Poller for the queue

  It also starts the StaleJobRecovery process and a Registry for
  looking up pollers by queue name.

  ## Configuration

  Queue configuration is passed via the Durable config:

      {Durable,
       repo: MyApp.Repo,
       queues: %{
         default: [concurrency: 10, poll_interval: 1000],
         high_priority: [concurrency: 20, poll_interval: 500]
       }}
  """

  use Supervisor

  require Logger

  alias Durable.Config
  alias Durable.Queue.Adapter
  alias Durable.Queue.Poller
  alias Durable.Queue.StaleJobRecovery

  @doc """
  Starts the queue manager supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    Supervisor.start_link(__MODULE__, config, name: manager_name(config.name))
  end

  @doc """
  Pauses a queue, stopping it from claiming new jobs.
  """
  @spec pause(atom(), atom() | String.t()) :: :ok
  def pause(durable_name \\ Durable, queue_name) do
    queue_name
    |> normalize_queue_name()
    |> poller_name(durable_name)
    |> Poller.pause()
  end

  @doc """
  Resumes a paused queue.
  """
  @spec resume(atom(), atom() | String.t()) :: :ok
  def resume(durable_name \\ Durable, queue_name) do
    queue_name
    |> normalize_queue_name()
    |> poller_name(durable_name)
    |> Poller.resume()
  end

  @doc """
  Drains a queue, waiting for active jobs to complete.
  """
  @spec drain(atom(), atom() | String.t(), timeout()) :: :ok | {:error, :timeout}
  def drain(durable_name \\ Durable, queue_name, timeout \\ 30_000) do
    queue_name
    |> normalize_queue_name()
    |> poller_name(durable_name)
    |> Poller.drain(timeout)
  end

  @doc """
  Returns the status of a queue.
  """
  @spec status(atom(), atom() | String.t()) :: map()
  def status(durable_name \\ Durable, queue_name) do
    queue_name
    |> normalize_queue_name()
    |> poller_name(durable_name)
    |> Poller.status()
  end

  @doc """
  Returns statistics for a queue from the adapter.
  """
  @spec stats(atom(), atom() | String.t()) :: map()
  def stats(durable_name \\ Durable, queue_name) do
    config = Config.get(durable_name)

    queue_name
    |> normalize_queue_name()
    |> then(&Adapter.default_adapter().get_stats(config, &1))
  end

  @doc """
  Returns the list of configured queues for a Durable instance.
  """
  @spec queues(atom()) :: [String.t()]
  def queues(durable_name \\ Durable) do
    Config.queues(durable_name)
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end

  # Supervisor callbacks

  @impl true
  def init(%Config{} = config) do
    children =
      [
        # Registry for looking up pollers by name
        {Registry, keys: :unique, name: registry_name(config.name)},

        # Stale job recovery
        {StaleJobRecovery, config: config},

        # Delivers wakes sent from inside a transaction, at its commit. It logs
        # each failed reconnect, so it doesn't retry at Postgrex's 500 ms.
        # ponytail: Postgrex crashes this if a poller dies while it's
        # disconnected. Its restart loses the other pollers' listens, so those
        # wakes wait for the next poll until the pollers restart.
        {Postgrex.Notifications,
         Keyword.merge(config.repo.config(),
           name: notifications_name(config.name),
           auto_reconnect: true,
           reconnect_backoff: 2_000
         )}
      ] ++ build_queue_children(config)

    Logger.info(
      "Queue manager #{inspect(config.name)} starting with queues: #{inspect(Map.keys(config.queues))}"
    )

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private functions

  defp build_queue_children(%Config{} = config) do
    Enum.flat_map(config.queues, fn {queue_name, opts} ->
      queue_str = to_string(queue_name)
      worker_sup_name = worker_supervisor_name(queue_str, config.name)

      [
        # DynamicSupervisor for workers
        {DynamicSupervisor, name: worker_sup_name, strategy: :one_for_one},

        # Poller for this queue
        Supervisor.child_spec(
          {Poller,
           [
             config: config,
             queue_name: queue_str,
             concurrency: Keyword.get(opts, :concurrency, 10),
             poll_interval: Keyword.get(opts, :poll_interval, 1000),
             worker_supervisor: worker_sup_name,
             notifications: notifications_name(config.name),
             name: poller_name(queue_str, config.name)
           ]},
          id: {Poller, queue_str}
        )
      ]
    end)
  end

  defp manager_name(durable_name) do
    Module.concat([durable_name, Queue, Manager])
  end

  defp notifications_name(durable_name) do
    Module.concat([durable_name, Queue, Notifications])
  end

  defp registry_name(durable_name) do
    Module.concat([durable_name, Queue, Registry])
  end

  defp normalize_queue_name(name) when is_atom(name), do: to_string(name)
  defp normalize_queue_name(name) when is_binary(name), do: name

  defp worker_supervisor_name(queue_name, durable_name) do
    Module.concat([durable_name, Queue, WorkerSupervisor, camelize(queue_name)])
  end

  defp poller_name(queue_name, durable_name) do
    Module.concat([durable_name, Queue, :Poller, camelize(queue_name)])
  end

  defp camelize(string) do
    string
    |> String.split("_")
    |> Enum.map_join(&String.capitalize/1)
    |> String.to_atom()
  end
end
