defmodule Durable.Scheduler do
  @moduledoc """
  GenServer that polls for due scheduled workflows and triggers them.

  This module runs as part of the Durable supervision tree and:

  - Polls every 60 seconds for due schedules
  - Uses `FOR UPDATE SKIP LOCKED` for multi-node safety
  - Starts workflows via the normal queue system
  - Updates last_run_at and next_run_at after each execution

  ## Multi-Node Safety

  When running multiple Durable instances (e.g., multiple app nodes),
  only one node will execute each scheduled workflow. This is achieved
  using PostgreSQL's `FOR UPDATE SKIP LOCKED` clause, which allows
  each node to atomically claim schedules without conflicts.

  ## Configuration

  The scheduler is automatically started when Durable starts. No additional
  configuration is required.
  """

  use GenServer

  require Logger

  alias Durable.Scheduler.API

  @default_interval 60_000

  defstruct [
    :config,
    :interval,
    :timer_ref,
    :scheduled_modules
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the scheduler process.

  ## Options

  - `:config` - The Durable configuration (required)
  - `:interval` - Poll interval in milliseconds (default: 60_000)
  - `:scheduled_modules` - List of modules to register on startup
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    GenServer.start_link(__MODULE__, opts, name: scheduler_name(config.name))
  end

  @doc """
  Returns the process name for a given Durable instance.
  """
  @spec scheduler_name(atom()) :: atom()
  def scheduler_name(durable_name) do
    Module.concat([durable_name, Scheduler])
  end

  @doc """
  Manually triggers a check for due schedules.
  """
  @spec check_schedules(atom()) :: :ok
  def check_schedules(durable_name \\ Durable) do
    GenServer.cast(scheduler_name(durable_name), :check_schedules)
  end

  @doc """
  Returns the current state of the scheduler for debugging.
  """
  @spec status(atom()) :: map()
  def status(durable_name \\ Durable) do
    GenServer.call(scheduler_name(durable_name), :status)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    interval = Keyword.get(opts, :interval, @default_interval)
    scheduled_modules = Keyword.get(opts, :scheduled_modules, [])

    state = %__MODULE__{
      config: config,
      interval: interval,
      timer_ref: nil,
      scheduled_modules: scheduled_modules
    }

    # Register scheduled modules
    register_modules(scheduled_modules, config.name)

    # Schedule first check
    state = schedule_check(state, 1000)

    Logger.info("Scheduler started with interval=#{interval}ms")

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      interval: state.interval,
      scheduled_modules: state.scheduled_modules,
      durable_name: state.config.name
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:check, state) do
    state = %{state | timer_ref: nil}
    process_due_schedules(state.config)
    state = schedule_check(state, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:check_schedules, state) do
    process_due_schedules(state.config)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_check(state, delay) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    timer_ref = Process.send_after(self(), :check, delay)
    %{state | timer_ref: timer_ref}
  end

  defp register_modules([], _durable_name), do: :ok

  defp register_modules(modules, durable_name) do
    case API.register_all(modules, durable: durable_name) do
      :ok ->
        Logger.info("Registered #{length(modules)} scheduled module(s)")

      {:error, reason} ->
        Logger.error("Failed to register scheduled modules: #{inspect(reason)}")
    end
  end

  defp process_due_schedules(config) do
    due_schedules = API.get_due_schedules(config)

    if due_schedules != [] do
      Logger.debug("Found #{length(due_schedules)} due schedule(s)")
    end

    Enum.each(due_schedules, fn schedule ->
      execute_schedule(schedule, config)
    end)
  end

  defp execute_schedule(schedule, config) do
    # Parse the module from the stored string
    module = parse_module(schedule.workflow_module)

    case module do
      {:ok, mod} ->
        start_workflow(schedule, mod, config)

      {:error, reason} ->
        Logger.error("Failed to load module for schedule #{schedule.name}: #{inspect(reason)}")
    end
  end

  defp parse_module(module_string) do
    # Handle both "Elixir.MyModule" and "MyModule" formats
    module_name =
      if String.starts_with?(module_string, "Elixir.") do
        module_string
      else
        "Elixir." <> module_string
      end

    try do
      {:ok, String.to_existing_atom(module_name)}
    rescue
      ArgumentError ->
        {:error, :module_not_found}
    end
  end

  defp start_workflow(schedule, module, config) do
    # Start the workflow
    result =
      Durable.Executor.start_workflow(module, schedule.input,
        workflow: schedule.workflow_name,
        queue: String.to_atom(schedule.queue),
        durable: config.name
      )

    case result do
      {:ok, workflow_id} ->
        # Update last_run_at and next_run_at
        case API.mark_run(schedule, config) do
          {:ok, _} ->
            emit_schedule_triggered(schedule, workflow_id)

            Logger.info("Triggered schedule #{schedule.name} -> workflow_id=#{workflow_id}")

          {:error, reason} ->
            Logger.error(
              "Failed to update run times for schedule #{schedule.name}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.error("Failed to start workflow for schedule #{schedule.name}: #{inspect(reason)}")
    end
  end

  defp emit_schedule_triggered(schedule, workflow_id) do
    :telemetry.execute(
      [:durable, :scheduler, :triggered],
      %{count: 1},
      %{
        schedule_name: schedule.name,
        workflow_id: workflow_id,
        workflow_module: schedule.workflow_module,
        workflow_name: schedule.workflow_name,
        queue: schedule.queue
      }
    )
  end
end
