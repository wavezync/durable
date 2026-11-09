defmodule Durable.Scheduler do
  @moduledoc """
  GenServer that polls for due scheduled workflows and triggers them.

  This module runs as part of the Durable supervision tree and:

  - Polls every 60 seconds for due schedules
  - Claims each fire with one conditional update, for multi-node safety
  - Starts workflows via the normal queue system
  - Updates last_run_at and next_run_at as it claims each fire

  ## Multi-Node Safety

  When running multiple Durable instances (e.g., multiple app nodes),
  only one node starts each fire of a schedule. Each node that sees a schedule
  due tries to move its `next_run_at` on from the value it read, and only the
  one whose update matched a row starts the run. The update and the start
  commit together, so a node that dies between them leaves the fire to the next.

  ## Configuration

  The scheduler is automatically started when Durable starts. No additional
  configuration is required.
  """

  use GenServer

  require Logger

  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler, as: CronScheduler
  alias Durable.Repo
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.ScheduledWorkflow

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
    safely_process_due_schedules(state.config)
    state = schedule_check(state, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:check_schedules, state) do
    safely_process_due_schedules(state.config)
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
        API.turn_off_removed(modules, durable: durable_name)
        Logger.info("Registered #{length(modules)} scheduled module(s)")

      {:error, reason} ->
        Logger.error("Failed to register scheduled modules: #{inspect(reason)}")
    end
  end

  # A busy pool mustn't take the scheduler down. The next check tries again.
  defp safely_process_due_schedules(config) do
    process_due_schedules(config)
  rescue
    error -> Logger.warning("[Durable.Scheduler] check failed: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("[Durable.Scheduler] check failed: #{inspect(reason)}")
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
        # Bug L-1: instead of just logging and re-firing on every poll cycle,
        # record the failure on the schedule row, advance next_run_at past
        # the current trigger so we don't loop hot, and auto-disable after
        # too many consecutive failures.
        record_failure(
          schedule,
          config,
          "Failed to load module #{schedule.workflow_module}: #{inspect(reason)}"
        )
    end
  end

  defp record_failure(schedule, config, message) do
    # Compute the next run time so we don't immediately re-fire on the next
    # poll. If the cron parse itself fails, just defer 5 minutes.
    next_run_at = compute_next_run(schedule)

    changeset =
      ScheduledWorkflow.failure_changeset(schedule, message,
        next_run_at: next_run_at,
        auto_disable_after: 5
      )

    case Repo.update(changeset, config) do
      {:ok, updated} ->
        if updated.auto_disabled_at do
          Logger.error(
            "[Durable.Scheduler] Auto-disabled #{schedule.name} after " <>
              "#{updated.consecutive_failures} consecutive failures: #{message}"
          )

          Durable.Activity.record(config, "schedule_disabled",
            queue: schedule.queue,
            details: %{
              schedule: schedule.name,
              failures: updated.consecutive_failures,
              error: message
            }
          )
        else
          Logger.warning(
            "[Durable.Scheduler] Schedule #{schedule.name} failure " <>
              "(#{updated.consecutive_failures}): #{message}"
          )
        end

      {:error, cs} ->
        Logger.error(
          "[Durable.Scheduler] Failed to record failure for #{schedule.name}: " <>
            inspect(cs.errors)
        )
    end
  end

  defp compute_next_run(schedule) do
    case CronParser.parse(schedule.cron_expression) do
      {:ok, cron} ->
        case CronScheduler.get_next_run_date(cron, DateTime.utc_now() |> DateTime.to_naive()) do
          {:ok, naive} ->
            naive
            |> DateTime.from_naive!("Etc/UTC")
            |> then(&%{&1 | microsecond: {elem(&1.microsecond, 0), 6}})

          _ ->
            DateTime.add(DateTime.utc_now(), 300, :second)
        end

      _ ->
        DateTime.add(DateTime.utc_now(), 300, :second)
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
    case claim_and_start(schedule, module, config) do
      {:ok, {:started, workflow_id}} ->
        emit_schedule_triggered(schedule, workflow_id, config)
        Logger.info("Triggered schedule #{schedule.name} -> workflow_id=#{workflow_id}")

      {:ok, {:skipped, holder_id}} ->
        Logger.info(
          "Skipped schedule #{schedule.name}: key #{schedule.key} is held by #{holder_id}"
        )

      {:ok, :claimed_elsewhere} ->
        Logger.debug("Schedule #{schedule.name} was fired by another node")

      {:error, reason} ->
        Logger.error("Failed to start workflow for schedule #{schedule.name}: #{inspect(reason)}")
    end
  end

  # In one transaction, so a start that fails leaves the fire for the next check.
  defp claim_and_start(schedule, module, config) do
    Repo.transaction(config, fn ->
      if API.claim_fire(schedule, config) do
        start_claimed(schedule, module, config)
      else
        :claimed_elsewhere
      end
    end)
  end

  defp start_claimed(schedule, module, config) do
    result =
      Durable.Executor.start_workflow(module, schedule.input,
        workflow: schedule.workflow_name,
        queue: String.to_atom(schedule.queue),
        key: schedule.key,
        durable: config.name,
        trigger: :schedule,
        trigger_ref: schedule.name
      )

    case result do
      {:ok, workflow_id} ->
        {:started, workflow_id}

      # The workflow's on_duplicate: :error refused the start: the last run
      # still holds the key. That's this fire being skipped, not a failure,
      # so move on to the next one (Activity has the duplicate).
      {:error, {:key_taken, holder_id}} ->
        {:skipped, holder_id}

      {:error, reason} ->
        config.repo.rollback(reason)
    end
  end

  defp emit_schedule_triggered(schedule, workflow_id, config) do
    :telemetry.execute(
      [:durable, :schedule, :trigger],
      %{count: 1},
      %{
        durable: config.name,
        schedule: schedule.name,
        workflow_id: workflow_id,
        workflow_module: schedule.workflow_module,
        workflow: schedule.workflow_name,
        queue: schedule.queue
      }
    )
  end
end
