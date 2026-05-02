defmodule DurableDashboard do
  @moduledoc """
  Web dashboard for monitoring and managing Durable workflows.

  ## Usage

  Embed the dashboard in your host's router via the `dashboard_routes/2`
  macro. Phoenix LiveView's session validation requires the routes to live
  in the host endpoint's router, so a `forward`-style plug mounting cannot
  work for this dashboard's LiveView routes.

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router
        import DurableDashboard.Router

        scope "/", MyAppWeb do
          pipe_through :browser
          dashboard_routes "/dashboard", durable: MyApp.Durable
        end
      end

  See `DurableDashboard.Router.dashboard_routes/2` for the full option list
  and the URL surface the macro emits.
  """
end
