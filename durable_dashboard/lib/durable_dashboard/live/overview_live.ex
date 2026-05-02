defmodule DurableDashboard.Live.OverviewLive do
  @moduledoc """
  Dashboard landing — KPI counts + recent workflows.

  Subscribes to the `Durable.PubSub` workflows topic and refreshes assigns on
  any workflow lifecycle event. No `push_event` to JS — LiveView re-renders.
  """

  use Phoenix.LiveView

  alias Durable.PubSub, as: DurablePubSub
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath
  alias Phoenix.LiveView.JS

  @workflow_kinds [
    :workflow_started,
    :workflow_resumed,
    :workflow_waiting,
    :workflow_completed,
    :workflow_failed,
    :workflow_cancelled
  ]

  @recent_limit 10

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]
    durable_name = config.durable

    if connected?(socket) do
      durable_config = Durable.Config.get_safe(durable_name)

      if durable_config do
        DurablePubSub.subscribe(durable_config, DurablePubSub.workflows_topic(durable_config))
      end
    end

    socket =
      socket
      |> assign(
        config: config,
        base_path: config.base_path,
        durable: durable_name,
        page_title: "Overview"
      )
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply,
     assign(socket,
       current_path: URI.parse(uri).path,
       breadcrumbs: [%{label: "Overview"}]
     )}
  end

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @workflow_kinds do
    {:noreply, load_data(socket)}
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
      <Core.heading level={1} subtitle="Live status of all workflows on this instance">
        Overview
      </Core.heading>

      <section class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3 mt-6">
        <.kpi_card label="Pending" value={@counts.pending} kind="muted" />
        <.kpi_card label="Running" value={@counts.running} kind="success" />
        <.kpi_card label="Waiting" value={@counts.waiting} kind="warning" />
        <.kpi_card label="Completed" value={@counts.completed} kind="success" />
        <.kpi_card label="Failed" value={@counts.failed} kind="destructive" />
        <.kpi_card label="Cancelled" value={@counts.cancelled} kind="muted" />
      </section>

      <section class="mt-8">
        <Core.card padding="none">
          <:title>Recent workflows</:title>
          <:action>
            <Core.button kind="link" navigate={DPath.workflows(@base_path)}>
              View all
            </Core.button>
          </:action>

          <%= if @recent == [] do %>
            <Core.empty_state
              icon="queue"
              title="No workflows yet"
              description="When a workflow starts, it'll appear here."
            />
          <% else %>
            <table class="w-full text-[13px]">
              <thead>
                <tr class="border-b border-border text-[11px] uppercase tracking-wider text-muted-foreground">
                  <th class="text-left font-medium px-4 py-2.5">ID</th>
                  <th class="text-left font-medium px-4 py-2.5">Workflow</th>
                  <th class="text-left font-medium px-4 py-2.5">Status</th>
                  <th class="text-left font-medium px-4 py-2.5">Queue</th>
                  <th class="text-right font-medium px-4 py-2.5">Started</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={exec <- @recent}
                  class="border-b border-border/60 last:border-b-0 hover:bg-accent/40 cursor-pointer transition-colors"
                  phx-click={JS.navigate(DPath.workflow(@base_path, exec.id))}
                >
                  <td class="px-4 py-2.5"><Core.code>{short_id(exec.id)}</Core.code></td>
                  <td class="px-4 py-2.5 font-medium">{exec.workflow_name}</td>
                  <td class="px-4 py-2.5"><Core.status_pill status={exec.status} /></td>
                  <td class="px-4 py-2.5 text-muted-foreground">{exec.queue}</td>
                  <td class="px-4 py-2.5 text-right">
                    <Core.relative_time at={exec.inserted_at} />
                  </td>
                </tr>
              </tbody>
            </table>
          <% end %>
        </Core.card>
      </section>
    </Layouts.app>
    """
  end

  # ============================================================================
  # KPI card
  # ============================================================================

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :kind, :string, default: "muted"

  defp kpi_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5 p-4 rounded-md border border-border bg-card">
      <span class={["text-[11px] uppercase tracking-wider", kpi_label_class(@kind)]}>
        {@label}
      </span>
      <span class="text-numeric text-2xl font-semibold tabular-nums text-foreground">
        {@value}
      </span>
    </div>
    """
  end

  defp kpi_label_class("success"), do: "text-success"
  defp kpi_label_class("warning"), do: "text-warning"
  defp kpi_label_class("destructive"), do: "text-destructive"
  defp kpi_label_class("info"), do: "text-info"
  defp kpi_label_class(_), do: "text-muted-foreground"

  # ============================================================================
  # Data
  # ============================================================================

  defp load_data(socket) do
    durable = socket.assigns.durable

    counts = fetch_counts(durable)
    recent = fetch_recent(durable)

    assign(socket, counts: counts, recent: recent)
  end

  defp fetch_counts(durable) do
    raw = Durable.Query.dashboard_counts(durable: durable)

    %{
      pending: count(raw, :pending),
      running: count(raw, :running),
      waiting: count(raw, :waiting),
      completed: count(raw, :completed),
      failed: count(raw, :failed),
      cancelled: count(raw, :cancelled)
    }
  rescue
    _ ->
      %{pending: 0, running: 0, waiting: 0, completed: 0, failed: 0, cancelled: 0}
  end

  defp count(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || 0
  end

  defp fetch_recent(durable) do
    {rows, _total} =
      Durable.Query.list_executions_with_total(
        durable: durable,
        limit: @recent_limit,
        offset: 0
      )

    rows
  rescue
    _ -> []
  end

  defp short_id(nil), do: "—"
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
end
