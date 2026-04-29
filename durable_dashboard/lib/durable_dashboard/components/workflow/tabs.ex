defmodule DurableDashboard.Components.Workflow.Tabs do
  @moduledoc """
  Tab navigation strip for the workflow detail view. Stateless function
  component — the active tab is derived from `@active` (the parent LV's
  `live_action` or a tab name from `handle_params`). Each tab links via
  `live_patch` to its nested route so switching is a no-remount transition.
  """

  use Phoenix.Component

  alias DurableDashboard.Path, as: DPath

  attr :base_path, :string, required: true
  attr :workflow_id, :string, required: true
  attr :active, :atom, required: true
  attr :show_family?, :boolean, default: false
  attr :class, :string, default: nil

  def tabs(assigns) do
    items =
      [
        {:summary, "Summary"},
        {:flow, "Flow"},
        {:logs, "Logs"},
        {:io, "I/O"},
        {:history, "History"}
      ] ++ if(assigns.show_family?, do: [{:family, "Family"}], else: [])

    assigns = assign(assigns, items: items)

    ~H"""
    <nav
      class={[
        "flex items-center gap-1 -mb-px border-b border-border",
        @class
      ]}
      aria-label="Workflow detail tabs"
      role="tablist"
    >
      <.link
        :for={{key, label} <- @items}
        patch={DPath.workflow_tab(@base_path, @workflow_id, key)}
        role="tab"
        aria-selected={to_string(@active == key)}
        aria-current={if @active == key, do: "page"}
        class={tab_class(@active == key)}
      >
        {label}
      </.link>
    </nav>
    """
  end

  defp tab_class(true) do
    "inline-flex items-center h-9 px-3 text-[13px] font-medium " <>
      "text-foreground border-b-2 border-primary -mb-px"
  end

  defp tab_class(false) do
    "inline-flex items-center h-9 px-3 text-[13px] font-medium " <>
      "text-muted-foreground hover:text-foreground border-b-2 border-transparent " <>
      "transition-colors"
  end
end
