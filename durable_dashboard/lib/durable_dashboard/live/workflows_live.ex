defmodule DurableDashboard.Live.WorkflowsLive do
  @moduledoc """
  Workflows catalog — one card per distinct workflow definition that has
  been executed on this instance. Drilling in opens the executions list
  filtered to that workflow.

  Workflow definitions aren't compile-time-registered, so the list is
  derived from execution history via `Durable.Query.list_workflows/1`.
  Each card shows total runs, a running indicator (live, pulses), the
  last run's relative time and status.
  """

  use Phoenix.LiveView

  alias Durable.PubSub, as: DurablePubSub
  alias DurableDashboard.Components.Core
  alias DurableDashboard.Layouts
  alias DurableDashboard.Path, as: DPath

  @workflow_kinds [
    :workflow_started,
    :workflow_resumed,
    :workflow_waiting,
    :workflow_completed,
    :workflow_failed,
    :workflow_cancelled
  ]

  # The full list refreshes on each PubSub event; throttle so a burst of
  # events (parallel branches all completing at once) doesn't thrash the
  # query. 250ms is below human-perceptible flicker but well above the
  # query latency for tens of workflows.
  @refresh_debounce_ms 250

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
       refresh_pending?: false,
       workflows: load_workflows(durable)
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply,
     assign(socket,
       current_path: URI.parse(uri).path,
       breadcrumbs: [%{label: "Workflows"}]
     )}
  end

  @impl true
  def handle_info({:durable_event, kind, _payload}, socket) when kind in @workflow_kinds do
    {:noreply, schedule_refresh(socket)}
  end

  def handle_info(:do_refresh, socket) do
    {:noreply,
     assign(socket,
       refresh_pending?: false,
       workflows: load_workflows(socket.assigns.durable)
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_refresh(%{assigns: %{refresh_pending?: true}} = socket), do: socket

  defp schedule_refresh(socket) do
    Process.send_after(self(), :do_refresh, @refresh_debounce_ms)
    assign(socket, refresh_pending?: true)
  end

  defp load_workflows(durable) do
    Durable.Query.list_workflows(durable: durable)
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
    >
      <Core.heading
        level={1}
        subtitle="Workflow definitions registered on this instance, derived from execution history"
      >
        Workflows
      </Core.heading>

      <%= if @workflows == [] do %>
        <div class="mt-6">
          <Core.empty_state
            title="No workflows yet"
            description="Once a workflow runs at least once it will show up here."
            icon="queue"
          />
        </div>
      <% else %>
        <div class="mt-6 grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-4">
          <div :for={wf <- @workflows} class="contents">
            <.workflow_card workflow={wf} base_path={@base_path} />
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  # ============================================================================
  # Workflow card
  # ============================================================================

  attr :workflow, :map, required: true
  attr :base_path, :string, required: true

  defp workflow_card(assigns) do
    ~H"""
    <.link
      navigate={DPath.workflow_executions(@base_path, @workflow.workflow_name)}
      class={[
        "group block rounded-md border border-border bg-card",
        "p-4 transition-colors duration-150",
        "hover:border-primary/50 hover:bg-accent/30",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      ]}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <h3 class="text-[14px] font-semibold text-foreground truncate">
            {@workflow.workflow_name}
          </h3>
          <p class="text-[11px] text-muted-foreground font-mono truncate mt-0.5">
            {strip_elixir(@workflow.workflow_module)}
          </p>
        </div>

        <.running_chip count={@workflow.running_count} />
      </div>

      <%!-- Segmented readout — same instrument-cluster motif as the Overview
            KPI strip, so the two "Observe" pages rhyme. --%>
      <div class="mt-4 grid grid-cols-3 divide-x divide-border rounded-md bg-background/40">
        <.stat label="Runs" value={@workflow.total_runs} />
        <.stat
          label="Failed"
          value={@workflow.failed_count}
          tone={if @workflow.failed_count > 0, do: :destructive, else: :muted}
        />
        <.stat
          label="Waiting"
          value={@workflow.waiting_count}
          tone={if @workflow.waiting_count > 0, do: :warning, else: :muted}
        />
      </div>

      <div class="mt-4 flex items-center justify-between text-[11px] text-muted-foreground">
        <span class="flex items-center gap-1.5">
          <Core.icon name="clock" class="size-3" />
          <%= if @workflow.last_run_at do %>
            Last run <Core.relative_time at={@workflow.last_run_at} />
          <% else %>
            Never run
          <% end %>
        </span>
        <%= if @workflow.last_status do %>
          <Core.status_pill status={@workflow.last_status} />
        <% end %>
      </div>
    </.link>
    """
  end

  attr :count, :integer, required: true

  defp running_chip(%{count: 0} = assigns) do
    ~H"""
    """
  end

  defp running_chip(assigns) do
    ~H"""
    <span class={[
      "shrink-0 inline-flex items-center gap-1.5 px-2 h-6 rounded-full",
      "bg-success/10 border border-success/30 text-success text-[11px] font-medium"
    ]}>
      <span class="size-1.5 rounded-full bg-success led-dot"></span>
      {@count} running
    </span>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :muted

  defp stat(assigns) do
    ~H"""
    <div class="px-3 py-2.5">
      <div class={[
        "text-numeric text-[17px] font-semibold leading-none tabular-nums",
        tone_class(@tone)
      ]}>
        {@value}
      </div>
      <Core.label class="mt-1.5 block">{@label}</Core.label>
    </div>
    """
  end

  defp tone_class(:destructive), do: "text-destructive"
  defp tone_class(:warning), do: "text-warning"
  defp tone_class(:success), do: "text-success"
  defp tone_class(_), do: "text-foreground"

  defp strip_elixir(nil), do: ""
  defp strip_elixir(s) when is_binary(s), do: String.replace_prefix(s, "Elixir.", "")
end
