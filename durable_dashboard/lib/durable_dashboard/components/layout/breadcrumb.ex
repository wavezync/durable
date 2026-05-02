defmodule DurableDashboard.Components.Layout.Breadcrumb do
  @moduledoc """
  Breadcrumb trail rendered in the topbar.

  Each LV computes its own crumbs and assigns `:breadcrumbs` to the socket.
  Pass through to this component as `@crumbs`.

  ## Crumb shape

      [
        %{label: "Workflows", href: "/dashboard/v2/workflows"},
        %{label: "abc12345"}  # last crumb is unlinked by convention
      ]
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core

  attr :crumbs, :list, default: []
  attr :class, :string, default: nil

  def breadcrumb(assigns) do
    ~H"""
    <nav class={["flex items-center gap-1 text-[13px] text-muted-foreground", @class]} aria-label="Breadcrumb">
      <ol class="flex items-center gap-1">
        <li :for={{crumb, i} <- Enum.with_index(@crumbs)} class="flex items-center gap-1">
          <Core.icon
            :if={i > 0}
            name="chevron-right"
            class="size-3.5 text-muted-foreground/60"
          />
          <.crumb_item crumb={crumb} last?={i == length(@crumbs) - 1} />
        </li>
      </ol>
    </nav>
    """
  end

  attr :crumb, :map, required: true
  attr :last?, :boolean, default: false

  defp crumb_item(%{crumb: %{href: href}, last?: false} = assigns) when is_binary(href) do
    ~H"""
    <.link navigate={@crumb.href} class="hover:text-foreground transition-colors">
      {@crumb.label}
    </.link>
    """
  end

  defp crumb_item(assigns) do
    ~H"""
    <span class={[@last? && "text-foreground font-medium"]}>
      {@crumb.label}
    </span>
    """
  end
end
