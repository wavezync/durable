defmodule DurableDashboard.Live.SchedulesLive do
  @moduledoc """
  Scheduled workflows list. Driven by the same `DataTable` LiveComponent as
  WorkflowsLive, with schedule-shaped columns. No filter UI in v1 — schedules
  are typically a small set; we'll add filters when the count justifies it.
  """

  use Phoenix.LiveView

  import Ecto.Query

  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.ScheduledWorkflow
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Data.DataTable
  alias DurableDashboard.Layouts

  @table_id "schedules-table"

  @schedule_kinds [:schedule_toggled, :schedule_triggered]

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]
    durable = config.durable

    if connected?(socket) do
      durable_config = Durable.Config.get_safe(durable)

      if durable_config do
        # Schedules don't have a dedicated topic yet — workflows topic
        # surfaces schedule_triggered events too.
        DurablePubSub.subscribe(durable_config, DurablePubSub.workflows_topic(durable_config))
      end
    end

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path,
       durable: durable,
       page_title: "Schedules",
       table_id: @table_id
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     assign(socket,
       current_path: URI.parse(uri).path,
       breadcrumbs: [%{label: "Schedules"}],
       query: %{
         page: parse_int(params["page"], 1),
         search: nil,
         sort_by: nil,
         sort_dir: :asc
       }
     )}
  end

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @schedule_kinds do
    Phoenix.LiveView.send_update(DataTable, id: @table_id, refresh: true)
    {:noreply, socket}
  end

  def handle_info({:data_table, @table_id, :query_changed, new_query}, socket) do
    base = DurableDashboard.Path.schedules(socket.assigns.base_path)

    qs =
      if new_query[:page] && new_query[:page] > 1,
        do: "?" <> URI.encode_query(%{"page" => new_query[:page]}),
        else: ""

    {:noreply, push_patch(socket, to: base <> qs)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
    >
      <Core.heading level={1} subtitle="Cron-driven workflows registered on this instance">
        Schedules
      </Core.heading>

      <div class="mt-6">
        <.live_component
          module={DataTable}
          id={@table_id}
          fetcher={fetch_schedules(@durable)}
          columns={columns()}
          query={@query}
          empty_title="No schedules yet"
          empty_description="Use Durable.schedule/3 in your workflow modules to register one."
          empty_icon="calendar"
        />
      </div>
    </Layouts.app>
    """
  end

  # ============================================================================
  # Columns
  # ============================================================================

  defp columns do
    [
      %{
        key: :enabled,
        label: "",
        class: "w-[60px]",
        render: &render_state/1
      },
      %{
        key: :name,
        label: "Name",
        render: &render_name/1
      },
      %{
        key: :workflow_module,
        label: "Module",
        class: "text-muted-foreground font-mono text-[11px]",
        render: fn s ->
          strip_elixir(s.workflow_module) <> ":" <> (s.workflow_name || "default")
        end
      },
      %{
        key: :cron_expression,
        label: "Cron",
        class: "w-[140px]",
        render: &render_cron/1
      },
      %{
        key: :next_run_at,
        label: "Next run",
        class: "w-[140px] text-right",
        render: &render_next/1
      }
    ]
  end

  defp render_state(s) do
    assigns = %{enabled: s.enabled}

    ~H"""
    <span class={[
      "inline-flex items-center justify-center size-2 rounded-full",
      if(@enabled, do: "bg-success led-dot", else: "bg-muted-foreground")
    ]} aria-label={if @enabled, do: "enabled", else: "disabled"}>
    </span>
    """
  end

  defp render_name(s) do
    assigns = %{name: s.name, tz: s.timezone}

    ~H"""
    <div class="flex flex-col leading-tight">
      <span class="font-medium text-foreground">{@name}</span>
      <span class="text-[11px] text-muted-foreground">{@tz}</span>
    </div>
    """
  end

  defp render_cron(s) do
    assigns = %{cron: s.cron_expression}

    ~H"""
    <Core.code>{@cron}</Core.code>
    """
  end

  defp render_next(s) do
    assigns = %{at: s.next_run_at}

    ~H"""
    <Core.relative_time at={@at} />
    """
  end

  # ============================================================================
  # Fetcher
  # ============================================================================

  defp fetch_schedules(durable) do
    fn query ->
      page = query[:page] || 1
      per_page = query[:per_page] || 20
      offset = (page - 1) * per_page

      config = Durable.Config.get_safe(durable)

      if config do
        list_query =
          from(s in ScheduledWorkflow,
            order_by: [asc: s.name],
            limit: ^per_page,
            offset: ^offset
          )

        total_query = from(s in ScheduledWorkflow, select: count(s.id))

        rows = Durable.Repo.all(config, list_query)
        total = Durable.Repo.one(config, total_query) || 0
        {rows, total}
      else
        {[], 0}
      end
    end
  end

  # ============================================================================
  # Misc
  # ============================================================================

  defp parse_int(nil, default), do: default

  defp parse_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(v, _) when is_integer(v), do: v
  defp parse_int(_, default), do: default

  defp strip_elixir(nil), do: ""
  defp strip_elixir(s) when is_binary(s), do: String.replace_prefix(s, "Elixir.", "")
end
