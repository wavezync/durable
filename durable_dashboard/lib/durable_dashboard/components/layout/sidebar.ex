defmodule DurableDashboard.Components.Layout.Sidebar do
  @moduledoc """
  Left navigation. Stateless — the active item is derived from
  `@current_path` passed by the parent layout.

  Destinations are grouped by intent — **Observe** (read the system),
  **Operate** (act on it), **Instrument** (wire it up) — so the nav reads as
  an information architecture rather than a flat list. The ⌘K jump button,
  theme toggle and version live here too; there is no topbar. See
  `DESIGN.md` §6.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Path, as: P
  alias Phoenix.LiveView.JS

  @repo_url "https://github.com/wavezync/durable"

  attr :base_path, :string, required: true
  attr :current_path, :string, required: true
  attr :durable, :any, default: nil
  attr :inbox_count, :integer, default: 0
  attr :class, :string, default: nil

  def sidebar(assigns) do
    assigns =
      assign(assigns,
        groups: nav_groups(assigns.base_path, assigns.inbox_count),
        prefix: prefix(assigns.durable),
        version: durable_version(),
        repo_url: @repo_url
      )

    ~H"""
    <aside class={[
      "flex flex-col w-[232px] shrink-0 h-screen sticky top-0",
      "border-r border-border bg-card",
      @class
    ]}>
      <div class="flex items-center gap-2.5 px-4 pt-4 pb-3">
        <Core.icon name="mark" class="size-[22px] text-foreground" />
        <div class="flex flex-col leading-tight min-w-0">
          <span class="text-sm font-semibold">Durable</span>
          <span
            class="text-xs text-muted-foreground truncate"
            data-tip-title="Postgres schema"
            data-tip="Where Durable keeps its tables · set with the :prefix option"
            data-tip-meta={@prefix <> ".workflow_executions, " <> @prefix <> ".step_executions, …"}
          >
            {@prefix} schema
          </span>
        </div>
      </div>

      <div class="px-3 pb-1">
        <%!-- Composite control (icon + label + kbd), so it stays raw markup. --%>
        <button
          type="button"
          class={[
            "w-full flex items-center gap-2 h-[30px] px-2.5 rounded-md",
            "border border-input bg-card text-[13px] text-muted-foreground",
            "hover:bg-accent hover:text-foreground transition-colors",
            "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          ]}
          aria-label="Open command palette"
          data-tip-title="Command palette"
          data-tip="Jump to a run by its id, a workflow or a page"
          data-tip-kbd="⌘K"
          phx-click={JS.dispatch("durable:open-palette", to: "html")}
        >
          <Core.icon name="search" class="size-3.5 shrink-0" />
          <span>Jump to run, workflow…</span>
          <span class="ml-auto font-mono text-[11px]">⌘K</span>
        </button>
      </div>

      <nav class="flex-1 overflow-y-auto thin-scroll px-3 pb-3" aria-label="Primary">
        <div :for={group <- @groups}>
          <p class="px-2.5 pt-3.5 pb-1 text-xs text-muted-foreground">{group.label}</p>
          <.nav_link :for={item <- group.items} item={item} current_path={@current_path} />
        </div>
      </nav>

      <div class="flex items-center gap-2 border-t border-border px-4 h-11 text-xs text-muted-foreground">
        <span
          class="flex items-center gap-2"
          data-tip-title="Live"
          data-tip="Pages update by themselves as runs change"
          data-tip-meta={"node " <> to_string(node())}
        >
          <Core.status_dot status={:running} />
          <span>Live</span>
        </span>
        <span
          :if={@version}
          class="font-mono"
          data-tip-title="Durable version"
          data-tip="The library this dashboard reads"
        >
          · {@version}
        </span>
        <div class="ml-auto flex items-center">
          <a
            href={@repo_url}
            target="_blank"
            rel="noopener noreferrer"
            class={icon_ctl()}
            aria-label="View source on GitHub"
            data-tip="Source on GitHub"
          >
            <Core.icon name="github" class="size-4" />
          </a>
          <%!-- Two-icon swap (moon ⇄ sun) — `Core.icon_button` takes one icon. --%>
          <button
            type="button"
            class={icon_ctl()}
            aria-label="Toggle theme"
            data-tip="Switch between light and dark"
            phx-click={JS.dispatch("durable:toggle-theme", to: "html")}
          >
            <Core.icon name="moon" class="size-4 dark:hidden" />
            <Core.icon name="sun" class="size-4 hidden dark:block" />
          </button>
        </div>
      </div>
    </aside>
    """
  end

  defp nav_groups(base, inbox_count) do
    [
      %{
        label: "Observe",
        items: [
          %{label: "Overview", href: P.overview(base), icon: "nav-overview", match: :exact},
          %{label: "Runs", href: P.executions(base), icon: "nav-runs", match: :prefix},
          %{label: "Workflows", href: P.workflows(base), icon: "nav-workflows", match: :prefix}
        ]
      },
      %{
        label: "Operate",
        items: [
          %{
            label: "Inbox",
            href: P.inputs(base),
            icon: "nav-inbox",
            match: :prefix,
            count: inbox_count
          },
          %{label: "Queues & nodes", href: P.queues(base), icon: "nav-queues", match: :prefix},
          %{label: "Schedules", href: P.schedules(base), icon: "nav-schedules", match: :prefix}
        ]
      },
      %{
        label: "Instrument",
        items: [
          %{label: "Telemetry", href: P.telemetry(base), icon: "nav-telemetry", match: :prefix},
          %{label: "Settings", href: P.settings(base), icon: "nav-settings", match: :prefix}
        ]
      }
    ]
  end

  attr :item, :map, required: true
  attr :current_path, :string, required: true

  defp nav_link(assigns) do
    assigns = assign(assigns, active?: active?(assigns.current_path, assigns.item))

    ~H"""
    <.link
      navigate={@item.href}
      class={[
        "flex items-center gap-2.5 h-8 px-2.5 rounded-md text-[13px] font-medium transition-colors",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        if(@active?,
          do: "bg-secondary text-foreground",
          else: "text-subtle-foreground hover:bg-accent hover:text-foreground"
        )
      ]}
      aria-current={@active? && "page"}
    >
      <Core.icon name={@item.icon} class={["size-4 shrink-0", @active? && "text-primary"]} />
      <span>{@item.label}</span>
      <span
        :if={(@item[:count] || 0) > 0}
        class="ml-auto rounded-full bg-warning/15 px-1.5 font-mono text-[11px] leading-[18px] text-warning"
        aria-label={"#{@item.count} waiting"}
        data-tip-title={"#{@item.count} waiting on a person"}
        data-tip="Runs paused for someone's input · answer them here"
      >
        {@item.count}
      </span>
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

  defp icon_ctl do
    [
      "size-7 inline-flex items-center justify-center rounded-md",
      "text-muted-foreground hover:bg-accent hover:text-foreground transition-colors",
      "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
    ]
  end

  defp prefix(nil), do: "durable"

  defp prefix(durable) do
    case Durable.Config.get_safe(durable) do
      %{prefix: prefix} -> prefix
      _ -> "durable"
    end
  end

  defp durable_version do
    case Application.spec(:durable, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end
end
