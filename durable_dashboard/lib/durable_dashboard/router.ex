defmodule DurableDashboard.Router do
  @moduledoc """
  Router macro for embedding the Durable dashboard into a host Phoenix
  application.

  ## Why a macro

  The dashboard's LiveViews can't be mounted via `forward` because Phoenix
  LiveView's session validation uses the host endpoint's router for route
  lookup — routes inside a forwarded sub-router fail the live_session check
  with `unauthorized live_redirect`. The macro emits the routes inline in
  the host's router, so `session.router` matches the URL and the validation
  passes.

  Same approach `phoenix_live_dashboard` uses for `live_dashboard/2`.

  ## Usage

  One line. Add this at the **top level** of your router (not inside a
  `scope` or `pipe_through` block — the macro defines its own pipelines):

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router

        # Your existing pipelines + scopes...

        use DurableDashboard.Router, mount: "/dashboard", durable: MyApp.Durable
      end

  Or equivalently, if you prefer the explicit form:

      import DurableDashboard.Router
      dashboard_routes "/dashboard", durable: MyApp.Durable

  This emits two pipelines (`:durable_dashboard_browser` and
  `:durable_dashboard_assets`) and two scopes:

  - `GET /dashboard` (Overview)
  - `GET /dashboard/workflows` (list)
  - `GET /dashboard/workflows/:id[/:tab]` (detail)
  - `GET /dashboard/inputs`
  - `GET /dashboard/schedules`
  - `GET /dashboard/settings`
  - `GET /dashboard/__assets__/*` (CSS/JS/font assets — no CSRF, since
    cross-origin module-script loading is normal and the assets are
    public-by-design)

  ## Options

  - `:durable` — Durable instance name (default: `Durable`)
  - `:live_socket_path` — path the host configured for `Phoenix.LiveView.Socket`
    (default: `"/live"`)
  - `:on_mount` — list of `on_mount` hooks the host wants to inject for
    auth/etc (default: `[]`)
  """

  @doc """
  One-line `use` form. Equivalent to `import` + `dashboard_routes/2`.

  Required option: `:mount` — the URL prefix the dashboard mounts at.
  Other options pass straight through to `dashboard_routes/2`.

  ## Example

      use DurableDashboard.Router, mount: "/dashboard", durable: MyApp.Durable
  """
  defmacro __using__(opts) do
    prefix = Keyword.fetch!(opts, :mount)
    rest = Keyword.delete(opts, :mount)

    quote do
      require DurableDashboard.Router
      DurableDashboard.Router.dashboard_routes(unquote(prefix), unquote(rest))
    end
  end

  @doc """
  Embeds the dashboard's routes at `prefix` in the calling router.
  """
  defmacro dashboard_routes(prefix, opts \\ []) do
    durable = Keyword.get(opts, :durable, Durable)
    live_socket_path = Keyword.get(opts, :live_socket_path, "/live")
    on_mount = Keyword.get(opts, :on_mount, [])

    quote do
      pipeline :durable_dashboard_browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug :fetch_live_flash
        plug :protect_from_forgery
        plug :put_secure_browser_headers
      end

      pipeline :durable_dashboard_assets do
        plug :accepts, ["html", "json", "css", "js", "woff2", "woff", "ttf", "map"]
      end

      scope path: unquote(prefix), alias: false, as: false do
        pipe_through :durable_dashboard_assets
        forward "/__assets__", DurableDashboard.AssetServer
      end

      scope path: unquote(prefix), alias: false, as: false do
        pipe_through :durable_dashboard_browser

        live_session :durable_dashboard,
          root_layout: {DurableDashboard.Layouts, :root},
          session: %{
            "config" => %{
              durable: unquote(durable),
              base_path: unquote(prefix),
              live_socket_path: unquote(live_socket_path),
              on_mount: unquote(on_mount)
            }
          } do
          live "/", DurableDashboard.Live.OverviewLive, :index
          live "/workflows", DurableDashboard.Live.WorkflowsLive, :index
          live "/workflows/:id", DurableDashboard.Live.WorkflowLive, :show
          live "/workflows/:id/:tab", DurableDashboard.Live.WorkflowLive, :show
          live "/inputs", DurableDashboard.Live.InputsLive, :index
          live "/schedules", DurableDashboard.Live.SchedulesLive, :index
          live "/settings", DurableDashboard.Live.SettingsLive, :index
        end
      end
    end
  end
end
