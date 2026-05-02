defmodule DurableDashboard.Components.Layout.Sidebar do
  @moduledoc """
  Left navigation sidebar. Stateless function component — active item is
  derived from `@current_path` passed by the parent layout.

  ## Required assigns

  - `:base_path` — host app's mount path (e.g. `/dashboard`)
  - `:current_path` — the LV's current request path; nav items match against
    this and highlight the active route
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Path, as: P

  attr :base_path, :string, required: true
  attr :current_path, :string, required: true
  attr :class, :string, default: nil

  def sidebar(assigns) do
    items = nav_items(assigns.base_path)
    assigns = assign(assigns, items: items)

    ~H"""
    <aside class={[
      "flex flex-col w-[220px] shrink-0 h-screen sticky top-0",
      "border-r border-border bg-card/40 backdrop-blur-sm",
      @class
    ]}>
      <.brand base_path={@base_path} />

      <nav class="flex-1 overflow-y-auto thin-scroll px-2 py-2">
        <ul class="space-y-0.5">
          <li :for={item <- @items}>
            <.nav_link item={item} current_path={@current_path} />
          </li>
        </ul>
      </nav>

      <.footer />
    </aside>
    """
  end

  defp nav_items(base) do
    [
      %{label: "Overview", href: P.overview(base), icon: "home", match: :exact},
      %{label: "Workflows", href: P.workflows(base), icon: "queue", match: :prefix},
      %{label: "Inputs", href: P.inputs(base), icon: "inbox", match: :prefix},
      %{label: "Schedules", href: P.schedules(base), icon: "calendar", match: :prefix},
      %{label: "Settings", href: P.settings(base), icon: "settings", match: :prefix}
    ]
  end

  attr :item, :map, required: true
  attr :current_path, :string, required: true

  defp nav_link(assigns) do
    active? = active?(assigns.current_path, assigns.item)
    assigns = assign(assigns, active?: active?)

    ~H"""
    <.link
      navigate={@item.href}
      class={[
        "flex items-center gap-2.5 px-2.5 h-8 rounded-md",
        "text-[13px] font-medium transition-colors",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        if @active? do
          "bg-primary/10 text-primary"
        else
          "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
        end
      ]}
      aria-current={@active? && "page"}
    >
      <Core.icon name={@item.icon} class="size-4 shrink-0" />
      <span>{@item.label}</span>
    </.link>
    """
  end

  defp active?(current_path, %{href: href, match: :exact}) do
    normalize(current_path) == normalize(href)
  end

  defp active?(current_path, %{href: href, match: :prefix}) do
    cur = normalize(current_path)
    target = normalize(href)
    cur == target or String.starts_with?(cur, target <> "/")
  end

  defp normalize(nil), do: ""
  defp normalize(path), do: path |> String.trim_trailing("/") |> default_root()
  defp default_root(""), do: "/"
  defp default_root(path), do: path

  attr :base_path, :string, required: true

  defp brand(assigns) do
    ~H"""
    <div class="h-14 px-4 flex items-center gap-2 border-b border-border">
      <div class="size-6 rounded-md bg-primary/15 border border-primary/30 flex items-center justify-center">
        <span class="size-1.5 rounded-full bg-primary led-dot"></span>
      </div>
      <div class="flex flex-col leading-none">
        <span class="text-[13px] font-semibold tracking-tight text-foreground">Durable</span>
        <span class="text-[10px] text-muted-foreground tracking-wider uppercase">Console</span>
      </div>
    </div>
    """
  end

  defp footer(assigns) do
    ~H"""
    <div class="border-t border-border px-3 h-10 flex items-center justify-between text-[11px] text-muted-foreground">
      <span class="font-mono">durable</span>
      <span class="flex items-center gap-1.5">
        <span class="size-1.5 rounded-full bg-success led-dot"></span>
        connected
      </span>
    </div>
    """
  end
end
