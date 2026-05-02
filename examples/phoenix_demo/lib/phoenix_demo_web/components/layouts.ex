defmodule PhoenixDemoWeb.Layouts do
  @moduledoc """
  Application chrome: drawer-based sidebar layout used by every LiveView in
  the demo. Each LiveView passes `:active_nav` to highlight the current
  section.
  """
  use PhoenixDemoWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :active_nav, :atom, default: nil

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="nav-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col min-h-screen bg-base-100">
        <header class="navbar bg-base-200 border-b border-base-300 px-4 lg:hidden">
          <label for="nav-drawer" class="btn btn-square btn-ghost">
            <.icon name="hero-bars-3" class="size-5" />
          </label>
          <span class="ml-2 font-semibold">Durable Demo</span>
        </header>

        <main class="flex-1 px-6 py-8">
          <div class="mx-auto max-w-6xl w-full">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <div class="drawer-side">
        <label for="nav-drawer" class="drawer-overlay" aria-label="close sidebar"></label>
        <aside class="bg-base-200 min-h-full w-64 border-r border-base-300">
          <div class="px-6 py-5 border-b border-base-300 flex items-center gap-2">
            <.icon name="hero-bolt" class="size-6 text-accent" />
            <div class="leading-tight">
              <div class="font-bold text-sm">Durable Demo</div>
              <div class="text-xs text-base-content/60">Workflow showcase</div>
            </div>
          </div>

          <ul class="menu menu-sm gap-1 p-3">
            <.nav_item icon="hero-home" label="Home" path="/" active={@active_nav == :home} />
            <.nav_item icon="hero-queue-list" label="Executions" path="/executions" active={@active_nav == :executions} />
            <.nav_item icon="hero-hand-raised" label="Pending Inputs" path="/pending-inputs" active={@active_nav == :pending_inputs} />
            <.nav_item icon="hero-bolt" label="Pending Events" path="/pending-events" active={@active_nav == :pending_events} />
            <.nav_item icon="hero-clock" label="Schedules" path="/schedules" active={@active_nav == :schedules} />

            <li class="menu-title pt-4 pb-1 text-xs uppercase tracking-wide">Tools</li>
            <li>
              <a href="/dashboard" target="_blank" class="flex items-center gap-2">
                <.icon name="hero-cog-6-tooth" class="size-4" />
                <span>Durable Dashboard</span>
                <.icon name="hero-arrow-top-right-on-square" class="size-3 ml-auto opacity-60" />
              </a>
            </li>
          </ul>
        </aside>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :path, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <li>
      <.link navigate={@path} class={["flex items-center gap-2", @active && "menu-active"]}>
        <.icon name={@icon} class="size-4" />
        <span>{@label}</span>
      </.link>
    </li>
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
