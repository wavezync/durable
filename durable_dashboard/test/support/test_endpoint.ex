defmodule DurableDashboard.TestEndpoint do
  @moduledoc """
  Minimal `Phoenix.Endpoint` for `live_isolated/3` tests. Not part of the
  shipped library — defined under `test/support/` and started by
  `test_helper.exs`.
  """

  use Phoenix.Endpoint, otp_app: :durable_dashboard

  socket "/live", Phoenix.LiveView.Socket, websocket: true, longpoll: true

  plug Plug.Session,
    store: :cookie,
    key: "_durable_dashboard_test_key",
    signing_salt: "test-salt"

  plug :put_secret_key_base

  defp put_secret_key_base(conn, _) do
    put_in(conn.secret_key_base, String.duplicate("a", 64))
  end
end
