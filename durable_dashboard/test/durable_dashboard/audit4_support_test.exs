# Shared by the audit4_* page tests, which `Code.require_file/2` this file: an
# endpoint that re-raises a crashed page's own exception (TestEndpoint has no
# error view, so it raises "no 500 template" instead) and picks its router per
# request, plus the dashboard mounted the ways a host might mount it. Named
# `_test.exs` only so `mix test` doesn't warn about a stray file under test/.

defmodule Audit4Dash.ErrorHTML do
  @moduledoc false
  # Renders something, so a crashed page re-raises its own exception instead
  # of "no 500 template" (TestEndpoint has no error view).
  def render(template, _assigns), do: "audit4 " <> template
end

defmodule Audit4Dash.RootRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  use DurableDashboard.Router,
    mount: "/",
    durable: Durable,
    resolver: DurableDashboard.TestResolver
end

defmodule Audit4Dash.NestedRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  use DurableDashboard.Router,
    mount: "/admin/ops/durable/",
    durable: Durable,
    resolver: DurableDashboard.TestResolver
end

defmodule Audit4Dash.NamedRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  use DurableDashboard.Router,
    mount: "/named",
    durable: Audit4Dash.Named,
    resolver: DurableDashboard.TestResolver
end

defmodule Audit4Dash.ReadOnlyRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  # No resolver: the documented read-only default.
  use DurableDashboard.Router, mount: "/ro", durable: Durable
end

defmodule Audit4Dash.Bugs do
  @moduledoc "Workflows for the bugs below: ordinary things a host app's step might do."
  use Durable
  use Durable.Wait

  def failure("message_map"), do: {:error, %{message: %{"code" => 503, "body" => "down"}}}
  def failure("reason_map"), do: {:error, %{reason: %{status: 503}}}

  def failure("message_list"),
    do: {:error, %{message: [%{"field" => "name", "error" => "is required"}]}}

  def failure("stacktrace_list"), do: {:error, %{message: "x", stacktrace: [%{"file" => "a"}]}}

  workflow "audit4_bad_error" do
    step(:call_api, fn data -> Audit4Dash.Bugs.failure(data["mode"]) end)
  end

  workflow "audit4_select_form" do
    step(:ask, fn data ->
      _ =
        wait_for_form("equipment",
          fields: [
            %{
              name: :laptop,
              type: :select,
              options: [%{value: "mbp", label: "MacBook Pro"}, %{value: "x1", label: "ThinkPad"}]
            }
          ]
        )

      {:ok, data}
    end)
  end

  workflow "audit4_required_form" do
    step(:ask, fn data ->
      _ = wait_for_form("budget", fields: [%{name: :amount, type: :number, required: true}])
      {:ok, data}
    end)
  end
end

defmodule Audit4Dash.ScopedRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import DurableDashboard.Router

  scope "/admin" do
    dashboard_routes("/durable", resolver: DurableDashboard.TestResolver)
  end
end

defmodule Audit4Dash.BillingRepo do
  @moduledoc false
  # A second database, for a second Durable instance: two instances on one
  # repo would read the same tables. Created here; migrated by the tests that
  # start it.
  use Ecto.Repo, otp_app: :durable_dashboard, adapter: Ecto.Adapters.Postgres

  def config! do
    config =
      :durable_dashboard
      |> Application.fetch_env!(DurableDashboard.TestRepo)
      |> Keyword.update!(:database, &(&1 <> "_billing"))
      |> Keyword.put(:pool_size, 3)

    Application.put_env(:durable_dashboard, __MODULE__, config)
    _ = Ecto.Adapters.Postgres.storage_up(config)
  end
end

defmodule Audit4Dash.TwoRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import DurableDashboard.Router

  # One dashboard per Durable instance, inside a scope.
  scope "/admin" do
    dashboard_routes("/durable", resolver: DurableDashboard.TestResolver)

    dashboard_routes("/durable-billing",
      durable: Audit4Dash.Billing,
      as: :billing_dashboard,
      resolver: DurableDashboard.TestResolver
    )
  end
end

defmodule Audit4Dash.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :durable_dashboard

  socket "/live", Phoenix.LiveView.Socket, websocket: true, longpoll: true

  plug Plug.Session, store: :cookie, key: "_audit4_key", signing_salt: "audit4-salt"
  plug :route

  # The router is picked per request: `conn.private[:audit4_router]`.
  defp route(conn, _opts) do
    router = conn.private[:audit4_router] || DurableDashboard.TestRouter
    router.call(conn, router.init([]))
  end

  def config! do
    Application.put_env(:durable_dashboard, __MODULE__,
      url: [host: "localhost"],
      secret_key_base: String.duplicate("a", 64),
      live_view: [signing_salt: "audit4-live-salt"],
      pubsub_server: DurableDashboard.TestPubSub,
      render_errors: [formats: [html: Audit4Dash.ErrorHTML], layout: false],
      server: false
    )
  end
end

Audit4Dash.Endpoint.config!()
Audit4Dash.BillingRepo.config!()
