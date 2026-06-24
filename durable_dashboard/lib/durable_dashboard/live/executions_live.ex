defmodule DurableDashboard.Live.ExecutionsLive do
  @moduledoc """
  Workflow executions list. One LiveView covers two URLs:

  - `/executions`            — all executions on this instance
  - `/workflows/:name`       — executions filtered to a single workflow

  Wraps the `DataTable` LiveComponent with execution-shaped columns and
  filters. URL params drive the table's query state via `handle_params`;
  the table notifies us back when state changes so we can patch the URL.
  """

  use Phoenix.LiveView

  alias Durable.PubSub, as: DurablePubSub
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Data.DataTable
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @table_id "executions-table"

  @workflow_kinds [
    :workflow_started,
    :workflow_resumed,
    :workflow_waiting,
    :workflow_completed,
    :workflow_failed,
    :workflow_cancelled
  ]

  @statuses ~w(running waiting completed failed cancelled pending)

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
       table_id: @table_id
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
    {:noreply, socket}
  end

  def handle_info({:data_table, @table_id, :query_changed, new_query}, socket) do
    target =
      query_path(socket.assigns.base_path, socket.assigns.workflow_name, new_query)

    {:noreply, push_patch(socket, to: target)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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

      <div class="mt-6">
        <.live_component
          module={DataTable}
          id={@table_id}
          fetcher={fetch_executions(@durable, @workflow_name)}
          columns={columns(@workflow_name)}
          filters={filters(@workflow_name)}
          query={@query}
          row_navigate={fn row -> DPath.execution(@base_path, row.id) end}
          empty_title={empty_title(@workflow_name)}
          empty_description="Adjust the filters or wait for an execution to start."
          empty_icon="queue"
          search_placeholder="Search by workflow name…"
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
  # Column / filter specs
  # ============================================================================

  defp columns(workflow_name) do
    base = [
      %{
        key: :id,
        label: "ID",
        class: "w-[120px]",
        render: &render_id/1
      }
    ]

    workflow_col = [
      %{
        key: :workflow_name,
        label: "Workflow",
        sortable?: false,
        render: &render_name/1
      }
    ]

    rest = [
      %{
        key: :status,
        label: "Status",
        class: "w-[120px]",
        render: &render_status/1
      },
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

  defp filters(workflow_name) do
    base = [
      %{
        key: :status,
        type: :select,
        label: "Status",
        options: ["" | @statuses]
      }
    ]

    if workflow_name do
      base
    else
      [%{key: :search, type: :search, label: "Search"} | base]
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

  defp fetch_executions(durable, workflow_name) do
    fn query ->
      per_page = query[:per_page] || 20
      page = query[:page] || 1
      parent = query[:parent]

      opts =
        [durable: durable, limit: per_page, offset: (page - 1) * per_page]
        |> maybe_add(:status, query[:status])
        |> maybe_add(:workflow_name, workflow_name || query[:search])
        |> scope_to_parent_or_top_level(parent)

      {execs, total} = Durable.Query.list_executions_with_total(opts)
      {attach_child_counts(execs, durable, parent), total}
    end
  end

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

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, _key, ""), do: opts

  defp maybe_add(opts, :status, value) when is_binary(value) do
    Keyword.put(opts, :status, String.to_existing_atom(value))
  rescue
    ArgumentError -> opts
  end

  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  # ============================================================================
  # URL <-> query
  # ============================================================================

  defp parse_query(params) do
    %{
      page: parse_int(params["page"], 1),
      search: nilify(params["search"]),
      status: nilify(params["status"]),
      parent: nilify(params["parent"]),
      sort_by: nil,
      sort_dir: :desc
    }
  end

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
      {"status", query[:status]},
      {"parent", query[:parent]}
    ]

    base =
      if workflow_name do
        base
      else
        base ++ [{"search", query[:search]}]
      end

    Enum.reject(base, fn {_k, v} -> v in [nil, ""] end)
  end

  # ============================================================================
  # Misc
  # ============================================================================

  defp short_id(nil), do: "—"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp strip_elixir(nil), do: ""
  defp strip_elixir(s) when is_binary(s), do: String.replace_prefix(s, "Elixir.", "")
end
