defmodule DurableDashboard.TestResolver do
  @moduledoc """
  Access for page tests: the user is `conn.assigns.current_user`
  (`DurableDashboard.LiveCase` sets one; tag a test `@tag role: :viewer` to
  change it), and its `:role` is the access level.
  """
  @behaviour DurableDashboard.Access

  @impl true
  def resolve_user(conn), do: conn.assigns[:current_user]

  @impl true
  def resolve_access(%{role: role}) when role in [:viewer, :operator, :admin], do: role
  def resolve_access(_user), do: :viewer
end

defmodule DurableDashboard.TestRouter do
  @moduledoc "Mounts the dashboard at /dashboard, the way a host app does. Test-only."
  use Phoenix.Router
  import Phoenix.LiveView.Router

  use DurableDashboard.Router,
    mount: "/dashboard",
    durable: Durable,
    resolver: DurableDashboard.TestResolver
end
