defmodule DurableDashboard.LiveCase do
  @moduledoc """
  Page tests: the real LiveViews, mounted through `TestRouter` against a
  Durable instance on `TestRepo` (queues off — runs are driven inline by
  `DurableDashboard.Fixtures`).

  Each test gets a shared SQL sandbox, its own Durable, and a `conn` whose
  user is an admin. Tag a test `@tag role: :viewer` (or `:operator`) to see
  the page as someone with less access.

      use DurableDashboard.LiveCase

      test "lists runs", %{conn: conn} do
        Fixtures.run!(Fixtures.Payments)
        {:ok, view, html} = live(conn, "/dashboard/executions")
      end

  Not async: the dashboard's LiveViews and Durable's processes share the
  test's connection.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import DurableDashboard.LiveCase

      alias DurableDashboard.Fixtures

      @endpoint DurableDashboard.TestEndpoint
    end
  end

  setup tags do
    owner = Sandbox.start_owner!(DurableDashboard.TestRepo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    start_supervised!(
      {Durable,
       repo: DurableDashboard.TestRepo, queue_enabled: false, pubsub: DurableDashboard.TestPubSub}
    )

    role = Map.get(tags, :role, :admin)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.assign(:current_user, %{email: "#{role}@example.com", role: role})

    {:ok, conn: conn}
  end

  @doc "The dashboard path for `path` (`\"/executions\"` → `\"/dashboard/executions\"`)."
  def dash(path \\ ""), do: "/dashboard" <> path
end
