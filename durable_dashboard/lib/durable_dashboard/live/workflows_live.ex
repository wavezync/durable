defmodule DurableDashboard.Live.WorkflowsLive do
  @moduledoc """
  Workflows list view. Wraps the `DataTable` LiveComponent with workflow-shaped
  columns and filters. URL params drive the table's query state via
  `handle_params`; the table notifies us back when state changes so we can
  patch the URL.
  """

  use Phoenix.LiveView

  alias Durable.PubSub, as: DurablePubSub
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Data.DataTable
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @table_id "workflows-table"

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
       page_title: "Workflows",
       table_id: @table_id
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    query = parse_query(params)

    {:noreply,
     assign(socket,
       current_path: URI.parse(uri).path,
       breadcrumbs: [%{label: "Workflows"}],
       query: query
     )}
  end

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @workflow_kinds do
    Phoenix.LiveView.send_update(DataTable, id: @table_id, refresh: true)
    {:noreply, socket}
  end

  def handle_info({:data_table, @table_id, :query_changed, new_query}, socket) do
    {:noreply, push_patch(socket, to: query_path(socket.assigns.base_path, new_query))}
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
    >
      <Core.heading level={1} subtitle="Every workflow execution on this instance">
        Workflows
      </Core.heading>

      <div class="mt-6">
        <.live_component
          module={DataTable}
          id={@table_id}
          fetcher={fetch_workflows(@durable)}
          columns={columns(@base_path)}
          filters={filters()}
          query={@query}
          row_navigate={fn row -> DPath.workflow(@base_path, row.id) end}
          empty_title="No workflows match"
          empty_description="Adjust the filters or wait for a workflow to start."
          empty_icon="queue"
          search_placeholder="Search by workflow name…"
        />
      </div>
    </Layouts.app>
    """
  end

  # ============================================================================
  # Column / filter specs
  # ============================================================================

  defp columns(_base_path) do
    [
      %{
        key: :id,
        label: "ID",
        class: "w-[120px]",
        render: &render_id/1
      },
      %{
        key: :workflow_name,
        label: "Workflow",
        sortable?: false,
        render: &render_name/1
      },
      %{
        key: :status,
        label: "Status",
        class: "w-[120px]",
        render: &render_status/1
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
  end

  defp filters do
    [
      %{key: :search, type: :search, label: "Search"},
      %{
        key: :status,
        type: :select,
        label: "Status",
        options: ["" | @statuses]
      }
    ]
  end

  defp render_status(row) do
    assigns = %{status: row.status}

    ~H"""
    <Core.status_pill status={@status} />
    """
  end

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
  # Fetcher (closure over durable name)
  # ============================================================================

  defp fetch_workflows(durable) do
    fn query ->
      per_page = query[:per_page] || 20
      page = query[:page] || 1

      opts =
        [durable: durable, limit: per_page, offset: (page - 1) * per_page]
        |> maybe_add(:status, query[:status])
        |> maybe_add(:workflow_name, query[:search])

      Durable.Query.list_executions_with_total(opts)
    end
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

  defp query_path(base_path, query) do
    params = build_params(query)
    base = DPath.workflows(base_path)

    case URI.encode_query(params) do
      "" -> base
      qs -> base <> "?" <> qs
    end
  end

  defp build_params(query) do
    [
      {"page", if(query[:page] && query[:page] > 1, do: to_string(query[:page]))},
      {"status", query[:status]},
      {"search", query[:search]}
    ]
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
  end

  # ============================================================================
  # Misc
  # ============================================================================

  defp short_id(nil), do: "—"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)

  defp strip_elixir(nil), do: ""
  defp strip_elixir(s) when is_binary(s), do: String.replace_prefix(s, "Elixir.", "")
end
