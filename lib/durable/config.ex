defmodule Durable.Config do
  @moduledoc """
  Configuration management for Durable.

  Durable configuration is validated at startup and stored in persistent_term
  for fast runtime access.

  ## Options

  * `:repo` - The Ecto repo module to use for persistence (required)
  * `:name` - Instance name for multiple Durable instances (default: `Durable`)
  * `:prefix` - PostgreSQL schema name for table isolation (default: `"durable"`)
  * `:queues` - Queue configuration map (default: `%{default: [concurrency: 10, poll_interval: 1000]}`)
  * `:queue_enabled` - Enable/disable queue processing (default: `true`)
  * `:stale_lock_timeout` - Seconds before a lock is considered stale (default: `300`)
  * `:heartbeat_interval` - Milliseconds between worker heartbeats (default: `30_000`)

  ## Examples

      # Single instance (most common)
      {Durable, repo: MyApp.Repo}

      # With custom queues
      {Durable,
       repo: MyApp.Repo,
       queues: %{
         default: [concurrency: 10],
         high_priority: [concurrency: 20, poll_interval: 500]
       }}

      # Multiple instances with different prefixes
      {Durable, repo: MyApp.Repo, name: :workflows_a, prefix: "durable_a"}
      {Durable, repo: MyApp.Repo, name: :workflows_b, prefix: "durable_b"}

  """

  @type t :: %__MODULE__{
          repo: module(),
          name: atom(),
          prefix: String.t(),
          queues: map(),
          queue_enabled: boolean(),
          stale_lock_timeout: pos_integer(),
          heartbeat_interval: pos_integer()
        }

  defstruct [
    :repo,
    :name,
    :prefix,
    :queues,
    :queue_enabled,
    :stale_lock_timeout,
    :heartbeat_interval
  ]

  @schema [
    repo: [
      type: :atom,
      required: true,
      doc: "The Ecto repo module to use for persistence"
    ],
    name: [
      type: :atom,
      default: Durable,
      doc: "Instance name for multiple Durable instances"
    ],
    prefix: [
      type: :string,
      default: "durable",
      doc: "PostgreSQL schema name for table isolation"
    ],
    queues: [
      type: :map,
      default: %{default: [concurrency: 10, poll_interval: 1000]},
      doc: "Queue configuration map"
    ],
    queue_enabled: [
      type: :boolean,
      default: true,
      doc: "Enable/disable queue processing"
    ],
    stale_lock_timeout: [
      type: :pos_integer,
      default: 300,
      doc: "Seconds before a lock is considered stale"
    ],
    heartbeat_interval: [
      type: :pos_integer,
      default: 30_000,
      doc: "Milliseconds between worker heartbeats"
    ]
  ]

  @doc """
  Creates a new validated configuration from options.

  Returns `{:ok, config}` if valid, `{:error, reason}` otherwise.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, NimbleOptions.ValidationError.t()}
  def new(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, validated} ->
        {:ok, struct(__MODULE__, validated)}

      {:error, %NimbleOptions.ValidationError{}} = error ->
        error
    end
  end

  @doc """
  Creates a new validated configuration, raising on error.
  """
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, error} -> raise error
    end
  end

  @doc """
  Stores the configuration for a Durable instance.

  Configuration is stored in persistent_term for fast lookups.
  """
  @spec put(atom(), t()) :: :ok
  def put(name, %__MODULE__{} = config) do
    :persistent_term.put({__MODULE__, name}, config)
    :ok
  end

  @doc """
  Retrieves the configuration for a Durable instance.

  Raises if the configuration hasn't been set.
  """
  @spec get(atom()) :: t()
  def get(name \\ Durable) do
    :persistent_term.get({__MODULE__, name})
  rescue
    ArgumentError ->
      raise ArgumentError,
            "Durable instance #{inspect(name)} not found. " <>
              "Make sure Durable is started with {Durable, repo: YourApp.Repo, name: #{inspect(name)}}"
  end

  @doc """
  Retrieves the configuration, returning `nil` if not set.
  """
  @spec get_safe(atom()) :: t() | nil
  def get_safe(name \\ Durable) do
    :persistent_term.get({__MODULE__, name}, nil)
  end

  @doc """
  Removes the configuration for a Durable instance.
  """
  @spec delete(atom()) :: :ok
  def delete(name) do
    :persistent_term.erase({__MODULE__, name})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Gets the repo module for a Durable instance.
  """
  @spec repo(atom()) :: module()
  def repo(name \\ Durable) do
    get(name).repo
  end

  @doc """
  Gets the database prefix for a Durable instance.
  """
  @spec prefix(atom()) :: String.t()
  def prefix(name \\ Durable) do
    get(name).prefix
  end

  @doc """
  Gets the queues configuration for a Durable instance.
  """
  @spec queues(atom()) :: map()
  def queues(name \\ Durable) do
    get(name).queues
  end

  @doc """
  Checks if queue processing is enabled for a Durable instance.
  """
  @spec queue_enabled?(atom()) :: boolean()
  def queue_enabled?(name \\ Durable) do
    get(name).queue_enabled
  end

  @doc """
  Gets the stale lock timeout for a Durable instance.
  """
  @spec stale_lock_timeout(atom()) :: pos_integer()
  def stale_lock_timeout(name \\ Durable) do
    get(name).stale_lock_timeout
  end

  @doc """
  Gets the heartbeat interval for a Durable instance.
  """
  @spec heartbeat_interval(atom()) :: pos_integer()
  def heartbeat_interval(name \\ Durable) do
    get(name).heartbeat_interval
  end

  @doc """
  Returns the NimbleOptions schema for documentation.
  """
  @spec schema() :: keyword()
  def schema, do: @schema
end
