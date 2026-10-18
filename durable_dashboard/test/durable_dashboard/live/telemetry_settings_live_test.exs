defmodule DurableDashboard.Live.TelemetrySettingsLiveTest do
  use DurableDashboard.LiveCase

  defp text(html),
    do:
      html
      |> String.replace("><", "> <")
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  describe "Telemetry" do
    test "lists every event group Durable emits, and the dashboard's audit event", %{conn: conn} do
      {:ok, _view, html} = live(conn, dash("/telemetry"))

      for group <- [
            "Runs",
            "Steps",
            "Compensations",
            "Queue",
            "Schedules, waits and retention",
            "Dashboard"
          ] do
        assert html =~ group
      end

      for event <- [[:durable_dashboard, :action] | Durable.Telemetry.events()] do
        assert html =~ Phoenix.HTML.html_escape(inspect(event)) |> Phoenix.HTML.safe_to_string()
      end
    end

    test "shows a handler attached to Durable's events under Listening now", %{conn: conn} do
      :ok =
        :telemetry.attach(
          "dashboard-test-handler",
          [:durable, :workflow, :stop],
          fn _event, _measurements, _meta, _config -> :ok end,
          nil
        )

      on_exit(fn -> :telemetry.detach("dashboard-test-handler") end)

      {:ok, view, _html} = live(conn, dash("/telemetry"))

      listening = view |> element("section", "Listening now") |> render() |> text()
      assert listening =~ ~s("dashboard-test-handler")
      assert listening =~ "1 event"
    end

    # Sync tests run after the async ones, so no other test's handler is attached.
    test "says nothing is listening when no handler is attached", %{conn: conn} do
      {:ok, _view, html} = live(conn, dash("/telemetry"))
      assert html =~ "Nothing is attached to Durable"
    end

    test "counts events that fire while the page is open", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/telemetry"))

      Fixtures.run!(Fixtures.Payments)
      send(view.pid, :sample)

      row = view |> element("tr", "[:durable, :workflow, :stop]") |> render() |> text()
      assert row =~ ~r/ 1$/

      # Two steps, each stopped once.
      row = view |> element("tr", "[:durable, :step, :stop]") |> render() |> text()
      assert row =~ ~r/ 2$/
    end

    test "lists Durable's metric definitions when telemetry_metrics is installed", %{conn: conn} do
      {:ok, _view, html} = live(conn, dash("/telemetry"))

      if Code.ensure_loaded?(Telemetry.Metrics) do
        assert html =~ "durable.workflow.stop.duration"
        assert html =~ "never run ids"
      else
        assert html =~ "telemetry_metrics"
      end
    end
  end

  describe "Settings" do
    test "shows the schema up to date at the latest migration", %{conn: conn} do
      {:ok, _view, html} = live(conn, dash("/settings"))

      assert text(html) =~ "Up to date at v#{Durable.Migration.Migrator.current_version()}."
      assert html =~ "add_deadlines_and_history"
    end

    test "describes the instance", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/settings"))

      instance = view |> element("section", "Postgres schema") |> render() |> text()
      assert instance =~ "Repo DurableDashboard.TestRepo"
      assert instance =~ "Postgres schema durable"
      assert instance =~ "PubSub DurableDashboard.TestPubSub"
      assert instance =~ "doesn't claim work"
    end

    test "shows the current user's access: admin", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/settings"))

      access = view |> element("section", "who may change things") |> render() |> text()
      assert access =~ "You: admin@example.com · Admin"
    end

    @tag role: :viewer
    test "shows the current user's access: viewer", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/settings"))

      access = view |> element("section", "who may change things") |> render() |> text()
      assert access =~ "You: viewer@example.com · Viewer"
    end

    test "lists the queues this node is configured with", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/settings"))

      queues = view |> element("section", "Queues on this node") |> render() |> text()
      assert queues =~ "queue_enabled: false"
      assert queues =~ ~r/default \d+ \d+ (ms|s)/
    end

    test "says retention isn't configured, with no Prune now button", %{conn: conn} do
      {:ok, view, html} = live(conn, dash("/settings"))

      assert html =~ "not configured — runs are kept forever"
      refute has_element?(view, ~s(button[phx-click="prune"]))
    end
  end
end
