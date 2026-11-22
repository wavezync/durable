Code.require_file("../audit4_support_test.exs", __DIR__)

defmodule DurableDashboard.Live.Audit4AccessTest do
  @moduledoc """
  Hardening: every event that changes something is refused on the server for
  a session that may not send it — pushed straight at the LiveView, the way a
  hand-written websocket client would, with nothing in the markup to click.
  Checked for a viewer, and for a dashboard mounted without a resolver (the
  documented read-only default) however privileged the host's user is.
  """
  use DurableDashboard.LiveCase

  import Ecto.Query

  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, StepExecution, WorkflowExecution}

  @endpoint Audit4Dash.Endpoint

  setup_all do
    start_supervised!(Audit4Dash.Endpoint)
    :ok
  end

  setup do
    test = self()
    handler = "audit4-access-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:durable_dashboard, :action],
      fn _event, _measurements, meta, _ -> send(test, {:action, meta.action, meta.result}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp repo, do: DurableDashboard.TestRepo

  # Everything an action could change.
  defp state do
    %{
      runs:
        repo().all(
          from(w in WorkflowExecution,
            order_by: w.id,
            select: {w.id, w.status, w.holds_key, w.input, w.context, w.error, w.scheduled_at}
          )
        ),
      inputs:
        repo().all(from(p in PendingInput, order_by: p.id, select: {p.id, p.status, p.response})),
      events: repo().all(from(e in PendingEvent, order_by: e.id, select: {e.id, e.status})),
      steps: repo().aggregate(StepExecution, :count),
      paused: Durable.paused_queues!(),
      schedules: Enum.map(Durable.list_schedules!(), &{&1.name, &1.enabled, &1.last_run_at})
    }
  end

  defp seed do
    {:ok, keyed} = Durable.start(Fixtures.Invoices, %{}, key: "invoice:1", inline: true)

    runs = %{
      failed: Fixtures.run!(Fixtures.Holds),
      waiting_input: Fixtures.run!(Fixtures.Approvals),
      waiting_event: Fixtures.run!(Fixtures.Webhooks),
      held: Fixtures.run!(Fixtures.HoldAwaitingCustomer),
      completed: Fixtures.run!(Fixtures.Payments),
      keyed: keyed
    }

    Fixtures.schedule!("card_sweep")
    Fixtures.schedule!("off_sweep", enabled: false)
    runs
  end

  defp actions do
    receive do
      {:action, action, result} -> [{action, result} | actions()]
    after
      0 -> []
    end
  end

  # Pushes every mutating event the dashboard has; returns the pages' refusals.
  defp push_everything(conn, base, runs) do
    for {_kind, id} <- runs do
      {:ok, view, _html} = live(conn, "#{base}/executions/#{id}")

      for {event, params} <- [
            {"cancel", %{}},
            {"retry", %{}},
            {"rerun", %{}},
            {"rerun", %{"input" => ~s({"forged": true})}},
            {"release-key", %{}},
            {"rollback", %{}}
          ] do
        render_click(view, event, params)
        assert has_element?(view, "[role=alert]", "You don't have permission to do that.")
      end
    end

    {:ok, view, _html} = live(conn, "#{base}/executions")
    for {_kind, id} <- runs, do: render_click(view, "toggle", %{"id" => id})

    for action <- ~w(retry rerun cancel release) do
      render_click(view, "toggle-all", %{})
      render_click(view, "bulk", %{"action" => action})
      assert has_element?(view, "[role=status]", "You don't have permission to do that.")
    end

    for input <- repo().all(from(p in PendingInput, where: p.status == :pending)),
        {event, params} <- [
          {"decide", %{"decision" => "approve"}},
          {"decide", %{"decision" => "reject", "comment" => "forged"}},
          {"answer", %{"text" => "forged", "choice" => "a", "fields" => %{"a" => "1"}}}
        ] do
      {:ok, view, _html} = live(conn, "#{base}/inputs?id=#{input.id}")
      render_submit(view, event, Map.put(params, "request", input.id))
    end

    {:ok, view, _html} = live(conn, "#{base}/inputs?tab=events")
    event = repo().one!(from(e in PendingEvent, where: e.event_name == "webhook_received"))
    render_click(view, "compose", %{"id" => event.id})
    render_submit(view, "send", %{"payload" => ~s({"forged": true})})
    assert has_element?(view, "[role=alert]", "You don't have permission to do that.")

    {:ok, view, _html} = live(conn, "#{base}/queues")
    render_click(view, "toggle", %{"queue" => "default"})
    assert has_element?(view, "[role=alert]", "You don't have permission to do that.")

    for name <- ~w(card_sweep off_sweep), event <- ~w(toggle run-now) do
      {:ok, view, _html} = live(conn, "#{base}/schedules")
      render_click(view, event, %{"name" => name})
      assert has_element?(view, "[role=alert]", "You don't have permission to do that.")

      {:ok, view, _html} = live(conn, "#{base}/schedules/#{name}")
      render_click(view, event, %{"name" => name})
    end

    {:ok, view, _html} = live(conn, "#{base}/settings")
    render_click(view, "prune", %{})
    assert render(view) =~ "Pruning needs admin access."
  end

  @all_actions ~w(cancel retry rerun release_key rollback release provide_input send_event
                  pause_queue disable_schedule enable_schedule trigger_schedule prune)a

  defp assert_all_refused(before) do
    assert state() == before

    attempts = actions()
    assert Enum.all?(attempts, fn {_action, result} -> result == {:error, :forbidden} end)
    # Every kind of action was really attempted, not skipped by a guard on the way.
    assert attempts |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(@all_actions)
  end

  @tag role: :viewer
  test "a viewer who pushes every mutating event changes nothing", %{conn: conn} do
    runs = seed()
    before = state()

    push_everything(conn, "/dashboard", runs)

    assert_all_refused(before)
  end

  test "a dashboard mounted without a resolver is read-only, even for the host's admin",
       %{conn: conn} do
    runs = seed()
    before = state()
    conn = Plug.Conn.put_private(conn, :audit4_router, Audit4Dash.ReadOnlyRouter)

    {:ok, view, html} = live(conn, "/ro/executions/#{runs.failed}")
    refute has_element?(view, "button[phx-click]", "Retry")
    refute html =~ ~s(phx-click="cancel")

    push_everything(conn, "/ro", runs)

    assert_all_refused(before)
  end

  @tag role: :operator
  test "an operator can't prune or switch a schedule, and the page still works after", %{
    conn: conn
  } do
    seed()
    before = state()

    {:ok, view, _html} = live(conn, dash("/settings"))
    render_click(view, "prune", %{})
    assert render(view) =~ "Pruning needs admin access."

    for name <- ~w(card_sweep off_sweep) do
      {:ok, view, _html} = live(conn, dash("/schedules/#{name}"))
      render_click(view, "toggle", %{"name" => name})
      assert has_element?(view, "[role=alert]", "You don't have permission to do that.")
    end

    assert state() == before

    assert actions() == [
             prune: {:error, :forbidden},
             disable_schedule: {:error, :forbidden},
             enable_schedule: {:error, :forbidden}
           ]
  end

  test "a session whose access level isn't one of the three is a viewer", %{conn: conn} do
    for forged <- ["root", "Admin", "", nil, :admin, 2, ["admin"]] do
      {:cont, socket} =
        DurableDashboard.Access.on_mount(
          :default,
          %{},
          %{"access" => forged, "user" => "x"},
          %Phoenix.LiveView.Socket{}
        )

      assert socket.assigns.access == :viewer
    end

    # A resolver that answers with anything else fails the page load, loudly.
    defmodule BadResolver do
      @behaviour DurableDashboard.Access
      def resolve_user(_conn), do: %{email: "x@example.com"}
      def resolve_access(_user), do: :superuser
    end

    assert_raise ArgumentError, ~r/must return :viewer, :operator or :admin/, fn ->
      DurableDashboard.Access.session(conn, %{durable: Durable}, BadResolver)
    end
  end

  describe "the asset route" do
    test "serves the bundle and nothing outside it", %{conn: conn} do
      assert get(conn, dash("/__assets__/app.js")).status == 200
      assert get(conn, dash("/__assets__/app.css")).status == 200

      for path <- ~w(/__assets__/..%2f..%2f..%2fmix.exs /__assets__/%2e%2e/%2e%2e/%2e%2e/mix.exs
                     /__assets__/..%5c..%5cmix.exs /__assets__/%00 /__assets__/app.css%00.png
 /__assets__/app.js/../../../../mix.exs) do
        assert_raise Plug.Static.InvalidPathError, fn -> get(conn, dash(path)) end
      end

      # Nothing is served for these.
      for path <- ~w(/__assets__/....//....//mix.exs /__assets__/nope.js /__assets__/) do
        conn = get(conn, dash(path))
        assert conn.status == 404
        assert conn.resp_body == ""
      end
    end
  end
end
