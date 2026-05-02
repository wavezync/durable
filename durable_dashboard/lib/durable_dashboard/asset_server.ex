defmodule DurableDashboard.AssetServer do
  @moduledoc """
  Plug that serves the dashboard's static assets (CSS, JS, woff2) from
  `priv/static/durable_dashboard/`. Plugged via `forward "/__assets__"`
  inside the host router by `DurableDashboard.Router.dashboard_routes/2`.
  """

  @behaviour Plug

  @opts Plug.Static.init(
          at: "/",
          from: {:durable_dashboard, "priv/static/durable_dashboard"},
          gzip: true,
          cache_control_for_etags: "public, max-age=31536000"
        )

  @impl true
  def init(_opts), do: @opts

  @impl true
  def call(conn, opts), do: Plug.Static.call(conn, opts)
end
