defmodule DurableDashboard.Components.Layout.Topbar do
  @moduledoc """
  Top bar — breadcrumb + ⌘K trigger + theme toggle.

  Stateless. Theme toggle dispatches a custom DOM event handled by the
  global theme JS (added in phase 5). For phase 1 the button is wired but
  the listener is a no-op stub.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Layout.Breadcrumb

  attr :crumbs, :list, default: []
  attr :class, :string, default: nil

  def topbar(assigns) do
    ~H"""
    <header class={[
      "h-14 shrink-0 sticky top-0 z-10",
      "flex items-center justify-between gap-4 px-5",
      "border-b border-border bg-background/80 backdrop-blur",
      @class
    ]}>
      <Breadcrumb.breadcrumb crumbs={@crumbs} />

      <div class="flex items-center gap-2">
        <%!-- Composite control: search icon + label + ⌘K kbd hints. Doesn't
              fit `Core.button` (which has a single text slot) or
              `Core.icon_button` (icon-only). One-of-a-kind to the topbar. --%>
        <button
          type="button"
          class={[
            "flex items-center gap-2 h-8 px-2.5 rounded-md",
            "border border-border text-[13px] text-muted-foreground",
            "bg-card/40 hover:bg-accent hover:text-accent-foreground",
            "transition-colors focus-visible:outline-none focus-visible:ring-2",
            "focus-visible:ring-ring"
          ]}
          aria-label="Open command palette"
          phx-click={Phoenix.LiveView.JS.dispatch("durable:open-palette", to: "html")}
        >
          <Core.icon name="search" class="size-3.5" />
          <span>Search</span>
          <span class="ml-3 flex items-center gap-1">
            <Core.kbd>⌘</Core.kbd>
            <Core.kbd>K</Core.kbd>
          </span>
        </button>

        <%!-- Two-icon swap (moon/sun) — `Core.icon_button` takes a single
              icon name, so this stays raw. Class string mirrors
              `icon_button(default, md)` — keep them in sync. --%>
        <button
          type="button"
          class={[
            "size-8 inline-flex items-center justify-center rounded-md",
            "border border-border text-muted-foreground",
            "bg-card/40 hover:bg-accent hover:text-accent-foreground",
            "transition-colors focus-visible:outline-none focus-visible:ring-2",
            "focus-visible:ring-ring"
          ]}
          aria-label="Toggle theme"
          phx-click={Phoenix.LiveView.JS.dispatch("durable:toggle-theme", to: "html")}
        >
          <Core.icon name="moon" class="size-4 dark:hidden" />
          <Core.icon name="sun" class="size-4 hidden dark:block" />
        </button>
      </div>
    </header>
    """
  end
end
