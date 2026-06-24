defmodule DurableDashboard.Components.Layout.Sidebar do
  @moduledoc """
  Left navigation sidebar. Stateless function component — active item is
  derived from `@current_path` passed by the parent layout.

  Nav is split into two intent groups — **Observe** (read the running system)
  and **Operate** (act on it) — so the six destinations read as an information
  architecture, not a flat list. The active item carries the "live rail" (a
  short indigo bar on the left edge): the console's recurring "now / you are
  here" signal, the same indigo that marks the running edge in the graph.

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
    assigns = assign(assigns, groups: nav_groups(assigns.base_path))

    ~H"""
    <aside class={[
      "flex flex-col w-[220px] shrink-0 h-screen sticky top-0",
      "border-r border-border bg-card/40 backdrop-blur-sm",
      @class
    ]}>
      <.brand />

      <nav class="flex-1 overflow-y-auto thin-scroll px-2.5 py-3 space-y-5">
        <div :for={group <- @groups} class="space-y-0.5">
          <p class="px-2.5 pb-1.5 font-mono text-[9px] uppercase tracking-[0.18em] text-muted-foreground/55">
            {group.label}
          </p>
          <.nav_link :for={item <- group.items} item={item} current_path={@current_path} />
        </div>
      </nav>

      <.footer />
    </aside>
    """
  end

  # Two intent groups. "Observe" reads the system; "Operate" acts on it.
  defp nav_groups(base) do
    [
      %{
        label: "Observe",
        items: [
          %{label: "Overview", href: P.overview(base), icon: "home", match: :exact},
          %{label: "Workflows", href: P.workflows(base), icon: "queue", match: :prefix},
          %{label: "Executions", href: P.executions(base), icon: "play", match: :prefix}
        ]
      },
      %{
        label: "Operate",
        items: [
          %{label: "Inputs", href: P.inputs(base), icon: "inbox", match: :prefix},
          %{label: "Schedules", href: P.schedules(base), icon: "calendar", match: :prefix},
          %{label: "Settings", href: P.settings(base), icon: "settings", match: :prefix}
        ]
      }
    ]
  end

  attr :item, :map, required: true
  attr :current_path, :string, required: true

  defp nav_link(assigns) do
    active? = active?(assigns.current_path, assigns.item)

    icon_class =
      if active?,
        do: "size-4 shrink-0",
        else: "size-4 shrink-0 text-muted-foreground/70 group-hover:text-accent-foreground"

    assigns = assign(assigns, active?: active?, icon_class: icon_class)

    ~H"""
    <.link
      navigate={@item.href}
      class={[
        "group relative flex items-center gap-2.5 px-2.5 h-8 rounded-md",
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
      <%!-- The live rail — the active channel. Same indigo as the running edge. --%>
      <span
        :if={@active?}
        class="absolute left-0 top-1/2 h-4 w-0.5 -translate-y-1/2 rounded-full bg-primary"
      >
      </span>
      <Core.icon name={@item.icon} class={@icon_class} />
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

  defp brand(assigns) do
    ~H"""
    <div class="h-14 px-4 flex items-center gap-2.5 border-b border-border">
      <%!-- The monitor tile + heartbeat: the engine is alive and durable. --%>
      <div class="relative size-7 rounded-md bg-primary/15 border border-primary/30 flex items-center justify-center">
        <span class="size-1.5 rounded-full bg-primary led-dot"></span>
      </div>
      <div class="flex flex-col leading-none gap-1">
        <span class="text-[13px] font-semibold tracking-tight text-foreground">Durable</span>
        <span class="font-mono text-[9px] text-muted-foreground/80 tracking-[0.22em] uppercase">
          Console
        </span>
      </div>
    </div>
    """
  end

  defp footer(assigns) do
    ~H"""
    <div class="border-t border-border px-3.5 h-10 flex items-center justify-between text-[11px]">
      <span class="font-mono text-muted-foreground/70">durable</span>
      <span class="flex items-center gap-1.5 font-mono text-muted-foreground">
        <span class="size-1.5 rounded-full bg-success led-dot"></span>
        connected
      </span>
    </div>
    """
  end
end
