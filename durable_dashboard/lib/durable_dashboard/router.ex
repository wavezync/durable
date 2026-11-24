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

  One line in your router:

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router

        # Your existing pipelines + scopes...

        use DurableDashboard.Router, mount: "/dashboard", durable: MyApp.Durable
      end

  Or equivalently, if you prefer the explicit form:

      import DurableDashboard.Router
      dashboard_routes "/dashboard", durable: MyApp.Durable

  Inside a `scope`, the dashboard mounts under the scope's path and its links
  follow.

  This emits two pipelines (`:durable_dashboard_browser` and
  `:durable_dashboard_assets`, once per router) and two scopes:

  - `GET /dashboard` (Overview)
  - `GET /dashboard/workflows`, `/workflows/:name`, `/workflows/:name/runs`
  - `GET /dashboard/executions` (Runs)
  - `GET /dashboard/executions/:id[/:view]` (one run)
  - `GET /dashboard/inputs` (Inbox)
  - `GET /dashboard/keys`
  - `GET /dashboard/queues` (Queues & nodes)
  - `GET /dashboard/schedules`, `/schedules/:name`
  - `GET /dashboard/telemetry`
  - `GET /dashboard/settings`
  - `GET /dashboard/__assets__/*` (CSS/JS/font assets — no CSRF, since
    cross-origin module-script loading is normal and the assets are
    public-by-design)

  ## Options

  - `:durable` — Durable instance name (default: `Durable`)
  - `:live_socket_path` — path the host configured for `Phoenix.LiveView.Socket`
    (default: `"/live"`)
  - `:on_mount` — `on_mount` hooks the host wants to run on every dashboard
    LiveView, e.g. authentication (default: `[]`)
  - `:resolver` — a `DurableDashboard.Access` module deciding who may
    retry, cancel, pause and so on. Without one the dashboard is read-only.
  - `:label` — what the sidebar says under "Durable", e.g. `"Production"`,
    so it's plain which dashboard is open (default: the repo's database name)
  - `:as` — the name of this mount's `live_session` (default:
    `:durable_dashboard`). Only needed to mount the dashboard more than once.

  ## One dashboard per Durable instance

  An app that runs several Durable instances mounts the dashboard once for
  each, at its own path, and names every mount after the first with `:as`:

      scope "/admin" do
        dashboard_routes "/durable"
        dashboard_routes "/durable-billing", durable: MyApp.Billing, as: :billing_dashboard
      end

  Each mount shows its own instance and links only to its own pages. A second
  mount without a distinct `:as` doesn't compile.
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
    resolver = Keyword.get(opts, :resolver)
    as = Keyword.get(opts, :as, :durable_dashboard)
    label = Keyword.get(opts, :label)

    quote do
      # The pipelines are the same for every mount, so the first one defines them.
      if DurableDashboard.Router.__mount__(__MODULE__, unquote(as), unquote(prefix)) == :first do
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
      end

      # Where the pages really are: under any `scope` this is called in.
      durable_dashboard_base = Phoenix.Router.scoped_path(__MODULE__, unquote(prefix))

      scope path: unquote(prefix), alias: false, as: false do
        pipe_through :durable_dashboard_assets
        forward "/__assets__", DurableDashboard.AssetServer
      end

      scope path: unquote(prefix), alias: false, as: false do
        pipe_through :durable_dashboard_browser

        live_session unquote(as),
          root_layout: {DurableDashboard.Layouts, :root},
          on_mount: [
            {DurableDashboard.Access, :default},
            {DurableDashboard.InboxBadge, :default} | List.wrap(unquote(on_mount))
          ],
          session:
            {DurableDashboard.Access, :session,
             [
               %{
                 durable: unquote(durable),
                 base_path: durable_dashboard_base,
                 live_socket_path: unquote(live_socket_path),
                 label: unquote(label)
               },
               unquote(resolver)
             ]} do
          live "/", DurableDashboard.Live.OverviewLive, :index
          live "/workflows", DurableDashboard.Live.WorkflowsLive, :index
          live "/workflows/:name", DurableDashboard.Live.WorkflowDetailLive, :show
          live "/workflows/:name/runs", DurableDashboard.Live.ExecutionsLive, :show
          live "/executions", DurableDashboard.Live.ExecutionsLive, :index
          live "/executions/:id", DurableDashboard.Live.WorkflowLive, :show
          live "/executions/:id/:tab", DurableDashboard.Live.WorkflowLive, :show
          live "/inputs", DurableDashboard.Live.InputsLive, :index
          live "/keys", DurableDashboard.Live.KeysLive, :index
          live "/queues", DurableDashboard.Live.QueuesLive, :index
          live "/schedules", DurableDashboard.Live.SchedulesLive, :index
          live "/schedules/:name", DurableDashboard.Live.SchedulesLive, :show
          live "/telemetry", DurableDashboard.Live.TelemetryLive, :index
          live "/settings", DurableDashboard.Live.SettingsLive, :index
        end
      end
    end
  end

  @doc false
  # Records a mount in the router being compiled; `:first` for its first one.
  def __mount__(router, as, prefix) do
    unless is_atom(as) and not is_nil(as) do
      raise ArgumentError, "dashboard_routes: :as must be an atom, got: #{inspect(as)}"
    end

    mounts = Module.get_attribute(router, :durable_dashboard_mounts, [])

    if as in mounts do
      raise ArgumentError, """
      the Durable dashboard is already mounted in #{inspect(router)} as #{inspect(as)}.

      To mount it again, for another Durable instance, give that mount its own name with :as

          dashboard_routes #{inspect(prefix)}, durable: MyApp.OtherDurable, as: :other_dashboard
      """
    end

    Module.put_attribute(router, :durable_dashboard_mounts, [as | mounts])
    if mounts == [], do: :first, else: :again
  end
end
