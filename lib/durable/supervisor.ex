defmodule Durable.Supervisor do
  @moduledoc """
  The main supervisor for a Durable instance.

  This supervisor manages the queue system for processing workflows.
  Users add Durable to their application's supervision tree to start
  the workflow engine.

  ## Usage

  Add Durable to your application's supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            MyApp.Repo,
            {Durable, repo: MyApp.Repo}
          ]

          opts = [strategy: :one_for_one, name: MyApp.Supervisor]
          Supervisor.start_link(children, opts)
        end
      end

  ## Options

  See `Durable.Config` for available options.

  ## Multiple Instances

  You can run multiple Durable instances by giving each a unique name:

      children = [
        MyApp.Repo,
        {Durable, repo: MyApp.Repo, name: :workflows_a, prefix: "durable_a"},
        {Durable, repo: MyApp.Repo, name: :workflows_b, prefix: "durable_b"}
      ]

  Each instance has its own:
  - Configuration stored separately
  - Queue system (pollers, workers)
  - Database tables (when using different prefixes)

  """

  use Supervisor

  require Logger

  alias Durable.Config

  @doc """
  Starts the Durable supervisor.

  ## Options

  * `:repo` - The Ecto repo module (required)
  * `:name` - Instance name (default: `Durable`)
  * `:prefix` - Database schema prefix (default: `"durable"`)
  * `:queues` - Queue configuration
  * `:queue_enabled` - Enable/disable queue processing (default: `true`)

  See `Durable.Config` for the complete list of options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, Durable)

    case Config.new(opts) do
      {:ok, config} ->
        Config.put(name, config)
        Supervisor.start_link(__MODULE__, config, name: supervisor_name(name))

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Returns the supervisor name for a Durable instance.
  """
  @spec supervisor_name(atom()) :: atom()
  def supervisor_name(name) do
    Module.concat(name, Supervisor)
  end

  @impl true
  def init(%Config{} = config) do
    # Attach log capture handler (idempotent)
    :ok = Durable.LogCapture.Handler.attach()

    children =
      if config.queue_enabled do
        Logger.info(
          "Durable #{inspect(config.name)} starting with queues: #{inspect(Map.keys(config.queues))}"
        )

        [
          {Durable.Queue.Manager, config: config}
        ]
      else
        Logger.info("Durable #{inspect(config.name)} starting with queue processing disabled")
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Stops a Durable instance and cleans up its configuration.
  """
  @spec stop(atom()) :: :ok
  def stop(name \\ Durable) do
    sup_name = supervisor_name(name)

    if Process.whereis(sup_name) do
      Supervisor.stop(sup_name)
    end

    Config.delete(name)
    :ok
  end
end
