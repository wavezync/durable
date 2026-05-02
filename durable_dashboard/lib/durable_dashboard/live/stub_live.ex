defmodule DurableDashboard.Live.StubLive do
  @moduledoc """
  Placeholder LiveView for routes not yet ported. Renders the full chrome
  (so navigation feels real) plus an explicit "coming in phase N" empty state.
  Replaced view-by-view in phases 2-5.
  """

  use Phoenix.LiveView

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Layouts

  @impl true
  def mount(_params, session, socket) do
    config = session["config"]

    {:ok,
     assign(socket,
       config: config,
       base_path: config.base_path
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {phase, title} = phase_for(socket.assigns.live_action, params)

    {:noreply,
     assign(socket,
       current_path: URI.parse(uri).path,
       breadcrumbs: breadcrumbs(socket.assigns.live_action, params),
       phase: phase,
       page_title: title
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      base_path={@base_path}
      current_path={@current_path}
      breadcrumbs={@breadcrumbs}
    >
      <Core.heading level={1} subtitle={"Coming in phase " <> @phase}>
        {@page_title}
      </Core.heading>

      <div class="mt-8">
        <Core.empty_state
          icon="clock"
          title="Not yet ported"
          description={"This view will be migrated to LiveView during phase " <> @phase <> " of the dashboard rewrite."}
        >
          <:action>
            <Core.button kind="link" navigate={DurableDashboard.Path.overview(@base_path)}>
              Back to Overview
            </Core.button>
          </:action>
        </Core.empty_state>
      </div>
    </Layouts.app>
    """
  end

  defp phase_for(:workflows, _), do: {"2", "Workflows"}
  defp phase_for(:workflow, _), do: {"3", "Workflow detail"}
  defp phase_for(:workflow_tab, _), do: {"3", "Workflow detail"}
  defp phase_for(:inputs, _), do: {"2", "Pending inputs"}
  defp phase_for(:schedules, _), do: {"2", "Schedules"}
  defp phase_for(:settings, _), do: {"5", "Settings"}
  defp phase_for(_, _), do: {"?", "Page"}

  defp breadcrumbs(action, params) do
    case action do
      :workflows ->
        [%{label: "Workflows"}]

      :workflow ->
        [%{label: "Workflows", href: "../workflows"}, %{label: short_id(params["id"])}]

      :workflow_tab ->
        [
          %{label: "Workflows", href: "../../workflows"},
          %{label: short_id(params["id"])},
          %{label: params["tab"]}
        ]

      :inputs ->
        [%{label: "Pending inputs"}]

      :schedules ->
        [%{label: "Schedules"}]

      :settings ->
        [%{label: "Settings"}]

      _ ->
        []
    end
  end

  defp short_id(nil), do: "—"
  defp short_id(id), do: String.slice(id, 0, 8)
end
