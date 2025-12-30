defmodule Durable.Queue.Manager do
  @moduledoc """
  Supervises queue pollers and worker supervisors.

  The Manager creates a supervision tree for each configured queue:
  - A DynamicSupervisor for workers
  - A Poller for the queue

  It also starts the StaleJobRecovery process and a Registry for
  looking up pollers by queue name.

  ## Configuration

  Queues are configured in the application environment:

      config :durable,
        queues: %{
          default: [concurrency: 10, poll_interval: 1000],
          high_priority: [concurrency: 20, poll_interval: 500]
        }
  """

  use Supervisor

  require Logger

  alias Durable.Queue.Poller
  alias Durable.Queue.StaleJobRecovery

  @doc """
  Starts the queue manager supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Pauses a queue, stopping it from claiming new jobs.
  """
  @spec pause(atom() | String.t()) :: :ok
  def pause(queue_name) do
    queue_name
    |> normalize_queue_name()
    |> poller_name()
    |> Poller.pause()
  end

  @doc """
  Resumes a paused queue.
  """
  @spec resume(atom() | String.t()) :: :ok
  def resume(queue_name) do
    queue_name
    |> normalize_queue_name()
    |> poller_name()
    |> Poller.resume()
  end

  @doc """
  Drains a queue, waiting for active jobs to complete.
  """
  @spec drain(atom() | String.t(), timeout()) :: :ok | {:error, :timeout}
  def drain(queue_name, timeout \\ 30_000) do
    queue_name
    |> normalize_queue_name()
    |> poller_name()
    |> Poller.drain(timeout)
  end

  @doc """
  Returns the status of a queue.
  """
  @spec status(atom() | String.t()) :: map()
  def status(queue_name) do
    queue_name
    |> normalize_queue_name()
    |> poller_name()
    |> Poller.status()
  end

  @doc """
  Returns statistics for a queue from the adapter.
  """
  @spec stats(atom() | String.t()) :: map()
  def stats(queue_name) do
    queue_name
    |> normalize_queue_name()
    |> Durable.Queue.Adapter.adapter().get_stats()
  end

  @doc """
  Returns the list of configured queues.
  """
  @spec queues() :: [String.t()]
  def queues do
    get_queue_config()
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end

  # Supervisor callbacks

  @impl true
  def init(_opts) do
    # Check if queue is enabled
    if queue_enabled?() do
      queues = get_queue_config()

      children =
        [
          # Registry for looking up pollers by name
          {Registry, keys: :unique, name: Durable.Queue.Registry},

          # Stale job recovery
          {StaleJobRecovery, []}
        ] ++ build_queue_children(queues)

      Logger.info("Queue manager starting with queues: #{inspect(Map.keys(queues))}")

      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.info("Queue manager disabled (queue_enabled: false)")
      Supervisor.init([], strategy: :one_for_one)
    end
  end

  # Private functions

  defp build_queue_children(queues) do
    Enum.flat_map(queues, fn {queue_name, opts} ->
      queue_str = to_string(queue_name)
      worker_sup_name = worker_supervisor_name(queue_str)

      [
        # DynamicSupervisor for workers
        {DynamicSupervisor, name: worker_sup_name, strategy: :one_for_one},

        # Poller for this queue
        {Poller,
         [
           queue_name: queue_str,
           concurrency: Keyword.get(opts, :concurrency, 10),
           poll_interval: Keyword.get(opts, :poll_interval, 1000),
           worker_supervisor: worker_sup_name,
           name: poller_name(queue_str)
         ]}
      ]
    end)
  end

  defp get_queue_config do
    Application.get_env(:durable, :queues, %{
      default: [concurrency: 10, poll_interval: 1000]
    })
  end

  defp queue_enabled? do
    Application.get_env(:durable, :queue_enabled, true)
  end

  defp normalize_queue_name(name) when is_atom(name), do: to_string(name)
  defp normalize_queue_name(name) when is_binary(name), do: name

  defp worker_supervisor_name(queue_name) do
    Module.concat([Durable.Queue.WorkerSupervisor, camelize(queue_name)])
  end

  defp poller_name(queue_name) do
    Module.concat([Durable.Queue.Poller, camelize(queue_name)])
  end

  defp camelize(string) do
    string
    |> String.split("_")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
    |> String.to_atom()
  end
end
