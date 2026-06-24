defmodule DurableDashboard.Components.Layout.Topbar do
  @moduledoc """
  Top bar — breadcrumb (left) + command cluster (right).

  The right cluster is the console's toolbar: the ⌘K **Jump to…** trigger,
  then a hairline-divided meta group carrying the running **version**, a
  **GitHub** link, and the **theme** toggle. The trigger keeps a bordered
  surface (it's the primary action); the meta controls are ghost (icon-only,
  no border) so the trigger reads as the one thing to reach for.

  Stateless. Both interactive controls dispatch a custom DOM event handled by
  global JS in the root layout (`durable:open-palette`, `durable:toggle-theme`).
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Layout.Breadcrumb
  alias Phoenix.LiveView.JS

  # Project repo, mirrored from `mix.exs` (`@source_url`). A stable constant.
  @repo_url "https://github.com/wavezync/durable"

  attr :crumbs, :list, default: []
  attr :class, :string, default: nil

  def topbar(assigns) do
    assigns =
      assign(assigns,
        version: durable_version(),
        repo_url: @repo_url,
        icon_ctl: icon_ctl_class()
      )

    ~H"""
    <header class={[
      "h-14 shrink-0 sticky top-0 z-10",
      "flex items-center justify-between gap-4 px-5",
      "border-b border-border bg-background/80 backdrop-blur",
      @class
    ]}>
      <Breadcrumb.breadcrumb crumbs={@crumbs} />

      <div class="flex items-center gap-3">
        <%!-- Command trigger. Width hugs its content (search · label · one ⌘K
              chip) so there's no dead gap; it's the primary control, so it
              keeps the bordered surface. Composite shape doesn't fit
              `Core.button`/`Core.icon_button`. --%>
        <button
          type="button"
          class={[
            "flex items-center gap-2 h-8 pl-2.5 pr-2 rounded-md",
            "border border-border text-[13px] text-muted-foreground",
            "bg-card/40 hover:bg-accent hover:text-accent-foreground",
            "transition-colors focus-visible:outline-none focus-visible:ring-2",
            "focus-visible:ring-ring"
          ]}
          aria-label="Open command palette"
          phx-click={JS.dispatch("durable:open-palette", to: "html")}
        >
          <Core.icon name="search" class="size-4 shrink-0" />
          <span>Jump to…</span>
          <Core.kbd class="ml-1">⌘K</Core.kbd>
        </button>

        <div class="h-5 w-px bg-border" aria-hidden="true"></div>

        <div class="flex items-center gap-1.5">
          <span
            :if={@version}
            class="font-mono text-[11px] text-muted-foreground/70 tracking-tight"
            title="Durable version"
          >
            {@version}
          </span>

          <a
            href={@repo_url}
            target="_blank"
            rel="noopener noreferrer"
            class={@icon_ctl}
            aria-label="View source on GitHub"
          >
            <Core.icon name="github" class="size-4" />
          </a>

          <%!-- Two-icon swap (moon ⇄ sun) — `Core.icon_button` takes one icon,
                so this stays raw. Ghost styling mirrors `@icon_ctl`. --%>
          <button
            type="button"
            class={@icon_ctl}
            aria-label="Toggle theme"
            phx-click={JS.dispatch("durable:toggle-theme", to: "html")}
          >
            <Core.icon name="moon" class="size-4 dark:hidden" />
            <Core.icon name="sun" class="size-4 hidden dark:block" />
          </button>
        </div>
      </div>
    </header>
    """
  end

  # Ghost icon-control classes — shared by the GitHub link and theme toggle.
  defp icon_ctl_class do
    [
      "size-8 inline-flex items-center justify-center rounded-md",
      "text-muted-foreground hover:bg-accent hover:text-accent-foreground",
      "transition-colors focus-visible:outline-none focus-visible:ring-2",
      "focus-visible:ring-ring"
    ]
  end

  defp durable_version do
    case Application.spec(:durable, :vsn) do
      nil -> nil
      vsn -> "v" <> List.to_string(vsn)
    end
  end
end
