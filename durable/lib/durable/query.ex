defmodule Durable.Query do
  @moduledoc """
  Query functions for workflow executions.

  Every function returns `{:ok, result}` or `{:error, reason}`, and has a twin
  ending in `!` that returns the result or raises `ArgumentError`:

      {:ok, runs} = Durable.Query.list_executions(status: :failed)
      runs = Durable.Query.list_executions!(status: :failed)

  A wrong option is `{:error, {:invalid_option, key}}` and an id that names
  nothing is `{:error, :not_found}`. `Durable.Query.Opts` has the whole
  contract.
  """

  import Ecto.Query

  alias Durable.Config
  alias Durable.Query.Opts
  alias Durable.Repo
  alias Durable.Storage.Schemas.{ActivityEvent, StepExecution, WorkflowExecution}

  @run_statuses Ecto.Enum.values(WorkflowExecution, :status)

  # What each filter of the run listings has to be (Durable.Query.Opts).
  @execution_filters [
    workflow: :module,
    workflow_name: :text,
    status: {:one_or_more_of, @run_statuses},
    queue: :name,
    current_step: :text,
    trigger: {:one_of, Ecto.Enum.values(WorkflowExecution, :trigger)},
    trigger_ref: :text,
    error_contains: :text,
    key: :text,
    tag: :text,
    input: :input,
    id: :uuid,
    parent_workflow_id: :uuid,
    id_prefix: :text,
    from: :datetime,
    to: :datetime,
    top_level_only: :boolean,
    limit: :non_neg_integer,
    offset: :non_neg_integer
  ]

  @key_filters [
    workflow_name: :text,
    key_prefix: :text,
    holder_status: {:one_or_more_of, @run_statuses},
    limit: :non_neg_integer,
    offset: :non_neg_integer
  ]

  @doc """
  Gets a workflow execution by ID.

  ## Options

  - `:include_steps` - Include step executions (default: false)
  - `:include_logs` - Include logs in step executions (default: false)
  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      {:ok, run} = Durable.Query.get_execution(workflow_id, include_steps: true)
      {:error, :not_found} = Durable.Query.get_execution("no-such-run")
      run = Durable.Query.get_execution!(workflow_id)

  """
  @spec get_execution(String.t(), keyword()) :: {:ok, map()} | {:error, Opts.reason()}
  def get_execution(workflow_id, opts \\ []) do
    with {:ok, opts} <- Opts.validate(opts, include_steps: :boolean, include_logs: :boolean),
         :ok <- Opts.id(workflow_id),
         do: fetch_execution(workflow_id, opts)
  end

  @doc "Like `get_execution/2`, but returns the run or raises `ArgumentError`."
  @spec get_execution!(String.t(), keyword()) :: map()
  def get_execution!(workflow_id, opts \\ []),
    do: workflow_id |> get_execution(opts) |> Opts.unwrap!(opts, id: workflow_id)

  defp fetch_execution(workflow_id, opts) do
    config = get_config(opts)
    include_steps = Keyword.get(opts, :include_steps, false)
    include_logs = Keyword.get(opts, :include_logs, false)

    query = from(w in WorkflowExecution, where: w.id == ^workflow_id)

    query =
      if include_steps do
        from(w in query, preload: [:step_executions])
      else
        query
      end

    case Repo.one(config, query) do
      %WorkflowExecution{} = execution ->
        {:ok, execution_to_map(execution, include_steps, include_logs)}

      _not_a_run ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists workflow executions with optional filters.

  ## Filters

  - `:workflow` - Filter by workflow module
  - `:workflow_name` - Filter by workflow name
  - `:status` - Filter by status
  - `:queue` - Filter by queue
  - `:current_step` - Runs currently at (or that stopped at) this step
  - `:trigger` - What started the run: `:api`, `:schedule`, `:parent` or `:rerun`
  - `:trigger_ref` - What it points at: a schedule's name, or the run a rerun copied
  - `:error_contains` - Case-insensitive text anywhere in the run's error
  - `:key` - Runs started with this workflow key (the holder has `holds_key: true`)
  - `:tag` - Runs started with this tag (`Durable.start(..., tags: [...])`)
  - `:input` - Map of dotted input paths to exact values, e.g.
    `%{"order_id" => "ORD-1042"}`
  - `:id`, `:parent_workflow_id` - One run, or the children of one
  - `:id_prefix` - Runs whose id starts with this text
  - `:from`, `:to` - Runs started in this window (`DateTime`)
  - `:top_level_only` - Leave out child runs
  - `:limit` - Maximum results (default: 50)
  - `:offset` - Offset for pagination (default: 0)
  - `:durable` - The Durable instance name (default: Durable)

  A filter of the wrong type is `{:error, {:invalid_option, key}}`: a negative
  `:limit`, a status no run has, a `:workflow` that isn't a module.

  ## Examples

      {:ok, runs} = Durable.Query.list_executions(status: [:failed, :cancelled], limit: 20)
      {:error, {:invalid_option, :limit}} = Durable.Query.list_executions(limit: -1)
      runs = Durable.Query.list_executions!(tag: "account:7")

  """
  @spec list_executions(keyword()) :: {:ok, [map()]} | {:error, Opts.reason()}
  def list_executions(filters \\ []) do
    with {:ok, filters} <- Opts.validate(filters, @execution_filters) do
      query =
        from(w in WorkflowExecution,
          order_by: [desc: w.inserted_at],
          limit: ^Keyword.get(filters, :limit, 50),
          offset: ^Keyword.get(filters, :offset, 0)
        )

      rows = filters |> get_config() |> Repo.all(apply_filters(query, filters))
      {:ok, Enum.map(rows, &execution_to_map(&1, false, false))}
    end
  end

  @doc "Like `list_executions/1`, but returns the runs or raises `ArgumentError`."
  @spec list_executions!(keyword()) :: [map()]
  def list_executions!(filters \\ []),
    do: filters |> list_executions() |> Opts.unwrap!(filters)

  @doc """
  Workflow keys: one row per workflow and key that a run was started with,
  most recently started first.

      [%{workflow_module: "Elixir.MyApp.ProcessArticle", workflow_name: "process_article",
         key: "article:42", runs: 2, last_started_at: ~U[...],
         holder_id: "3f2a91c4-…", holder_status: :running,   # nil when no run holds it
         readded: 3, dropped: 1, last_readded_at: ~U[...]}]  # in the last 24 hours

  ## Filters

  - `:workflow_name` - One workflow
  - `:key_prefix` - Keys that start with this text
  - `:holder_status` - Status or statuses of the run holding the key
  - `:limit` (default 50), `:offset`
  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      {:ok, keys} = Durable.Query.list_keys(key_prefix: "article:")
      keys = Durable.Query.list_keys!(holder_status: :running)
  """
  @spec list_keys(keyword()) :: {:ok, [map()]} | {:error, Opts.reason()}
  def list_keys(filters \\ []) do
    with {:ok, filters} <- Opts.validate(filters, @key_filters), do: {:ok, keys(filters)}
  end

  @doc "Like `list_keys/1`, but returns the keys or raises `ArgumentError`."
  @spec list_keys!(keyword()) :: [map()]
  def list_keys!(filters \\ []), do: filters |> list_keys() |> Opts.unwrap!(filters)

  defp keys(filters) do
    config = get_config(filters)

    rows =
      Repo.all(
        config,
        from(w in keys_query(filters),
          order_by: [desc: max(w.inserted_at)],
          limit: ^Keyword.get(filters, :limit, 50),
          offset: ^Keyword.get(filters, :offset, 0),
          select: %{
            workflow_module: w.workflow_module,
            workflow_name: w.workflow_name,
            key: w.key,
            runs: count(w.id),
            last_started_at: max(w.inserted_at),
            holder_id: fragment("(array_agg(?::text) FILTER (WHERE ?))[1]", w.id, w.holds_key),
            holder_status: fragment("(array_agg(?) FILTER (WHERE ?))[1]", w.status, w.holds_key)
          }
        )
      )

    activity = key_activity(config, rows)

    Enum.map(rows, fn row ->
      row
      |> Map.update!(:holder_status, &(&1 && String.to_existing_atom(&1)))
      |> Map.merge(
        Map.get(activity, {row.workflow_name, row.key}, %{
          readded: 0,
          dropped: 0,
          last_readded_at: nil
        })
      )
    end)
  end

  @doc """
  Counts the keys `list_keys/1` would list, ignoring `:limit` and `:offset`.

      {:ok, 12} = Durable.Query.count_keys(workflow_name: "process_article")
      12 = Durable.Query.count_keys!(workflow_name: "process_article")
  """
  @spec count_keys(keyword()) :: {:ok, non_neg_integer()} | {:error, Opts.reason()}
  def count_keys(filters \\ []) do
    with {:ok, filters} <- Opts.validate(filters, @key_filters) do
      keys = from(w in keys_query(filters), select: %{key: w.key})
      {:ok, filters |> get_config() |> Repo.one(from(k in subquery(keys), select: count()))}
    end
  end

  @doc "Like `count_keys/1`, but returns the count or raises `ArgumentError`."
  @spec count_keys!(keyword()) :: non_neg_integer()
  def count_keys!(filters \\ []), do: filters |> count_keys() |> Opts.unwrap!(filters)

  defp keys_query(filters) do
    query =
      from(w in WorkflowExecution,
        where: not is_nil(w.key),
        group_by: [w.workflow_module, w.workflow_name, w.key]
      )

    filters = if bad_filter?(filters), do: [nothing: true], else: filters

    Enum.reduce(filters, query, fn
      {:nothing, true}, q ->
        from(w in q, where: false)

      {:workflow_name, name}, q when is_binary(name) and name != "" ->
        from(w in q, where: w.workflow_name == ^name)

      {:key_prefix, prefix}, q when is_binary(prefix) and prefix != "" ->
        from(w in q, where: like(w.key, ^(escape_like(prefix) <> "%")))

      {:holder_status, status}, q when not is_nil(status) ->
        statuses = status |> List.wrap() |> Enum.map(&to_string/1)

        from(w in q,
          having:
            fragment(
              "(array_agg(?) FILTER (WHERE ?))[1] = ANY(?)",
              w.status,
              w.holds_key,
              ^statuses
            )
        )

      _, q ->
        q
    end)
  end

  # Re-adds in the last 24 hours, per workflow name and key, from Activity.
  defp key_activity(_config, []), do: %{}

  defp key_activity(config, rows) do
    keys = rows |> Enum.map(& &1.key) |> Enum.uniq()
    since = DateTime.add(DateTime.utc_now(), -86_400, :second)

    Repo.all(
      config,
      from(a in ActivityEvent,
        where: a.kind == "key_duplicate" and a.at >= ^since,
        where: fragment("?->>'key' = ANY(?)", a.details, ^keys),
        group_by: [fragment("?->>'workflow'", a.details), fragment("?->>'key'", a.details)],
        select: {
          fragment("?->>'workflow'", a.details),
          fragment("?->>'key'", a.details),
          count(a.id),
          fragment(
            "count(*) FILTER (WHERE ?->>'outcome' = 'use_existing' AND (?->>'input_changed')::boolean)",
            a.details,
            a.details
          ),
          max(a.at)
        }
      )
    )
    |> Map.new(fn {workflow, key, readded, dropped, last} ->
      {{workflow, key}, %{readded: readded, dropped: dropped, last_readded_at: last}}
    end)
  end

  @doc """
  Counts workflow executions matching filters, the filters of
  `list_executions/1`.

      {:ok, 3} = Durable.Query.count_executions(status: :failed)
      3 = Durable.Query.count_executions!(status: :failed)
  """
  @spec count_executions(keyword()) :: {:ok, non_neg_integer()} | {:error, Opts.reason()}
  def count_executions(filters \\ []) do
    with {:ok, filters} <- Opts.validate(filters, @execution_filters) do
      query = from(w in WorkflowExecution, select: count(w.id))
      {:ok, filters |> get_config() |> Repo.one(apply_filters(query, filters))}
    end
  end

  @doc "Like `count_executions/1`, but returns the count or raises `ArgumentError`."
  @spec count_executions!(keyword()) :: non_neg_integer()
  def count_executions!(filters \\ []),
    do: filters |> count_executions() |> Opts.unwrap!(filters)

  @doc """
  Counts runs per status, applying every filter except `:status` — what a
  "Failed (12) · Running (3)" view switcher needs in one query.

      {:ok, %{failed: 12, running: 3}} = Durable.Query.count_by_status(queue: :default)
      %{failed: 12, running: 3} = Durable.Query.count_by_status!(queue: :default)
  """
  @spec count_by_status(keyword()) ::
          {:ok, %{atom() => non_neg_integer()}} | {:error, Opts.reason()}
  def count_by_status(filters \\ []) do
    with {:ok, filters} <- Opts.validate(filters, @execution_filters) do
      query =
        from(w in WorkflowExecution, group_by: w.status, select: {w.status, count(w.id)})
        |> apply_filters(Keyword.delete(filters, :status))

      {:ok, filters |> get_config() |> Repo.all(query) |> Map.new()}
    end
  end

  @doc "Like `count_by_status/1`, but returns the counts or raises `ArgumentError`."
  @spec count_by_status!(keyword()) :: %{atom() => non_neg_integer()}
  def count_by_status!(filters \\ []),
    do: filters |> count_by_status() |> Opts.unwrap!(filters)

  @doc """
  Gets step executions for a workflow, oldest first.

      {:ok, steps} = Durable.Query.get_step_executions(workflow_id)
      {:error, :not_found} = Durable.Query.get_step_executions("no-such-run")
      steps = Durable.Query.get_step_executions!(workflow_id)
  """
  @spec get_step_executions(String.t(), keyword()) :: {:ok, [map()]} | {:error, Opts.reason()}
  def get_step_executions(workflow_id, opts \\ []) do
    with {:ok, opts} <- Opts.validate(opts), :ok <- Opts.id(workflow_id) do
      query =
        from(s in StepExecution,
          where: s.workflow_id == ^workflow_id,
          order_by: [asc: s.inserted_at]
        )

      config = get_config(opts)
      config |> Repo.all(query) |> Enum.map(&step_to_map/1) |> of_run(config, workflow_id)
    end
  end

  @doc "Like `get_step_executions/2`, but returns the steps or raises `ArgumentError`."
  @spec get_step_executions!(String.t(), keyword()) :: [map()]
  def get_step_executions!(workflow_id, opts \\ []),
    do: workflow_id |> get_step_executions(opts) |> Opts.unwrap!(opts, id: workflow_id)

  # Rows that belong to a run. With none, the run itself is looked for: an id
  # that names no run is not found, rather than a run with nothing to list.
  defp of_run([], config, workflow_id) do
    if Repo.one(config, from(w in WorkflowExecution, where: w.id == ^workflow_id, select: true)),
      do: {:ok, []},
      else: {:error, :not_found}
  end

  defp of_run(rows, _config, _workflow_id), do: {:ok, rows}

  @doc """
  Gets logs for a specific step, from its latest attempt.

      {:ok, logs} = Durable.Query.get_step_logs(workflow_id, :charge)
      {:error, :not_found} = Durable.Query.get_step_logs(workflow_id, :no_such_step)
      logs = Durable.Query.get_step_logs!(workflow_id, :charge)
  """
  @spec get_step_logs(String.t(), atom() | String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Opts.reason()}
  def get_step_logs(workflow_id, step_name, opts \\ []) do
    with {:ok, opts} <- Opts.validate(opts),
         :ok <- Opts.id(workflow_id),
         true <- Opts.valid?(:name, step_name) || {:error, :not_found} do
      query =
        from(s in StepExecution,
          where: s.workflow_id == ^workflow_id and s.step_name == ^to_string(step_name),
          order_by: [desc: s.attempt],
          limit: 1
        )

      case opts |> get_config() |> Repo.one(query) do
        %StepExecution{} = step -> {:ok, step.logs || []}
        _no_such_step -> {:error, :not_found}
      end
    end
  end

  @doc "Like `get_step_logs/3`, but returns the logs or raises `ArgumentError`."
  @spec get_step_logs!(String.t(), atom() | String.t(), keyword()) :: [map()]
  def get_step_logs!(workflow_id, step_name, opts \\ []) do
    workflow_id
    |> get_step_logs(step_name, opts)
    |> Opts.unwrap!(opts, id: {workflow_id, step_name})
  end

  @doc """
  Lists child workflow executions for a parent workflow.

  ## Options

  - `:status` - Filter by status
  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      {:ok, children} = Durable.Query.list_child_executions(parent_id, status: :running)
      {:error, :not_found} = Durable.Query.list_child_executions("no-such-run")
      children = Durable.Query.list_child_executions!(parent_id)

  """
  @spec list_child_executions(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Opts.reason()}
  def list_child_executions(parent_workflow_id, opts \\ []) do
    with {:ok, opts} <- Opts.validate(opts, status: {:one_of, @run_statuses}),
         :ok <- Opts.id(parent_workflow_id) do
      parent_workflow_id |> children_of(opts) |> of_run(get_config(opts), parent_workflow_id)
    end
  end

  @doc "Like `list_child_executions/2`, but returns the runs or raises `ArgumentError`."
  @spec list_child_executions!(String.t(), keyword()) :: [map()]
  def list_child_executions!(parent_workflow_id, opts \\ []) do
    parent_workflow_id
    |> list_child_executions(opts)
    |> Opts.unwrap!(opts, id: parent_workflow_id)
  end

  defp children_of(parent_workflow_id, opts) do
    config = get_config(opts)

    query =
      from(w in WorkflowExecution,
        where: w.parent_workflow_id == ^parent_workflow_id,
        order_by: [asc: w.inserted_at]
      )

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(w in query, where: w.status == ^status)
      end

    Repo.all(config, query)
    |> Enum.map(&execution_to_map(&1, false, false))
  end

  @doc """
  Returns a `%{parent_workflow_id => child_count}` map for the given parent
  ids, in a single query. Used to render a "N children" drill-down affordance
  on top-level run rows without an N+1. Parents with no children are omitted.

  ## Options

  - `:durable` - The Durable instance name (default: Durable)

  Anything but a list of run ids is `{:error, {:invalid_option, :parent_ids}}`.

  ## Examples

      {:ok, %{^parent_id => 3}} = Durable.Query.child_counts([parent_id, other_id])
      %{^parent_id => 3} = Durable.Query.child_counts!([parent_id, other_id])
  """
  @spec child_counts([String.t()], keyword()) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, Opts.reason()}
  def child_counts(parent_ids, opts \\ []) do
    with {:ok, opts} <- Opts.validate(opts),
         true <- Opts.valid?(:uuids, parent_ids) || {:error, {:invalid_option, :parent_ids}} do
      {:ok, count_children(parent_ids, opts)}
    end
  end

  @doc "Like `child_counts/2`, but returns the counts or raises `ArgumentError`."
  @spec child_counts!([String.t()], keyword()) :: %{String.t() => non_neg_integer()}
  def child_counts!(parent_ids, opts \\ []),
    do: parent_ids |> child_counts(opts) |> Opts.unwrap!(opts, parent_ids: parent_ids)

  defp count_children([], _opts), do: %{}

  defp count_children(parent_ids, opts) do
    config = get_config(opts)

    from(w in WorkflowExecution,
      where: w.parent_workflow_id in ^parent_ids,
      group_by: w.parent_workflow_id,
      select: {w.parent_workflow_id, count(w.id)}
    )
    |> then(&Repo.all(config, &1))
    |> Map.new()
  end

  @doc """
  Returns workflow execution counts grouped by status.

  Returns a map like `%{pending: 5, running: 3, completed: 100, ...}`.

  ## Options

  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      {:ok, %{running: 3, completed: 100}} = Durable.Query.dashboard_counts()
      %{running: 3, completed: 100} = Durable.Query.dashboard_counts!()

  """
  @spec dashboard_counts(keyword()) ::
          {:ok, %{atom() => non_neg_integer()}} | {:error, Opts.reason()}
  def dashboard_counts(opts \\ []) do
    with {:ok, opts} <- Opts.validate(opts) do
      query =
        from(w in WorkflowExecution,
          group_by: w.status,
          select: {w.status, count(w.id)}
        )

      {:ok, opts |> get_config() |> Repo.all(query) |> Map.new()}
    end
  end

  @doc "Like `dashboard_counts/1`, but returns the counts or raises `ArgumentError`."
  @spec dashboard_counts!(keyword()) :: %{atom() => non_neg_integer()}
  def dashboard_counts!(opts \\ []), do: opts |> dashboard_counts() |> Opts.unwrap!(opts)

  @doc """
  Lists distinct workflow definitions, derived from execution history.

  Returns one row per `{workflow_module, workflow_name}` pair that has
  ever been executed, with aggregate stats. There is no compile-time
  registry of definitions in the engine — the executor only resolves
  modules by name on demand — so the dashboard derives the catalog from
  the persisted executions.

  Each row contains:
    * `:workflow_module` (string)
    * `:workflow_name` (string)
    * `:total_runs` (non_neg_integer)
    * `:running_count` (non_neg_integer)
    * `:waiting_count` (non_neg_integer)
    * `:failed_count` (non_neg_integer)
    * `:last_run_at` (DateTime.t() | nil) — most recent inserted_at
    * `:last_status` (atom | nil) — status of the most recent run

  Sorted by `last_run_at DESC NULLS LAST`.

  ## Options

  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      {:ok, workflows} = Durable.Query.list_workflows()
      workflows = Durable.Query.list_workflows!()
  """
  @spec list_workflows(keyword()) :: {:ok, [map()]} | {:error, Opts.reason()}
  def list_workflows(opts \\ []) do
    with {:ok, opts} <- Opts.validate(opts), do: {:ok, workflows(opts)}
  end

  @doc "Like `list_workflows/1`, but returns the workflows or raises `ArgumentError`."
  @spec list_workflows!(keyword()) :: [map()]
  def list_workflows!(opts \\ []), do: opts |> list_workflows() |> Opts.unwrap!(opts)

  defp workflows(opts) do
    config = get_config(opts)

    # Two queries instead of a window function:
    #   1. Aggregate counts + max(inserted_at) per (module, name)
    #   2. The status of the row that matched max(inserted_at) per pair
    # Joining a window function would be cleaner but Ecto's window API
    # is awkward and the row count here is "number of distinct
    # workflows in this app" — typically tens, not millions.
    aggregate_query =
      from(w in WorkflowExecution,
        # Top-level runs only. Parallel/`each`/`call_workflow` children
        # inherit the parent's (module, name), so counting them here would
        # inflate total_runs and the status counts by the fan-out width and
        # could drive last_status off a child row.
        where: is_nil(w.parent_workflow_id),
        group_by: [w.workflow_module, w.workflow_name],
        select: %{
          workflow_module: w.workflow_module,
          workflow_name: w.workflow_name,
          total_runs: count(w.id),
          running_count: fragment("count(*) FILTER (WHERE ? = 'running')", w.status),
          waiting_count: fragment("count(*) FILTER (WHERE ? = 'waiting')", w.status),
          failed_count: fragment("count(*) FILTER (WHERE ? = 'failed')", w.status),
          last_run_at: max(w.inserted_at)
        }
      )

    aggregates = Repo.all(config, aggregate_query)

    aggregates
    |> Enum.map(&attach_last_status(config, &1))
    |> sort_by_last_run_desc()
  end

  defp sort_by_last_run_desc(rows) do
    {with_dates, without} = Enum.split_with(rows, &(not is_nil(&1.last_run_at)))
    Enum.sort_by(with_dates, & &1.last_run_at, {:desc, DateTime}) ++ without
  end

  defp attach_last_status(_config, %{last_run_at: nil} = row) do
    Map.put(row, :last_status, nil)
  end

  defp attach_last_status(config, row) do
    query =
      from(w in WorkflowExecution,
        where:
          is_nil(w.parent_workflow_id) and
            w.workflow_module == ^row.workflow_module and
            w.workflow_name == ^row.workflow_name and
            w.inserted_at == ^row.last_run_at,
        select: w.status,
        limit: 1
      )

    last_status = Repo.one(config, query)
    Map.put(row, :last_status, last_status)
  end

  @doc """
  Lists workflow executions with total count for pagination.

  Returns `{:ok, {executions, total_count}}`.

  Accepts the same filters as `list_executions/1`.

      {:ok, {runs, total}} = Durable.Query.list_executions_with_total(limit: 25, offset: 50)
      {runs, total} = Durable.Query.list_executions_with_total!(limit: 25, offset: 50)
  """
  @spec list_executions_with_total(keyword()) ::
          {:ok, {[map()], non_neg_integer()}} | {:error, Opts.reason()}
  def list_executions_with_total(filters \\ []) do
    with {:ok, filters} <- Opts.validate(filters, @execution_filters),
         do: {:ok, executions_with_total(filters)}
  end

  @doc "Like `list_executions_with_total/1`, but returns the pair or raises `ArgumentError`."
  @spec list_executions_with_total!(keyword()) :: {[map()], non_neg_integer()}
  def list_executions_with_total!(filters \\ []),
    do: filters |> list_executions_with_total() |> Opts.unwrap!(filters)

  defp executions_with_total(filters) do
    config = get_config(filters)
    limit = Keyword.get(filters, :limit, 50)
    offset = Keyword.get(filters, :offset, 0)

    base_query =
      from(w in WorkflowExecution,
        order_by: [desc: w.inserted_at]
      )

    base_query = apply_filters(base_query, filters)

    list_query = from(w in base_query, limit: ^limit, offset: ^offset)

    # The count query mustn't inherit `order_by` — Postgres rejects ORDER BY
    # against a column that isn't in GROUP BY when the SELECT is an aggregate
    # (`SELECT count(id) FROM ... ORDER BY inserted_at` raises 42803). Strip
    # it from the base query before adding the aggregate.
    total_query =
      base_query
      |> exclude(:order_by)
      |> select([w], count(w.id))

    workflows =
      Repo.all(config, list_query)
      |> Enum.map(&execution_to_map(&1, false, false))

    total = Repo.one(config, total_query)

    {workflows, total}
  end

  # Private functions

  defp get_config(opts) do
    durable_name = Keyword.get(opts, :durable, Durable)
    Config.get(durable_name)
  end

  @doc false
  # The runs matching `filters`, as a query, for callers that act on them
  # (Durable.cancel_all/2).
  @spec executions_query(keyword()) :: Ecto.Query.t()
  def executions_query(filters), do: apply_filters(from(w in WorkflowExecution), filters)

  # A value Postgres can't hold can't match a run.
  defp apply_filters(query, filters) do
    # A nil value is a filter that wasn't set.
    filters = Enum.reject(filters, fn {_name, value} -> is_nil(value) end)

    if bad_filter?(filters) or Enum.any?(filters, &unmatchable?/1),
      do: from(w in query, where: false),
      else: reduce_filters(query, filters)
  end

  @statuses Ecto.Enum.values(WorkflowExecution, :status)

  # Not an id or a status, so no run has it. Compared anyway, it's a cast error.
  defp unmatchable?({name, id}) when name in [:id, :parent_workflow_id],
    do: is_binary(id) and id != "" and not Repo.id?(id)

  defp unmatchable?({:status, status}), do: is_atom(status) and status not in @statuses
  defp unmatchable?(_filter), do: false

  defp bad_filter?(filters) do
    Enum.any?(filters, fn
      {:input, fields} when is_map(fields) -> Enum.any?(fields, &bad_input_field?/1)
      {_name, value} -> Repo.bad_text?(value)
    end)
  end

  defp bad_input_field?({path, value}), do: not comparable?(path) or not comparable?(value)

  defp comparable?(value) when is_binary(value) or is_atom(value),
    do: not Repo.bad_text?(value)

  defp comparable?(value), do: is_number(value)

  defp reduce_filters(query, filters) do
    Enum.reduce(filters, query, fn
      # Runs store Atom.to_string(module) ("Elixir.MyApp.Orders"); accept the
      # inspect/1 form too.
      {:workflow, module}, q when is_atom(module) ->
        names = [Atom.to_string(module), inspect(module)]
        from(w in q, where: w.workflow_module in ^names)

      {:workflow_name, name}, q ->
        from(w in q, where: w.workflow_name == ^name)

      # Top-level runs only — exclude parallel/`each`/`call_workflow` children
      # (which carry a non-nil parent_workflow_id and inherit the parent's
      # workflow_name verbatim). Without this, run lists are flooded with
      # indistinguishable child rows and per-definition counts are inflated by
      # the fan-out width. Lists default to this; the detail page's Family tab
      # and the per-parent drill-down surface the children.
      {:top_level_only, true}, q ->
        from(w in q, where: is_nil(w.parent_workflow_id))

      # Drill-down: only the children of a specific parent execution.
      {:parent_workflow_id, parent_id}, q when is_binary(parent_id) ->
        from(w in q, where: w.parent_workflow_id == ^parent_id)

      # Exact execution id.
      {:id, id}, q when is_binary(id) and id != "" ->
        from(w in q, where: w.id == ^id)

      {:status, status}, q when is_atom(status) ->
        from(w in q, where: w.status == ^status)

      {:status, statuses}, q when is_list(statuses) and statuses != [] ->
        from(w in q, where: w.status in ^statuses)

      # Id prefix — matches the short (8-char) id shown in lists or any leading
      # slice of the full UUID. Cast the uuid to text so LIKE works. Callers
      # must strip LIKE wildcards from user input (the dashboard does).
      {:id_prefix, prefix}, q when is_binary(prefix) and prefix != "" ->
        from(w in q, where: fragment("?::text LIKE ?", w.id, ^(prefix <> "%")))

      {:queue, queue}, q ->
        queue_str = to_string(queue)
        from(w in q, where: w.queue == ^queue_str)

      {:from, from_date}, q ->
        from(w in q, where: w.inserted_at >= ^from_date)

      {:to, to_date}, q ->
        from(w in q, where: w.inserted_at <= ^to_date)

      {:current_step, step}, q when is_binary(step) and step != "" ->
        from(w in q, where: w.current_step == ^step)

      {:trigger, trigger}, q when is_atom(trigger) and not is_nil(trigger) ->
        from(w in q, where: w.trigger == ^trigger)

      {:trigger_ref, ref}, q when is_binary(ref) and ref != "" ->
        from(w in q, where: w.trigger_ref == ^ref)

      {:key, key}, q when is_binary(key) and key != "" ->
        from(w in q, where: w.key == ^key)

      {:tag, tag}, q when is_binary(tag) and tag != "" ->
        from(w in q, where: fragment("? @> ?", w.tags, ^[tag]))

      # Case-insensitive substring of the stored error (type, message, or any
      # field a step returned in `{:error, map}`).
      {:error_contains, text}, q when is_binary(text) and text != "" ->
        pattern = "%" <> escape_like(text) <> "%"
        from(w in q, where: fragment("?::text ILIKE ?", w.error, ^pattern))

      # Exact match on fields of the run's input, by dotted path:
      # `input: %{"order_id" => "ORD-1", "customer.tier" => "gold"}`.
      {:input, fields}, q when is_map(fields) ->
        Enum.reduce(fields, q, fn {path, value}, acc ->
          keys = path |> to_string() |> String.split(".")
          from(w in acc, where: fragment("? #>> ? = ?", w.input, ^keys, ^to_string(value)))
        end)

      _, q ->
        q
    end)
  end

  defp escape_like(text), do: String.replace(text, ["\\", "%", "_"], &("\\" <> &1))

  defp execution_to_map(execution, include_steps, include_logs) do
    base = %{
      id: execution.id,
      workflow_module: execution.workflow_module,
      workflow_name: execution.workflow_name,
      status: execution.status,
      queue: execution.queue,
      home_queue: execution.home_queue,
      priority: execution.priority,
      input: execution.input,
      context: Map.drop(execution.context, ["__string_keys__", "__done__"]),
      current_step: execution.current_step,
      error: execution.error,
      parent_workflow_id: execution.parent_workflow_id,
      trigger: execution.trigger,
      trigger_ref: execution.trigger_ref,
      key: execution.key,
      holds_key: execution.holds_key,
      runs_after_id: execution.runs_after_id,
      tags: execution.tags,
      locked_by: execution.locked_by,
      scheduled_at: execution.scheduled_at,
      started_at: execution.started_at,
      completed_at: execution.completed_at,
      retried_at: execution.retried_at,
      inserted_at: execution.inserted_at,
      updated_at: execution.updated_at
    }

    if include_steps && Ecto.assoc_loaded?(execution.step_executions) do
      steps =
        execution.step_executions
        |> Enum.map(&step_to_map(&1, include_logs))

      Map.put(base, :steps, steps)
    else
      base
    end
  end

  defp step_to_map(step, include_logs \\ true) do
    base = %{
      id: step.id,
      step_name: step.step_name,
      step_type: step.step_type,
      attempt: step.attempt,
      status: step.status,
      input: step.input,
      output: step.output,
      error: step.error,
      duration_ms: step.duration_ms,
      started_at: step.started_at,
      completed_at: step.completed_at,
      child_workflow_id: step.child_workflow_id
    }

    if include_logs do
      Map.put(base, :logs, step.logs || [])
    else
      base
    end
  end
end
