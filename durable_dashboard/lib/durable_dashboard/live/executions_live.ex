defmodule DurableDashboard.Live.ExecutionsLive do
  @moduledoc """
  Workflow executions list. One LiveView covers two URLs:

  - `/executions`            — all executions on this instance
  - `/workflows/:name`       — executions filtered to a single workflow

  A faceted `ExecutionFilters` bar (workflow / status / time / id) drives the
  URL params; the `DataTable` LiveComponent renders rows and pagination from
  the resulting query. URL params are the single source of truth — both the
  filter bar and the table notify us, and we patch the URL in response.
  """

  use Phoenix.LiveView

  alias Durable.PubSub, as: DurablePubSub
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Data.DataTable
  alias DurableDashboard.Components.Data.ExecutionFilters
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @table_id "executions-table"
  @filters_id "executions-filters"

  @workflow_kinds [
    :workflow_started,
    :workflow_resumed,
    :workflow_waiting,
    :workflow_completed,
    :workflow_failed,
    :workflow_cancelled
  ]

  @statuses ~w(running waiting completed failed cancelled pending)

  # Relative time presets → seconds back from now (mapped to the query's
  # `:from` on inserted_at). Custom ranges use explicit from/to instead.
  @preset_seconds %{
    "15m" => 900,
    "1h" => 3_600,
    "24h" => 86_400,
    "7d" => 604_800,
    "30d" => 2_592_000
  }

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]
    durable = config.durable

    if connected?(socket) do
      durable_config = Durable.Config.get_safe(durable)

      if durable_config do
        DurablePubSub.subscribe(durable_config, DurablePubSub.workflows_topic(durable_config))
      end
    end

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: durable,
       table_id: @table_id,
       filters_id: @filters_id,
       status_options: @statuses,
       workflows: fetch_workflows(durable)
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    workflow_name = params["name"]
    query = parse_query(params)

    breadcrumbs =
      case workflow_name do
        nil ->
          [%{label: "Executions"}]

        name ->
          [
            %{label: "Workflows", href: DPath.workflows(socket.assigns.base_path)},
            %{label: name}
          ]
      end

    {:noreply,
     assign(socket,
       current_path: URI.parse(uri).path,
       breadcrumbs: breadcrumbs,
       query: query,
       workflow_name: workflow_name,
       page_title: page_title(workflow_name)
     )}
  end

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @workflow_kinds do
    Phoenix.LiveView.send_update(DataTable, id: @table_id, refresh: true)
    {:noreply, assign(socket, workflows: fetch_workflows(socket.assigns.durable))}
  end

  def handle_info({:data_table, @table_id, :query_changed, new_query}, socket) do
    {:noreply, patch_to_query(socket, new_query)}
  end

  def handle_info({:execution_filters, patch}, socket) do
    new_query = socket.assigns.query |> Map.merge(patch) |> Map.put(:page, 1)
    {:noreply, patch_to_query(socket, new_query)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp patch_to_query(socket, query) do
    target = query_path(socket.assigns.base_path, socket.assigns.workflow_name, query)
    push_patch(socket, to: target)
  end

  # ============================================================================
  # Render
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
      durable={@durable}
    >
      <Core.heading level={1} subtitle={subtitle(@workflow_name)}>
        {heading(@workflow_name)}
      </Core.heading>

      <div
        :if={@query[:parent]}
        class="mt-4 flex items-center justify-between gap-3 rounded-md border border-border bg-muted/30 px-4 py-2.5"
      >
        <p class="text-[13px] text-muted-foreground">
          Showing child executions of run
          <Core.code>{short_id(@query[:parent])}</Core.code>
        </p>
        <.link
          patch={DPath.execution(@base_path, @query[:parent])}
          class="font-mono text-[10px] uppercase tracking-[0.16em] text-muted-foreground hover:text-foreground transition-colors"
        >
          ← Back to parent
        </.link>
      </div>

      <div class="mt-6 space-y-4">
        <.live_component
          module={ExecutionFilters}
          id={@filters_id}
          base_path={@base_path}
          workflows={@workflows}
          status_options={@status_options}
          workflow={@workflow_name || @query[:workflow]}
          locked_workflow?={not is_nil(@workflow_name)}
          statuses={@query[:statuses]}
          range={@query[:range]}
          from={@query[:from]}
          to={@query[:to]}
          exec_id={@query[:exec_id]}
        />

        <.live_component
          module={DataTable}
          id={@table_id}
          fetcher={fetch_executions(@durable, @workflow_name)}
          columns={columns(@workflow_name)}
          filters={[]}
          query={@query}
          row_navigate={fn row -> DPath.execution(@base_path, row.id) end}
          empty_title={empty_title(@workflow_name)}
          empty_description="Adjust the filters or wait for an execution to start."
          empty_icon="queue"
        />
      </div>
    </Layouts.app>
    """
  end

  defp page_title(nil), do: "Executions"
  defp page_title(name), do: "Executions · #{name}"

  defp heading(nil), do: "Executions"
  defp heading(name), do: name

  defp subtitle(nil), do: "Every workflow execution on this instance"
  defp subtitle(name), do: "Executions of #{name}"

  defp empty_title(nil), do: "No executions match"
  defp empty_title(name), do: "No #{name} executions yet"

  # ============================================================================
  # Column specs
  # ============================================================================

  defp columns(workflow_name) do
    base = [
      %{key: :id, label: "ID", class: "w-[120px]", render: &render_id/1}
    ]

    workflow_col = [
      %{key: :workflow_name, label: "Workflow", sortable?: false, render: &render_name/1}
    ]

    rest = [
      %{key: :status, label: "Status", class: "w-[120px]", render: &render_status/1},
      %{
        key: :child_count,
        label: "Children",
        sortable?: false,
        class: "w-[120px]",
        render: &render_child_count/1
      },
      %{
        key: :queue,
        label: "Queue",
        class: "w-[120px] text-muted-foreground",
        render: &render_queue/1
      },
      %{
        key: :inserted_at,
        label: "Started",
        sortable?: false,
        class: "w-[140px] text-right",
        render: &render_started/1
      }
    ]

    if workflow_name do
      base ++ rest
    else
      base ++ workflow_col ++ rest
    end
  end

  defp render_status(row) do
    assigns = %{status: row.status}

    ~H"""
    <Core.status_pill status={@status} />
    """
  end

  # Informational child-count chip on a top-level run. The run's children are
  # listed on its detail page (Family tab) and via `/executions?parent=<id>`.
  defp render_child_count(%{child_count: n}) when is_integer(n) and n > 0 do
    assigns = %{n: n}

    ~H"""
    <span
      class="inline-flex items-center gap-1 whitespace-nowrap rounded-sm border border-border bg-muted/40 px-1.5 h-5 font-mono text-[10px] text-muted-foreground"
      title="Child executions spawned by this run"
    >
      <span class="font-medium text-foreground/80">{@n}</span> {ngettext_child(@n)}
    </span>
    """
  end

  defp render_child_count(_row) do
    assigns = %{}

    ~H"""
    <span class="text-muted-foreground/40">—</span>
    """
  end

  defp ngettext_child(1), do: "child"
  defp ngettext_child(_), do: "children"

  defp render_name(row) do
    assigns = %{name: row.workflow_name, module: row.workflow_module}

    ~H"""
    <div class="flex flex-col leading-tight">
      <span class="font-medium text-foreground">{@name}</span>
      <span class="text-[11px] text-muted-foreground font-mono">{strip_elixir(@module)}</span>
    </div>
    """
  end

  defp render_id(row) do
    assigns = %{id: row.id}

    ~H"""
    <Core.code>{short_id(@id)}</Core.code>
    """
  end

  defp render_queue(row) do
    assigns = %{queue: row.queue}

    ~H"""
    {@queue}
    """
  end

  defp render_started(row) do
    assigns = %{at: row.inserted_at}

    ~H"""
    <Core.relative_time at={@at} />
    """
  end

  # ============================================================================
  # Fetcher
  # ============================================================================

  defp fetch_executions(durable, locked_name) do
    fn query ->
      per_page = query[:per_page] || 20
      page = query[:page] || 1
      parent = query[:parent]

      opts =
        [durable: durable, limit: per_page, offset: (page - 1) * per_page]
        |> put_workflow(locked_name || query[:workflow])
        |> put_statuses(query[:statuses])
        |> put_id_prefix(query[:exec_id])
        |> put_time_range(query)
        |> scope_to_parent_or_top_level(parent)

      {execs, total} = Durable.Query.list_executions_with_total(opts)
      {attach_child_counts(execs, durable, parent), total}
    end
  end

  defp put_workflow(opts, name) when is_binary(name) and name != "",
    do: Keyword.put(opts, :workflow_name, name)

  defp put_workflow(opts, _), do: opts

  defp put_statuses(opts, statuses) when is_list(statuses) and statuses != [] do
    # Only known statuses survive — guards `String.to_existing_atom` and drops
    # anything a hand-edited URL might inject.
    atoms =
      statuses
      |> Enum.filter(&(&1 in @statuses))
      |> Enum.map(&String.to_existing_atom/1)

    if atoms == [], do: opts, else: Keyword.put(opts, :status, atoms)
  end

  defp put_statuses(opts, _), do: opts

  defp put_id_prefix(opts, id) when is_binary(id) and id != "",
    do: Keyword.put(opts, :id_prefix, id)

  defp put_id_prefix(opts, _), do: opts

  defp put_time_range(opts, query) do
    cond do
      Map.has_key?(@preset_seconds, query[:range]) ->
        from = DateTime.add(DateTime.utc_now(), -@preset_seconds[query[:range]], :second)
        Keyword.put(opts, :from, from)

      query[:from] not in [nil, ""] or query[:to] not in [nil, ""] ->
        opts
        |> maybe_put(:from, parse_local_datetime(query[:from]))
        |> maybe_put(:to, parse_local_datetime(query[:to]))

      true ->
        opts
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Default every list to TOP-LEVEL runs. Parallel/`each`/`call_workflow`
  # children inherit the parent's name and would otherwise flood the list
  # with indistinguishable rows. When a `parent` is set we invert that and
  # show exactly that parent's children (the drill-down view).
  defp scope_to_parent_or_top_level(opts, parent) when is_binary(parent) and parent != "" do
    Keyword.put(opts, :parent_workflow_id, parent)
  end

  defp scope_to_parent_or_top_level(opts, _), do: Keyword.put(opts, :top_level_only, true)

  # Annotate each top-level row with how many child executions it spawned,
  # in a single query for the page. Children-view rows don't need it.
  defp attach_child_counts(execs, _durable, parent) when is_binary(parent) and parent != "" do
    Enum.map(execs, &Map.put(&1, :child_count, 0))
  end

  defp attach_child_counts(execs, durable, _parent) do
    counts = Durable.Query.child_counts(Enum.map(execs, & &1.id), durable: durable)
    Enum.map(execs, fn e -> Map.put(e, :child_count, Map.get(counts, e.id, 0)) end)
  end

  defp fetch_workflows(durable) do
    Durable.Query.list_workflows(durable: durable)
  rescue
    _ -> []
  end

  # ============================================================================
  # URL <-> query
  # ============================================================================

  defp parse_query(params) do
    %{
      page: parse_int(params["page"], 1),
      workflow: nilify(params["workflow"]),
      statuses: parse_list(params["status"]),
      range: nilify(params["range"]),
      from: nilify(params["from"]),
      to: nilify(params["to"]),
      exec_id: nilify(params["id"]),
      parent: nilify(params["parent"]),
      sort_by: nil,
      sort_dir: :desc
    }
  end

  defp parse_list(nil), do: []
  defp parse_list(s) when is_binary(s), do: String.split(s, ",", trim: true)

  defp parse_int(nil, default), do: default

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(v, _) when is_integer(v), do: v
  defp parse_int(_, default), do: default

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(v) when is_binary(v), do: v

  # datetime-local ("YYYY-MM-DDTHH:MM") read as UTC — the query compares the
  # utc_datetime_usec `inserted_at` column.
  defp parse_local_datetime(nil), do: nil
  defp parse_local_datetime(""), do: nil

  defp parse_local_datetime(s) when is_binary(s) do
    s = if String.length(s) == 16, do: s <> ":00", else: s

    case NaiveDateTime.from_iso8601(s) do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  defp query_path(base_path, workflow_name, query) do
    base =
      case workflow_name do
        nil -> DPath.executions(base_path)
        name -> DPath.workflow_executions(base_path, name)
      end

    case URI.encode_query(build_params(workflow_name, query)) do
      "" -> base
      qs -> base <> "?" <> qs
    end
  end

  defp build_params(workflow_name, query) do
    base = [
      {"page", if(query[:page] && query[:page] > 1, do: to_string(query[:page]))},
      {"status", list_param(query[:statuses])},
      {"range", query[:range]},
      {"from", query[:from]},
      {"to", query[:to]},
      {"id", query[:exec_id]},
      {"parent", query[:parent]}
    ]

    base = if workflow_name, do: base, else: base ++ [{"workflow", query[:workflow]}]

    Enum.reject(base, fn {_k, v} -> v in [nil, ""] end)
  end

  defp list_param(list) when is_list(list) and list != [], do: Enum.join(list, ",")
  defp list_param(_), do: nil

  # ============================================================================
  # Misc
  # ============================================================================

  defp short_id(nil), do: "—"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp strip_elixir(nil), do: ""
  defp strip_elixir(s) when is_binary(s), do: String.replace_prefix(s, "Elixir.", "")
end
