defmodule PhoenixDemoWeb.DurableResolver do
  @moduledoc """
  Dashboard access for the demo: everyone is an admin. A real app would look
  at its signed-in user and return `:viewer`, `:operator` or `:admin`.
  """
  @behaviour DurableDashboard.Access

  @impl true
  def resolve_user(_conn), do: "demo@example.com"

  @impl true
  def resolve_access(_user), do: :admin
end
