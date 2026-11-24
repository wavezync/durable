defmodule Durable.Scheduler.API do
  @moduledoc """
  CRUD operations for scheduled workflows.

  This module provides functions to create, read, update, and delete
  scheduled workflows that run on cron expressions.

  ## Usage

      # Create a schedule
      Durable.schedule(MyApp.DailyReport, "0 9 * * *", name: "daily_report")

      # List schedules
      {:ok, schedules} = Durable.list_schedules(enabled: true)

      # Update a schedule
      Durable.update_schedule("daily_report", cron: "0 10 * * *")

      # Delete a schedule
      Durable.delete_schedule("daily_report")

  """

  import Ecto.Query

  alias Crontab.CronExpression
  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler
  alias Durable.Config
  alias Durable.Executor
  alias Durable.Query.Opts
  alias Durable.Repo
  alias Durable.Storage.Schemas.ScheduledWorkflow

  require Logger

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
  - `:key` - Workflow key each run starts with, so a fire while the last run
    still holds it follows the workflow's `on_duplicate:` (by default it
    starts nothing). See the workflow keys guide
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
    config = Config.get(durable_name)

    with {:ok, workflow_name} <- resolve_workflow_name(module, opts),
         :ok <- validate_cron(cron_expression),
         {:ok, input} <- Executor.storable_input(Keyword.get(opts, :input, %{})),
         {:ok, next_run} <- compute_next_run(cron_expression, Keyword.get(opts, :timezone, "UTC")) do
      schedule_name = Keyword.get(opts, :name, workflow_name)

      attrs = %{
        name: schedule_name,
        workflow_module: inspect(module),
        workflow_name: workflow_name,
        cron_expression: cron_expression,
        timezone: Keyword.get(opts, :timezone, "UTC"),
        input: input,
        queue: to_string(Keyword.get(opts, :queue, :default)),
        key: Keyword.get(opts, :key),
        enabled: Keyword.get(opts, :enabled, true),
        next_run_at: next_run
      }

      %ScheduledWorkflow{}
      |> ScheduledWorkflow.changeset(attrs)
      |> Repo.insert(config)
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

  A filter of the wrong type is `{:error, {:invalid_option, key}}`, such as a
  negative `:limit` or an `:enabled` that isn't a boolean. See
  `Durable.Query.Opts`.

  ## Examples

      {:ok, schedules} = Durable.list_schedules(enabled: true)
      schedules = Durable.list_schedules!(queue: :reports, limit: 10)

  """
  @spec list_schedules(keyword()) :: {:ok, [ScheduledWorkflow.t()]} | {:error, Opts.reason()}
  def list_schedules(filters \\ []) do
    schema = [
      enabled: :boolean,
      workflow_module: :module,
      queue: :name,
      limit: :non_neg_integer,
      offset: :non_neg_integer
    ]

    with {:ok, filters} <- Opts.validate(filters, schema), do: {:ok, schedules(filters)}
  end

  @doc "Like `list_schedules/1`, but returns the schedules or raises `ArgumentError`."
  @spec list_schedules!(keyword()) :: [ScheduledWorkflow.t()]
  def list_schedules!(filters \\ []), do: filters |> list_schedules() |> Opts.unwrap!(filters)

  defp schedules(filters) do
    durable_name = Keyword.get(filters, :durable, Durable)
    config = Config.get(durable_name)
    limit = Keyword.get(filters, :limit, 100)
    offset = Keyword.get(filters, :offset, 0)

    query =
      from(s in ScheduledWorkflow,
        order_by: [asc: s.name],
        limit: ^limit,
        offset: ^offset
      )

    query = apply_filters(query, filters)
    Repo.all(config, query)
  end

  @doc """
  Gets a scheduled workflow by name.

  ## Examples

      {:ok, schedule} = Durable.get_schedule("daily_report")
      {:error, :not_found} = Durable.get_schedule("nonexistent")
      schedule = Durable.get_schedule!("daily_report")

  """
  @spec get_schedule(String.t(), keyword()) ::
          {:ok, ScheduledWorkflow.t()} | {:error, Opts.reason()}
  def get_schedule(name, opts \\ []) do
    with {:ok, opts} <- Opts.validate(opts),
         config = Config.get(Keyword.get(opts, :durable, Durable)),
         true <- Opts.valid?(:text, name),
         %ScheduledWorkflow{} = schedule <- Repo.get_by(config, ScheduledWorkflow, name: name) do
      {:ok, schedule}
    else
      {:error, _invalid_options} = error -> error
      _not_a_schedule -> {:error, :not_found}
    end
  end

  @doc "Like `get_schedule/2`, but returns the schedule or raises `ArgumentError`."
  @spec get_schedule!(String.t(), keyword()) :: ScheduledWorkflow.t()
  def get_schedule!(name, opts \\ []),
    do: name |> get_schedule(opts) |> Opts.unwrap!(opts, id: name)

  @doc """
  Updates a scheduled workflow.

  ## Updatable Fields

  - `:cron_expression` (or `:cron`) - New cron expression
  - `:timezone` - New timezone
  - `:input` - New input data
  - `:queue` - New queue
  - `:key` - New workflow key (`nil` for none)
  - `:enabled` - Enable/disable

  A new cron or time zone sets the next run from now. A fire that was due
  before the edit, and that the scheduler hasn't started yet, still fires,
  with the edited schedule. A schedule turned back on starts from its next
  time, and doesn't fire the ones it missed.

  ## Examples

      {:ok, schedule} = Durable.update_schedule("daily_report", cron: "0 10 * * *")
      {:ok, schedule} = Durable.update_schedule("daily_report", enabled: false)

  """
  @spec update_schedule(String.t(), keyword()) ::
          {:ok, ScheduledWorkflow.t()} | {:error, term()}
  def update_schedule(name, changes) do
    durable_name = Keyword.get(changes, :durable, Durable)

    changes =
      case Keyword.pop(changes, :cron) do
        {nil, changes} -> changes
        {cron, changes} -> Keyword.put(changes, :cron_expression, cron)
      end

    edit_schedule(name, durable_name, fn schedule ->
      with {:ok, attrs} <- build_update_attrs(changes, schedule),
           do: {:ok, ScheduledWorkflow.update_changeset(schedule, attrs)}
    end)
  end

  # An edit is made to the schedule as it is, under its row's lock, not to a
  # copy read before: two operators editing one schedule at once take turns,
  # and each works out the next run from what the other left. Made to copies,
  # one turning a schedule on and one moving its time left it set for the new
  # time and due at the old one.
  defp edit_schedule(name, durable_name, edit) do
    config = Config.get(durable_name)

    with {:ok, _exists} <- get_schedule(name, durable: durable_name) do
      Repo.transaction(config, fn -> edit_locked(config, name, edit) end)
    end
  end

  defp edit_locked(config, name, edit) do
    locked = from(s in ScheduledWorkflow, where: s.name == ^name, lock: "FOR UPDATE")

    with %ScheduledWorkflow{} = schedule <- Repo.one(config, locked) || {:error, :not_found},
         {:ok, changeset} <- edit.(schedule),
         {:ok, edited} <- Repo.update(changeset, config) do
      edited
    else
      {:error, reason} -> config.repo.rollback(reason)
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
    config = Config.get(durable_name)

    query = from(s in ScheduledWorkflow, where: s.name == ^name)

    case not Repo.bad_text?(name) && Repo.delete_all(config, query) do
      {count, _} when count > 0 -> :ok
      _nothing_deleted -> {:error, :not_found}
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
    edit_schedule(name, Keyword.get(opts, :durable, Durable), fn schedule ->
      with {:ok, next_run} <- compute_next_run(schedule.cron_expression, schedule.timezone) do
        {:ok,
         schedule
         |> ScheduledWorkflow.enable_changeset(true)
         |> Ecto.Changeset.put_change(:next_run_at, next_run)}
      end
    end)
  end

  @doc """
  Disables a scheduled workflow.

  ## Examples

      {:ok, schedule} = Durable.disable_schedule("daily_report")

  """
  @spec disable_schedule(String.t(), keyword()) ::
          {:ok, ScheduledWorkflow.t()} | {:error, term()}
  def disable_schedule(name, opts \\ []) do
    edit_schedule(name, Keyword.get(opts, :durable, Durable), fn schedule ->
      {:ok, ScheduledWorkflow.enable_changeset(schedule, false)}
    end)
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

    with {:ok, schedule} <- get_schedule(name, durable: durable_name),
         {:ok, module} <- parse_module(schedule.workflow_module) do
      input = Keyword.get(opts, :input, schedule.input)

      Durable.Executor.start_workflow(module, input,
        workflow: schedule.workflow_name,
        queue: schedule.queue,
        key: schedule.key,
        durable: durable_name,
        trigger: :schedule,
        trigger_ref: schedule.name
      )
    end
  end

  @doc false
  # A schedule's workflow, if this node has its code: in a rolling deploy, or
  # on a node that runs other queues, it may not.
  @spec parse_module(String.t()) :: {:ok, module()} | {:error, :module_not_found}
  def parse_module(module_string) do
    # Handle both "Elixir.MyModule" and "MyModule" formats
    module_name =
      if String.starts_with?(module_string, "Elixir.") do
        module_string
      else
        "Elixir." <> module_string
      end

    try do
      module = String.to_existing_atom(module_name)
      if Code.ensure_loaded?(module), do: {:ok, module}, else: {:error, :module_not_found}
    rescue
      ArgumentError ->
        {:error, :module_not_found}
    end
  end

  @doc """
  Registers schedules from a module's @schedule attributes.

  This is called automatically during startup for modules listed in
  the `scheduled_modules` config option.

  Uses upsert semantics: updates cron/timezone/input/queue but preserves
  the enabled status for existing schedules. A new cron or time zone takes
  effect now rather than after the old next run has fired.

  ## Examples

      :ok = Durable.Scheduler.API.register(MyApp.DailyReport)

  """
  @spec register(module(), keyword()) :: :ok | {:error, term()}
  def register(module, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)

    register_schedules(module, declared_schedules(module), durable_name)
  end

  defp declared_schedules(module) do
    # Modules are lazy-loaded in dev; `function_exported?/3` returns false
    # for an existing-but-not-yet-loaded module, which would silently skip
    # registration at scheduler boot. Force the load first so the export
    # check is meaningful.
    _ = Code.ensure_loaded(module)

    if function_exported?(module, :__schedules__, 0), do: module.__schedules__(), else: []
  end

  defp schedule_name(schedule_def), do: schedule_def[:name] || schedule_def.workflow

  @doc """
  Registers schedules from multiple modules.

  ## Examples

      :ok = Durable.Scheduler.API.register_all([MyApp.Reports, MyApp.Cleanup])

  """
  @spec register_all([module()], keyword()) :: :ok | {:error, term()}
  def register_all(modules, opts \\ []) when is_list(modules) do
    modules |> Enum.map(&register(&1, opts)) |> first_error()
  end

  # One bad schedule mustn't stop the ones declared after it.
  defp first_error(results), do: Enum.find(results, :ok, &match?({:error, _}, &1))

  @doc """
  Turns off schedules that came from `@schedule` in `modules` and that those
  modules no longer declare. Called at boot, after registering them.

  It only speaks for `modules`, so nodes with different `scheduled_modules` don't
  turn off each other's. Schedules made with `Durable.schedule/3` are left alone,
  and a schedule that's declared again comes back on.
  """
  @spec turn_off_removed([module()], keyword()) :: :ok
  def turn_off_removed(modules, opts \\ []) when is_list(modules) do
    config = Config.get(Keyword.get(opts, :durable, Durable))
    module_names = Enum.map(modules, &inspect/1)

    declared =
      Enum.flat_map(modules, &Enum.map(declared_schedules(&1), fn s -> schedule_name(s) end))

    {_count, names} =
      Repo.update_all(
        config,
        from(s in ScheduledWorkflow,
          where:
            s.source == "code" and s.enabled and s.workflow_module in ^module_names and
              s.name not in ^declared,
          select: s.name
        ),
        set: [enabled: false, source: "removed", updated_at: DateTime.utc_now()]
      )

    report_removed(config, names)
  end

  defp report_removed(_config, []), do: :ok

  defp report_removed(config, names) do
    Logger.warning(
      "[Durable.Scheduler] Turned off schedule(s) no longer declared with @schedule: " <>
        Enum.join(names, ", ")
    )

    Durable.Activity.record(config, "schedule_removed",
      count: length(names),
      details: %{schedules: names}
    )
  end

  # ============================================================================
  # Internal: Used by Scheduler GenServer
  # ============================================================================

  @doc false
  def get_due_schedules(config) do
    now = DateTime.utc_now()

    Repo.all(
      config,
      from(s in ScheduledWorkflow, where: s.enabled == true and s.next_run_at <= ^now)
    )
  end

  @doc false
  # Takes this fire for the calling node. One conditional UPDATE: of the nodes
  # that saw the schedule due, Postgres lets exactly one move its next_run_at,
  # and the others match no row. A false return means another node has it, or
  # an operator changed the schedule since it was read: an edit keeps the fire
  # that was due (`due_or/2`), for the next check to fire as edited.
  @spec claim_fire(ScheduledWorkflow.t(), Config.t()) :: boolean()
  def claim_fire(%ScheduledWorkflow{} = schedule, %Config{} = config) do
    now = DateTime.utc_now()

    {:ok, next_run} =
      compute_next_run(schedule.cron_expression, schedule.timezone, schedule.next_run_at)

    {count, _} =
      Repo.update_all(
        config,
        from(s in as_read(schedule)),
        set: [
          last_run_at: now,
          next_run_at: next_run,
          updated_at: now,
          consecutive_failures: 0,
          last_error: nil,
          last_error_at: nil
        ]
      )

    count == 1
  end

  # The schedule as a tick read it, on and unchanged since.
  defp as_read(schedule) do
    from(s in ScheduledWorkflow,
      where: s.id == ^schedule.id and s.enabled,
      where: s.next_run_at == ^schedule.next_run_at and s.updated_at == ^schedule.updated_at
    )
  end

  @auto_disable_after 5

  @doc false
  # Records that the fire `schedule` was read for failed, and turns the
  # schedule off at its fifth failure in a row. Like `claim_fire/2`, one
  # conditional UPDATE on the fire as it was read: of the nodes that failed it
  # only one counts it, and a schedule an operator changed or turned off
  # meanwhile is left as they made it. The count is the row's own, not the one
  # this node read. Returns the schedule as written, or nil if it wasn't.
  @spec record_failure(ScheduledWorkflow.t(), String.t(), Config.t()) ::
          ScheduledWorkflow.t() | nil
  def record_failure(%ScheduledWorkflow{} = schedule, message, %Config{} = config) do
    now = DateTime.utc_now()
    error = String.slice(to_string(message), 0, 1024)
    next_run = next_run_after_failure(schedule)

    {_count, written} =
      Repo.update_all(
        config,
        from(s in as_read(schedule),
          select: s,
          update: [
            set: [
              last_error: ^error,
              last_error_at: ^now,
              next_run_at: ^next_run,
              updated_at: ^now,
              consecutive_failures: fragment("COALESCE(?, 0) + 1", s.consecutive_failures),
              enabled:
                fragment("COALESCE(?, 0) + 1 < ?", s.consecutive_failures, ^@auto_disable_after),
              auto_disabled_at:
                fragment(
                  "CASE WHEN COALESCE(?, 0) + 1 >= ? THEN ?::timestamp END",
                  s.consecutive_failures,
                  ^@auto_disable_after,
                  ^now
                )
            ]
          ]
        ),
        []
      )

    List.first(written)
  end

  @doc false
  # Where a failed fire goes next: the next run in the schedule's own zone, or
  # 5 minutes from now if that can't be worked out, so it can't fire every check.
  @spec next_run_after_failure(ScheduledWorkflow.t()) :: DateTime.t()
  def next_run_after_failure(%ScheduledWorkflow{} = schedule) do
    case compute_next_run(schedule.cron_expression, schedule.timezone) do
      {:ok, next_run} -> next_run
      _unresolved -> retry_in_five_minutes()
    end
  rescue
    # A cron with no next date raises from `get_next_run_date!/2`.
    _error -> retry_in_five_minutes()
  end

  defp retry_in_five_minutes, do: DateTime.add(DateTime.utc_now(), 300, :second)

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

  # `fired` is the fire being claimed. One claimed late, after the clocks went
  # back, mustn't fire again when the wall clock shows its time a second time:
  # the next comes after the wall time it fired for, as well as after now.
  defp compute_next_run(cron_expression, timezone, fired \\ nil) do
    with {:ok, cron} <- CronParser.parse(cron_expression),
         {:ok, now} <- get_local_time(timezone),
         {:ok, from} <- after_fired(now, fired, timezone) do
      next_fire(cron, from, timezone, DateTime.utc_now())
    end
  end

  defp after_fired(local_now, nil, _timezone), do: {:ok, local_now}

  defp after_fired(local_now, fired, timezone) do
    with {:ok, local} <- zoned(fired, timezone) do
      fired_minute_over = local |> DateTime.to_naive() |> NaiveDateTime.add(60)
      {:ok, Enum.max([local_now, fired_minute_over], NaiveDateTime)}
    end
  end

  defp next_fire(cron, local_now, timezone, _utc_now) when timezone in ["UTC", "Etc/UTC"] do
    with {:ok, next} <- next_date(cron, local_now), do: local_to_utc(next, timezone)
  end

  # A cron for every hour keeps firing through an hour the clocks repeat. The
  # wall clock can't say when that is, so a fire within the hour runs on the
  # offset in force now. One further out (`0 * * * 1` on a Tuesday) may be past
  # a clock change, so it's converted like a fixed hour.
  # ponytail: assumes whole-hour clock changes; a 30-minute one (Lord Howe)
  # fires at the wrong minute once a year.
  defp next_fire(%CronExpression{hour: [:*]} = cron, _local_now, timezone, utc_now) do
    with {:ok, local} <- zoned(utc_now, timezone),
         naive = DateTime.to_naive(local),
         {:ok, next} <- next_date(cron, naive) do
      if NaiveDateTime.diff(next, naive) <= 3_600 do
        offset = local.utc_offset + local.std_offset
        {:ok, next |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-offset, :second) |> usec()}
      else
        at_wall_time(cron, next, timezone, utc_now)
      end
    end
  end

  # A cron at fixed hours fires once. In an hour the clocks repeat, that's the
  # first occurrence still to come; if both have passed, it's the next match.
  defp next_fire(cron, local_now, timezone, utc_now) do
    with {:ok, next} <- next_date(cron, local_now),
         do: at_wall_time(cron, next, timezone, utc_now)
  end

  defp at_wall_time(cron, next, timezone, utc_now) do
    case DateTime.from_naive(next, timezone) do
      {:ambiguous, first, second} ->
        next_of_repeat(cron, next, timezone, utc_now, [first, second])

      _unambiguous ->
        local_to_utc(next, timezone)
    end
  end

  defp next_of_repeat(cron, next, timezone, utc_now, occurrences) do
    case Enum.find(occurrences, &DateTime.after?(&1, utc_now)) do
      nil -> next_fire(cron, NaiveDateTime.add(next, 60), timezone, utc_now)
      upcoming -> shift_to_utc(upcoming, timezone)
    end
  end

  defp zoned(utc, timezone) when timezone in ["UTC", "Etc/UTC"], do: {:ok, utc}

  defp zoned(utc, timezone) do
    case DateTime.shift_zone(utc, timezone) do
      {:ok, _local} = ok -> ok
      {:error, reason} -> {:error, {:timezone_error, timezone, reason}}
    end
  end

  # A valid cron can still never match, like February 31st.
  defp next_date(cron, naive) do
    case Scheduler.get_next_run_date(cron, naive) do
      {:ok, _next} = ok -> ok
      {:error, _reason} -> {:error, {:invalid_cron, :no_next_date}}
    end
  end

  @doc """
  The next `count` times a schedule fires, in UTC, from its cron expression
  and time zone — whether or not it's enabled. Empty for a cron or a time zone
  that can't be worked out.

      {:ok, [~U[2026-10-17 09:00:00.000000Z], ~U[2026-10-18 09:00:00.000000Z], ...]} =
        Durable.Scheduler.API.upcoming_runs(schedule)

      [next | _] = Durable.Scheduler.API.upcoming_runs!(schedule, 3)

  A `count` that isn't a whole number from 0 to 1,000 is
  `{:error, {:invalid_option, :count}}`, and anything but a schedule is
  `{:error, :not_found}`.
  """
  @spec upcoming_runs(ScheduledWorkflow.t(), non_neg_integer()) ::
          {:ok, [DateTime.t()]} | {:error, Opts.reason()}
  def upcoming_runs(schedule, count \\ 5)

  def upcoming_runs(%ScheduledWorkflow{} = schedule, count) do
    if is_integer(count) and count in 0..1_000,
      do: {:ok, next_runs(schedule, count)},
      else: {:error, {:invalid_option, :count}}
  end

  def upcoming_runs(_not_a_schedule, _count), do: {:error, :not_found}

  @doc "Like `upcoming_runs/2`, but returns the times or raises `ArgumentError`."
  @spec upcoming_runs!(ScheduledWorkflow.t(), non_neg_integer()) :: [DateTime.t()]
  def upcoming_runs!(schedule, count \\ 5),
    do: schedule |> upcoming_runs(count) |> Opts.unwrap!([], id: schedule, count: count)

  defp next_runs(schedule, count) do
    with {:ok, cron} <- CronParser.parse(schedule.cron_expression),
         {:ok, now} <- get_local_time(schedule.timezone) do
      cron
      |> Scheduler.get_next_run_dates(now)
      |> Stream.map(&local_to_utc(&1, schedule.timezone))
      |> Stream.flat_map(fn
        {:ok, utc} -> [utc]
        _ -> []
      end)
      |> Enum.take(count)
    else
      _ -> []
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

  # Next-run times go into `:utc_datetime_usec` columns, some through
  # `put_change` (no cast), so they must carry microsecond precision — cron
  # math returns whole seconds.
  defp local_to_utc(naive_datetime, "UTC") do
    {:ok, naive_datetime |> DateTime.from_naive!("Etc/UTC") |> usec()}
  end

  defp local_to_utc(naive_datetime, "Etc/UTC") do
    {:ok, naive_datetime |> DateTime.from_naive!("Etc/UTC") |> usec()}
  end

  defp local_to_utc(naive_datetime, timezone) do
    case DateTime.from_naive(naive_datetime, timezone) do
      {:ok, dt} -> shift_to_utc(dt, timezone)
      {:ambiguous, dt1, _dt2} -> shift_to_utc(dt1, timezone)
      {:gap, dt_before, _dt_after} -> shift_to_utc(dt_before, timezone)
      {:error, reason} -> {:error, {:timezone_error, timezone, reason}}
    end
  end

  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp shift_to_utc(datetime, timezone) do
    case DateTime.shift_zone(datetime, "Etc/UTC") do
      {:ok, utc} -> {:ok, usec(utc)}
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
    with {:ok, timing} <- updated_timing(changes, schedule),
         {:ok, input} <- updated_input(changes) do
      {:ok, Enum.reduce([timing, input, plain_updates(changes)], &Map.merge/2)}
    end
  end

  # A schedule turned back on starts from its next time, as with
  # enable_schedule/2: the one it had may have gone by while it was off.
  defp updated_timing(changes, schedule) do
    turned_on? = changes[:enabled] == true and not schedule.enabled

    if turned_on? or Keyword.has_key?(changes, :cron_expression) or
         Keyword.has_key?(changes, :timezone) do
      cron = Keyword.get(changes, :cron_expression, schedule.cron_expression)
      timezone = Keyword.get(changes, :timezone, schedule.timezone)

      # Turned on, it doesn't fire the times it missed while off.
      kept = if turned_on?, do: %{schedule | enabled: false}, else: schedule

      with {:ok, next_run} <- compute_next_run(cron, timezone) do
        {:ok, %{cron_expression: cron, timezone: timezone, next_run_at: due_or(kept, next_run)}}
      end
    else
      {:ok, %{}}
    end
  end

  # A new time for a schedule that's on doesn't drop the fire it has due now,
  # which the next check hasn't come to yet. That fire goes with what the edit
  # set, and the one after it by the new time.
  defp due_or(%{enabled: true, next_run_at: %DateTime{} = due}, next_run) do
    if DateTime.after?(due, DateTime.utc_now()), do: next_run, else: due
  end

  defp due_or(_schedule, next_run), do: next_run

  defp updated_input(changes) do
    case Keyword.fetch(changes, :input) do
      {:ok, input} ->
        with {:ok, safe} <- Executor.storable_input(input), do: {:ok, %{input: safe}}

      :error ->
        {:ok, %{}}
    end
  end

  defp plain_updates(changes) do
    changes
    |> Keyword.take([:queue, :key, :enabled])
    |> Map.new(fn
      {:queue, queue} -> {:queue, to_string(queue)}
      other -> other
    end)
    |> clear_failures_if_enabled()
  end

  defp clear_failures_if_enabled(%{enabled: true} = attrs),
    do: Map.merge(attrs, ScheduledWorkflow.cleared_failures())

  defp clear_failures_if_enabled(attrs), do: attrs

  defp register_schedules(_module, [], _durable_name), do: :ok

  defp register_schedules(module, schedules, durable_name) do
    config = Config.get(durable_name)

    schedules
    |> Enum.map(&register_single_schedule(module, &1, config))
    |> first_error()
  end

  defp register_single_schedule(module, schedule_def, config) do
    workflow_name = schedule_def.workflow
    cron = schedule_def.cron
    timezone = schedule_def[:timezone] || "UTC"
    name = schedule_name(schedule_def)

    with :ok <- validate_cron(cron),
         {:ok, input} <- Executor.storable_input(schedule_def[:input] || %{}),
         {:ok, next_run} <- compute_next_run(cron, timezone) do
      attrs = %{
        name: name,
        workflow_module: inspect(module),
        workflow_name: workflow_name,
        cron_expression: cron,
        timezone: timezone,
        input: input,
        queue: to_string(schedule_def[:queue] || :default),
        key: schedule_def[:key],
        source: "code",
        next_run_at: next_run
      }

      # Upsert: insert or update (preserving enabled status)
      case Repo.get_by(config, ScheduledWorkflow, name: name) do
        nil ->
          %ScheduledWorkflow{}
          |> ScheduledWorkflow.changeset(Map.put(attrs, :enabled, true))
          |> Repo.insert(config)

        existing ->
          existing
          |> ScheduledWorkflow.upsert_changeset(upsert_attrs(existing, attrs))
          |> Repo.update(config)
      end
    end
  end

  # The next run only changes if when it should run has.
  defp upsert_attrs(existing, attrs) do
    cond do
      existing.source == "removed" ->
        Map.put(attrs, :enabled, true)

      existing.cron_expression != attrs.cron_expression or existing.timezone != attrs.timezone ->
        %{attrs | next_run_at: due_or(existing, attrs.next_run_at)}

      true ->
        Map.delete(attrs, :next_run_at)
    end
  end
end
