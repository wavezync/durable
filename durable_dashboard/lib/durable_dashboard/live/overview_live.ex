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
      durable={@durable}
    >
      <Core.heading level={1} subtitle="Live status of all workflows on this instance">
        Overview
      </Core.heading>

      <%!-- Status readout — one hairline-segmented instrument cluster rather
            than six glowing cards. The gap-px + bg-border trick draws the
            dividers; cells sit on bg-card. Running pulses; only the counts
            that signal trouble light up. --%>
      <section class="mt-6">
        <div class="grid grid-cols-2 gap-px overflow-hidden rounded-xl border border-border bg-border shadow-card md:grid-cols-3 lg:grid-cols-6">
          <.kpi_cell label="Pending" value={@counts.pending} kind="muted" />
          <.kpi_cell label="Running" value={@counts.running} kind="success" live />
          <.kpi_cell label="Waiting" value={@counts.waiting} kind="warning" />
          <.kpi_cell label="Completed" value={@counts.completed} kind="success" />
          <.kpi_cell label="Failed" value={@counts.failed} kind="destructive" />
          <.kpi_cell label="Cancelled" value={@counts.cancelled} kind="muted" />
        </div>
      </section>

      <section class="mt-8">
        <Core.card padding="none">
          <:title>Recent executions</:title>
          <:action>
            <Core.button kind="link" navigate={DPath.executions(@base_path)}>
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
                <%!-- Headers share the canonical <.label> idiom — see DESIGN.md §6. --%>
                <tr class="border-b border-border font-mono text-[10px] font-medium uppercase tracking-[0.14em] text-muted-foreground/70">
                  <th class="text-left px-4 py-2.5">ID</th>
                  <th class="text-left px-4 py-2.5">Workflow</th>
                  <th class="text-left px-4 py-2.5">Status</th>
                  <th class="text-left px-4 py-2.5">Queue</th>
                  <th class="text-right px-4 py-2.5">Started</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={exec <- @recent}
                  class="border-b border-border/60 last:border-b-0 hover:bg-accent/40 cursor-pointer transition-colors"
                  phx-click={JS.navigate(DPath.execution(@base_path, exec.id))}
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
  # KPI cell — one segment of the status readout cluster
  # ============================================================================

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :kind, :string, default: "muted"
  attr :live, :boolean, default: false

  defp kpi_cell(assigns) do
    ~H"""
    <div class="flex flex-col gap-2.5 bg-card px-4 py-3.5">
      <div class="flex items-center gap-1.5">
        <span class={["size-1.5 rounded-full", kpi_dot(@kind), @live && @value > 0 && "led-dot"]} />
        <Core.label class={kpi_label_tone(@kind)}>{@label}</Core.label>
      </div>
      <span class={[
        "text-numeric text-[26px] font-semibold leading-none tabular-nums",
        kpi_value_tone(@kind, @value)
      ]}>
        {@value}
      </span>
    </div>
    """
  end

  defp kpi_dot("success"), do: "bg-success"
  defp kpi_dot("warning"), do: "bg-warning"
  defp kpi_dot("destructive"), do: "bg-destructive"
  defp kpi_dot("info"), do: "bg-info"
  defp kpi_dot(_), do: "bg-muted-foreground/50"

  # Labels stay quiet by default; the "attention" tiers (failed/waiting) carry a
  # faint tint so the eye lands on them without six competing colors.
  defp kpi_label_tone("destructive"), do: "text-destructive/80"
  defp kpi_label_tone("warning"), do: "text-warning/80"
  defp kpi_label_tone(_), do: nil

  # Only the numbers that signal a problem light up; the rest stay neutral mono.
  defp kpi_value_tone("destructive", v) when v > 0, do: "text-destructive"
  defp kpi_value_tone("warning", v) when v > 0, do: "text-warning"
  defp kpi_value_tone(_, _), do: "text-foreground"

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
        # Top-level runs only — otherwise a single fan-out run inserts N child
        # rows at nearly the same time and floods "recent executions" with
        # indistinguishable children of one parent.
        top_level_only: true,
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
