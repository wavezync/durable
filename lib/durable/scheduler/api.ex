defmodule Durable.Scheduler.API do
  @moduledoc """
  CRUD operations for scheduled workflows.

  This module provides functions to create, read, update, and delete
  scheduled workflows that run on cron expressions.

  ## Usage

      # Create a schedule
      Durable.schedule(MyApp.DailyReport, "0 9 * * *", name: "daily_report")

      # List schedules
      Durable.list_schedules(enabled: true)

      # Update a schedule
      Durable.update_schedule("daily_report", cron: "0 10 * * *")

      # Delete a schedule
      Durable.delete_schedule("daily_report")

  """

  import Ecto.Query

  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler
  alias Durable.Config
  alias Durable.Storage.Schemas.ScheduledWorkflow

  @type schedule_opts :: [
          name: String.t(),
          workflow: String.t(),
          input: map(),
          timezone: String.t(),
          queue: atom() | String.t(),
          enabled: boolean(),
          durable: atom()
        ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Creates a new scheduled workflow.

  ## Arguments

  - `module` - The workflow module
  - `cron_expression` - Cron expression (e.g., "0 9 * * *" for 9am daily)
  - `opts` - Options

  ## Options

  - `:name` - Schedule name (defaults to workflow name)
  - `:workflow` - Workflow name (defaults to first workflow in module)
  - `:input` - Input data for each execution
  - `:timezone` - Timezone for cron (default: "UTC")
  - `:queue` - Queue to run on (default: :default)
  - `:enabled` - Whether schedule is active (default: true)
  - `:durable` - Durable instance name (default: Durable)

  ## Examples

      {:ok, schedule} = Durable.schedule(MyApp.DailyReport, "0 9 * * *")

      {:ok, schedule} = Durable.schedule(
        MyApp.Reports,
        "0 9 * * MON-FRI",
        name: "weekday_report",
        workflow: "generate_report",
        timezone: "America/New_York",
        queue: :reports
      )

  """
  @spec schedule(module(), String.t(), schedule_opts()) ::
          {:ok, ScheduledWorkflow.t()} | {:error, term()}
  def schedule(module, cron_expression, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    repo = Config.repo(durable_name)

    with {:ok, workflow_name} <- resolve_workflow_name(module, opts),
         :ok <- validate_cron(cron_expression),
         {:ok, next_run} <- compute_next_run(cron_expression, Keyword.get(opts, :timezone, "UTC")) do
      schedule_name = Keyword.get(opts, :name, workflow_name)

      attrs = %{
        name: schedule_name,
        workflow_module: inspect(module),
        workflow_name: workflow_name,
        cron_expression: cron_expression,
        timezone: Keyword.get(opts, :timezone, "UTC"),
        input: Keyword.get(opts, :input, %{}),
        queue: to_string(Keyword.get(opts, :queue, :default)),
        enabled: Keyword.get(opts, :enabled, true),
        next_run_at: next_run
      }

      %ScheduledWorkflow{}
      |> ScheduledWorkflow.changeset(attrs)
      |> repo.insert()
    end
  end

  @doc """
  Lists scheduled workflows with optional filters.

  ## Filters

  - `:enabled` - Filter by enabled status
  - `:workflow_module` - Filter by module
  - `:queue` - Filter by queue
  - `:limit` - Maximum results (default: 100)
  - `:offset` - Offset for pagination
  - `:durable` - Durable instance name

  ## Examples

      schedules = Durable.list_schedules(enabled: true)
      schedules = Durable.list_schedules(queue: :reports, limit: 10)

  """
  @spec list_schedules(keyword()) :: [ScheduledWorkflow.t()]
  def list_schedules(filters \\ []) do
    durable_name = Keyword.get(filters, :durable, Durable)
    repo = Config.repo(durable_name)
    limit = Keyword.get(filters, :limit, 100)
    offset = Keyword.get(filters, :offset, 0)

    query =
      from(s in ScheduledWorkflow,
        order_by: [asc: s.name],
        limit: ^limit,
        offset: ^offset
      )

    query = apply_filters(query, filters)
    repo.all(query)
  end

  @doc """
  Gets a scheduled workflow by name.

  ## Examples

      {:ok, schedule} = Durable.get_schedule("daily_report")
      {:error, :not_found} = Durable.get_schedule("nonexistent")

  """
  @spec get_schedule(String.t(), keyword()) ::
          {:ok, ScheduledWorkflow.t()} | {:error, :not_found}
  def get_schedule(name, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    repo = Config.repo(durable_name)

    case repo.get_by(ScheduledWorkflow, name: name) do
      nil -> {:error, :not_found}
      schedule -> {:ok, schedule}
    end
  end

  @doc """
  Updates a scheduled workflow.

  ## Updatable Fields

  - `:cron_expression` - New cron expression
  - `:timezone` - New timezone
  - `:input` - New input data
  - `:queue` - New queue
  - `:enabled` - Enable/disable

  ## Examples

      {:ok, schedule} = Durable.update_schedule("daily_report", cron: "0 10 * * *")
      {:ok, schedule} = Durable.update_schedule("daily_report", enabled: false)

  """
  @spec update_schedule(String.t(), keyword()) ::
          {:ok, ScheduledWorkflow.t()} | {:error, term()}
  def update_schedule(name, changes) do
    durable_name = Keyword.get(changes, :durable, Durable)
    repo = Config.repo(durable_name)

    with {:ok, schedule} <- get_schedule(name, durable: durable_name) do
      attrs = build_update_attrs(changes, schedule)

      schedule
      |> ScheduledWorkflow.update_changeset(attrs)
      |> repo.update()
    end
  end

  @doc """
  Deletes a scheduled workflow by name.

  ## Examples

      :ok = Durable.delete_schedule("daily_report")

  """
  @spec delete_schedule(String.t(), keyword()) :: :ok | {:error, :not_found}
  def delete_schedule(name, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    repo = Config.repo(durable_name)

    query = from(s in ScheduledWorkflow, where: s.name == ^name)

    case repo.delete_all(query) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @doc """
  Enables a scheduled workflow.

  ## Examples

      {:ok, schedule} = Durable.enable_schedule("daily_report")

  """
  @spec enable_schedule(String.t(), keyword()) ::
          {:ok, ScheduledWorkflow.t()} | {:error, term()}
  def enable_schedule(name, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    repo = Config.repo(durable_name)

    with {:ok, schedule} <- get_schedule(name, durable: durable_name),
         {:ok, next_run} <- compute_next_run(schedule.cron_expression, schedule.timezone) do
      schedule
      |> ScheduledWorkflow.enable_changeset(true)
      |> Ecto.Changeset.put_change(:next_run_at, next_run)
      |> repo.update()
    end
  end

  @doc """
  Disables a scheduled workflow.

  ## Examples

      {:ok, schedule} = Durable.disable_schedule("daily_report")

  """
  @spec disable_schedule(String.t(), keyword()) ::
          {:ok, ScheduledWorkflow.t()} | {:error, term()}
  def disable_schedule(name, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    repo = Config.repo(durable_name)

    with {:ok, schedule} <- get_schedule(name, durable: durable_name) do
      schedule
      |> ScheduledWorkflow.enable_changeset(false)
      |> repo.update()
    end
  end

  @doc """
  Triggers a scheduled workflow immediately.

  This starts a new workflow execution without waiting for the next scheduled time.
  The schedule's next_run_at is NOT updated.

  ## Options

  - `:input` - Override the schedule's input
  - `:durable` - Durable instance name

  ## Examples

      {:ok, workflow_id} = Durable.trigger_schedule("daily_report")
      {:ok, workflow_id} = Durable.trigger_schedule("daily_report", input: %{force: true})

  """
  @spec trigger_schedule(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def trigger_schedule(name, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)

    with {:ok, schedule} <- get_schedule(name, durable: durable_name) do
      module =
        String.to_existing_atom(
          "Elixir." <> String.trim_leading(schedule.workflow_module, "Elixir.")
        )

      input = Keyword.get(opts, :input, schedule.input)

      Durable.Executor.start_workflow(module, input,
        workflow: schedule.workflow_name,
        queue: String.to_atom(schedule.queue),
        durable: durable_name
      )
    end
  end

  @doc """
  Registers schedules from a module's @schedule attributes.

  This is called automatically during startup for modules listed in
  the `scheduled_modules` config option.

  Uses upsert semantics: updates cron/timezone/input/queue but preserves
  the enabled status and run times for existing schedules.

  ## Examples

      :ok = Durable.Scheduler.API.register(MyApp.DailyReport)

  """
  @spec register(module(), keyword()) :: :ok | {:error, term()}
  def register(module, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)

    if function_exported?(module, :__schedules__, 0) do
      schedules = module.__schedules__()
      register_schedules(module, schedules, durable_name)
    else
      :ok
    end
  end

  @doc """
  Registers schedules from multiple modules.

  ## Examples

      :ok = Durable.Scheduler.API.register_all([MyApp.Reports, MyApp.Cleanup])

  """
  @spec register_all([module()], keyword()) :: :ok | {:error, term()}
  def register_all(modules, opts \\ []) when is_list(modules) do
    Enum.reduce_while(modules, :ok, fn module, :ok ->
      case register(module, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # ============================================================================
  # Internal: Used by Scheduler GenServer
  # ============================================================================

  @doc false
  def get_due_schedules(config) do
    repo = config.repo
    now = DateTime.utc_now()

    from(s in ScheduledWorkflow,
      where: s.enabled == true and s.next_run_at <= ^now,
      lock: "FOR UPDATE SKIP LOCKED"
    )
    |> repo.all()
  end

  @doc false
  def mark_run(schedule, config) do
    repo = config.repo
    now = DateTime.utc_now()

    {:ok, next_run} = compute_next_run(schedule.cron_expression, schedule.timezone)

    schedule
    |> ScheduledWorkflow.run_changeset(now, next_run)
    |> repo.update()
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp resolve_workflow_name(module, opts) do
    cond do
      not Code.ensure_loaded?(module) ->
        return_error("Module #{inspect(module)} is not loaded")

      not function_exported?(module, :__workflows__, 0) ->
        return_error("Module #{inspect(module)} is not a Durable workflow module")

      true ->
        resolve_workflow_from_module(module, Keyword.get(opts, :workflow))
    end
  end

  defp resolve_workflow_from_module(module, nil) do
    case module.__workflows__() do
      [first | _] -> {:ok, first}
      [] -> return_error("Module #{inspect(module)} has no workflows defined")
    end
  end

  defp resolve_workflow_from_module(module, workflow_name) do
    if workflow_name in module.__workflows__() do
      {:ok, workflow_name}
    else
      return_error(
        "Workflow '#{workflow_name}' not found in #{inspect(module)}. " <>
          "Available: #{inspect(module.__workflows__())}"
      )
    end
  end

  defp return_error(message), do: {:error, message}

  defp validate_cron(expression) do
    case CronParser.parse(expression) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:invalid_cron, reason}}
    end
  end

  defp compute_next_run(cron_expression, timezone) do
    with {:ok, cron} <- CronParser.parse(cron_expression),
         {:ok, now} <- get_local_time(timezone) do
      next_local = Scheduler.get_next_run_date!(cron, now)
      local_to_utc(next_local, timezone)
    end
  end

  defp get_local_time("UTC"), do: {:ok, NaiveDateTime.utc_now()}
  defp get_local_time("Etc/UTC"), do: {:ok, NaiveDateTime.utc_now()}

  defp get_local_time(timezone) do
    case DateTime.shift_zone(DateTime.utc_now(), timezone) do
      {:ok, dt} -> {:ok, DateTime.to_naive(dt)}
      {:error, reason} -> {:error, {:timezone_error, timezone, reason}}
    end
  end

  defp local_to_utc(naive_datetime, "UTC") do
    {:ok, DateTime.from_naive!(naive_datetime, "Etc/UTC")}
  end

  defp local_to_utc(naive_datetime, "Etc/UTC") do
    {:ok, DateTime.from_naive!(naive_datetime, "Etc/UTC")}
  end

  defp local_to_utc(naive_datetime, timezone) do
    case DateTime.from_naive(naive_datetime, timezone) do
      {:ok, dt} -> shift_to_utc(dt, timezone)
      {:ambiguous, dt1, _dt2} -> shift_to_utc(dt1, timezone)
      {:gap, dt_before, _dt_after} -> shift_to_utc(dt_before, timezone)
      {:error, reason} -> {:error, {:timezone_error, timezone, reason}}
    end
  end

  defp shift_to_utc(datetime, timezone) do
    case DateTime.shift_zone(datetime, "Etc/UTC") do
      {:ok, utc} -> {:ok, utc}
      {:error, reason} -> {:error, {:timezone_error, timezone, reason}}
    end
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:enabled, enabled}, q when is_boolean(enabled) ->
        from(s in q, where: s.enabled == ^enabled)

      {:workflow_module, module}, q when is_atom(module) ->
        module_str = inspect(module)
        from(s in q, where: s.workflow_module == ^module_str)

      {:queue, queue}, q ->
        queue_str = to_string(queue)
        from(s in q, where: s.queue == ^queue_str)

      _, q ->
        q
    end)
  end

  defp build_update_attrs(changes, schedule) do
    attrs = %{}

    attrs =
      if Keyword.has_key?(changes, :cron_expression) do
        cron = Keyword.get(changes, :cron_expression)
        timezone = Keyword.get(changes, :timezone, schedule.timezone)

        case compute_next_run(cron, timezone) do
          {:ok, next_run} ->
            attrs
            |> Map.put(:cron_expression, cron)
            |> Map.put(:next_run_at, next_run)

          _ ->
            Map.put(attrs, :cron_expression, cron)
        end
      else
        attrs
      end

    attrs =
      if Keyword.has_key?(changes, :timezone) do
        Map.put(attrs, :timezone, Keyword.get(changes, :timezone))
      else
        attrs
      end

    attrs =
      if Keyword.has_key?(changes, :input) do
        Map.put(attrs, :input, Keyword.get(changes, :input))
      else
        attrs
      end

    attrs =
      if Keyword.has_key?(changes, :queue) do
        Map.put(attrs, :queue, to_string(Keyword.get(changes, :queue)))
      else
        attrs
      end

    attrs =
      if Keyword.has_key?(changes, :enabled) do
        Map.put(attrs, :enabled, Keyword.get(changes, :enabled))
      else
        attrs
      end

    attrs
  end

  defp register_schedules(_module, [], _durable_name), do: :ok

  defp register_schedules(module, schedules, durable_name) do
    repo = Config.repo(durable_name)

    Enum.reduce_while(schedules, :ok, fn schedule_def, :ok ->
      case register_single_schedule(module, schedule_def, repo) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp register_single_schedule(module, schedule_def, repo) do
    workflow_name = schedule_def.workflow
    cron = schedule_def.cron
    timezone = schedule_def[:timezone] || "UTC"
    name = schedule_def[:name] || workflow_name

    with :ok <- validate_cron(cron),
         {:ok, next_run} <- compute_next_run(cron, timezone) do
      attrs = %{
        name: name,
        workflow_module: inspect(module),
        workflow_name: workflow_name,
        cron_expression: cron,
        timezone: timezone,
        input: schedule_def[:input] || %{},
        queue: to_string(schedule_def[:queue] || :default),
        next_run_at: next_run
      }

      # Upsert: insert or update (preserving enabled status)
      case repo.get_by(ScheduledWorkflow, name: name) do
        nil ->
          %ScheduledWorkflow{}
          |> ScheduledWorkflow.changeset(Map.put(attrs, :enabled, true))
          |> repo.insert()

        existing ->
          existing
          |> ScheduledWorkflow.upsert_changeset(attrs)
          |> repo.update()
      end
    end
  end
end
