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
  def call(conn, opts) do
    # `Plug.Static` passes a path it has no file for along untouched, and this
    # plug sits behind a `forward`: nothing after it answers. An unsent conn is
    # an error under Bandit and Cowboy, so say 404.
    case Plug.Static.call(conn, opts) do
      %Plug.Conn{state: state} = conn when state in [:unset, :set] ->
        conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()

      conn ->
        conn
    end
  end
end
