defmodule DurableDashboard.Layouts do
  @moduledoc false

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias DurableDashboard.Components.Layout.Sidebar
  alias DurableDashboard.Components.Layout.Topbar

  # ============================================================================
  # Root layout — HTML shell, theme bootstrap, asset loading.
  # ============================================================================

  def root(assigns) do
    assigns = assign(assigns, :dev_mode, dev_mode?())

    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <meta name="live-socket-path" content={@config.live_socket_path} />
        <title>Durable Console</title>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin="anonymous" />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap"
        />
        <link :if={!@dev_mode} rel="stylesheet" href={asset_path(assigns, "app.css")} />
        <link :if={@dev_mode} rel="stylesheet" href="http://localhost:5173/src/index.css" />
        <script>
          // Pick the right theme class on the root before paint.
          (function () {
            try {
              var stored = localStorage.getItem("durable-dashboard-theme");
              var theme = stored || "system";
              var prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
              var dark = theme === "dark" || (theme === "system" && prefersDark);
              document.documentElement.classList.toggle("dark", dark);
            } catch (e) {}
          })();
        </script>
      </head>
      <body class="bg-background text-foreground antialiased min-h-screen">
        {@inner_content}

        <noscript>
          <div style="padding: 2rem; text-align: center; font-family: system-ui;">
            <strong>Durable Console requires JavaScript.</strong>
          </div>
        </noscript>

        <%= if @dev_mode do %>
          <script type="module" src="http://localhost:5173/@vite/client">
          </script>
          <%!-- @vitejs/plugin-react requires this preamble in the page
                BEFORE any React module loads, otherwise React Fast
                Refresh throws "@vitejs/plugin-react can't detect
                preamble." --%>
          <script type="module">
            import RefreshRuntime from "http://localhost:5173/@react-refresh"
            RefreshRuntime.injectIntoGlobalHook(window)
            window.$RefreshReg$ = () => {}
            window.$RefreshSig$ = () => (type) => type
            window.__vite_plugin_react_preamble_installed__ = true
          </script>
          <script type="module" src="http://localhost:5173/src/main.ts">
          </script>
        <% else %>
          <script type="module" src={asset_path(assigns, "app.js")}>
          </script>
        <% end %>

        <script>
          // Theme toggle. Persists, flips html.dark.
          document.documentElement.addEventListener("durable:toggle-theme", function () {
            try {
              var isDark = document.documentElement.classList.toggle("dark");
              localStorage.setItem("durable-dashboard-theme", isDark ? "dark" : "light");
            } catch (e) {}
          });
        </script>
      </body>
    </html>
    """
  end

  # ============================================================================
  # App layout — sidebar + topbar wrapper around `@inner_content`. Each
  # LiveView assigns `:current_path` and `:breadcrumbs` in its mount/handle_params
  # for this layout to read.
  # ============================================================================

  attr :current_path, :string, required: true
  attr :breadcrumbs, :list, default: []
  attr :base_path, :string, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a
      href="#main-content"
      class="sr-only focus:not-sr-only focus:fixed focus:top-3 focus:left-3 focus:z-[60] focus:px-3 focus:py-2 focus:rounded-md focus:bg-primary focus:text-primary-foreground focus:text-[13px] focus:font-medium"
    >
      Skip to main content
    </a>
    <div class="flex min-h-screen">
      <Sidebar.sidebar base_path={@base_path} current_path={@current_path} />
      <div class="flex flex-col flex-1 min-w-0">
        <Topbar.topbar crumbs={@breadcrumbs} />
        <main
          id="main-content"
          tabindex="-1"
          class="flex-1 px-6 py-6 max-w-[1400px] w-full mx-auto"
        >
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    """
  end

  defp asset_path(assigns, file) do
    base = get_in(assigns, [:config, :base_path]) || ""
    "#{base}/__assets__/#{file}"
  end

  defp dev_mode? do
    Application.get_env(:durable_dashboard, :dev_mode, false)
  end
end
