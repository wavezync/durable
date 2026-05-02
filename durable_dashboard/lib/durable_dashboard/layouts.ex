defmodule DurableDashboard.Layouts do
  @moduledoc false

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias DurableDashboard.Components.Layout.Sidebar
  alias DurableDashboard.Components.Layout.Topbar

  # ============================================================================
  # V2 root — no React shell, no Vite dev script. Reuses the existing CSS
  # bundle (assets/src/index.css → priv/static/durable_dashboard/app.css) since
  # phase 1-5 keep the v1 path running side-by-side. After cutover we'll swap
  # the build pipeline.
  # ============================================================================

  def root_v2(assigns) do
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
                preamble." Mirrors the v1 layout's setup. --%>
          <script type="module">
            import RefreshRuntime from "http://localhost:5173/@react-refresh"
            RefreshRuntime.injectIntoGlobalHook(window)
            window.$RefreshReg$ = () => {}
            window.$RefreshSig$ = () => (type) => type
            window.__vite_plugin_react_preamble_installed__ = true
          </script>
          <script type="module" src="http://localhost:5173/src/v2/main.ts">
          </script>
        <% else %>
          <script type="module" src={asset_path(assigns, "app_v2.js")}>
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
  # V2 app layout — sidebar + topbar wrapper around `@inner_content`. Each
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

    <%!-- CommandPalette temporarily unmounted while debugging the reload loop. --%>
    """
  end

  # ============================================================================
  # V1 root (unchanged) — retained for the React SPA path.
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
        <title>Durable Dashboard</title>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin="anonymous" />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap"
        />
        <link :if={!@dev_mode} rel="stylesheet" href={asset_path(assigns, "app.css")} />
        <script>
          // Pick the right theme class on the root element BEFORE the body
          // renders so we avoid a flash of the wrong theme. Kept in sync with
          // the ThemeToggle component in src/components/ThemeToggle.tsx.
          (function () {
            try {
              var stored = localStorage.getItem("durable-dashboard-theme");
              var theme = stored || "system";
              var prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
              var dark = theme === "dark" || (theme === "system" && prefersDark);
              document.documentElement.classList.toggle("dark", dark);
            } catch (e) {
              // ignore
            }
          })();
        </script>
      </head>
      <body class="bg-background text-foreground antialiased min-h-screen">
        {@inner_content}

        <noscript>
          <div style="padding: 2rem; text-align: center; font-family: system-ui;">
            <strong>Durable Dashboard requires JavaScript.</strong>
            <p>Enable JavaScript in your browser to view the dashboard.</p>
          </div>
        </noscript>

        <%= if @dev_mode do %>
          <script type="module" src="http://localhost:5173/@vite/client">
          </script>
          <script type="module">
            import RefreshRuntime from "http://localhost:5173/@react-refresh"
            RefreshRuntime.injectIntoGlobalHook(window)
            window.$RefreshReg$ = () => {}
            window.$RefreshSig$ = () => (type) => type
            window.__vite_plugin_react_preamble_installed__ = true
          </script>
          <script type="module" src="http://localhost:5173/src/main.tsx">
          </script>
        <% else %>
          <script type="module" src={asset_path(assigns, "app.js")}>
          </script>
        <% end %>

        <script>
          // After 4s, if the React root hasn't replaced the loading shell with
          // real content, surface an actionable error so the user isn't left
          // staring at a spinner forever. This is the dev-mode safety net
          // called out in Phase 5 of the refactor plan.
          setTimeout(function () {
            var el = document.getElementById("durable-dashboard");
            if (!el) return;
            var bootSentinel = el.querySelector("[data-boot-sentinel]");
            if (!bootSentinel) return;
            bootSentinel.innerHTML =
              '<div style="max-width:36rem;margin:4rem auto;padding:1.5rem;' +
              'border:1px solid #dc2626;border-radius:.5rem;' +
              'font-family:system-ui;color:#fca5a5;background:#7f1d1d22;">' +
              '<h2 style="margin-top:0;">Dashboard assets failed to load</h2>' +
              '<p>The React bundle did not mount after 4 seconds. Likely causes:</p>' +
              '<ul><li>Vite dev server not running — start it with ' +
              '<code>cd durable_dashboard/assets &amp;&amp; pnpm vite</code></li>' +
              '<li>Production assets missing — run <code>pnpm build</code></li>' +
              '<li>Browser blocked the script (check the devtools console)</li></ul>' +
              '</div>';
          }, 4000);
        </script>
      </body>
    </html>
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
