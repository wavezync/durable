defmodule DurableDashboard.Live.OverviewLiveTest do
  use DurableDashboard.LiveCase

  # The node registry beats in handle_continue; a sys call waits for it, so
  # the node is registered before the page counts nodes.
  defp await_node_registry do
    {_, pid, _, _} =
      Durable
      |> Durable.Supervisor.supervisor_name()
      |> Supervisor.which_children()
      |> List.keyfind(Durable.NodeRegistry, 0)

    :sys.get_state(pid)
  end

  # Text with a space between elements, the way it reads on screen.
  defp text(html),
    do:
      html
      |> String.replace("><", "> <")
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> squish()

  defp squish(s), do: s |> String.split() |> Enum.join(" ")

  defp kpi(view, label) do
    view
    |> element(~s([aria-label="Key metrics"] [data-tip-title="#{label}"]))
    |> render()
    |> text()
  end

  describe "headline numbers" do
    test "count the runs in the window, failures and what's waiting", %{conn: conn} do
      Fixtures.seed!()
      {:ok, view, _html} = live(conn, dash())

      # Seven top-level runs; the Moderation run's two child runs aren't counted.
      assert kpi(view, "Runs started") =~ "Runs started 7"

      # process_payment declined (failed) + fulfill_order declined (compensated)
      # are the failures; the waiting pair stays out of "finished".
      assert kpi(view, "Failure rate") =~ "· 2 failed"

      assert kpi(view, "Waiting") == "Waiting 2 1 event · 1 input · 0 sleep"
      assert kpi(view, "Backlog") =~ "ready to run now · 1 queue"
    end

    test "say so when nothing has run", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash())

      assert kpi(view, "Runs started") =~ "Runs started 0"
      assert kpi(view, "Waiting") == "Waiting 0 0 event · 0 input · 0 sleep"
      assert render(view) =~ "No runs finished in this window"
      assert render(view) =~ "Nothing failed in the last 24h."
      assert render(view) =~ "No steps ran in the last 24h."
    end
  end

  test "the subtitle counts workflows, queues and nodes with the right plurals", %{conn: conn} do
    await_node_registry()
    Fixtures.run!(Fixtures.Payments)

    {:ok, _view, html} = live(conn, dash())

    assert text(html) =~ "1 workflow · 1 queue · 1 node · updated live"
  end

  test "the range switch patches ?range= and the page keeps rendering", %{conn: conn} do
    Fixtures.run!(Fixtures.Payments, %{"decline" => true})
    {:ok, view, _html} = live(conn, dash())

    view |> element(~s(a[href="/dashboard?range=7d"])) |> render_click()

    assert_patch(view, "/dashboard?range=7d")
    assert render(view) =~ "grouped by error · last 7d"
    assert render(view) =~ "process_payment"
  end

  test "an unknown range falls back to 24h", %{conn: conn} do
    {:ok, _view, html} = live(conn, dash("?range=forever"))
    assert html =~ "grouped by error · last 24h"
  end

  test "failing workflows lists process_payment with its top error and step", %{conn: conn} do
    Fixtures.run!(Fixtures.Payments)
    Fixtures.run!(Fixtures.Payments, %{"decline" => true})

    {:ok, view, _html} = live(conn, dash())

    row =
      view
      |> element(
        ~s(a[href="/dashboard/workflows/process_payment/runs?status=failed,compensated,compensation_failed"])
      )
      |> render()
      |> text()

    assert row =~ "process_payment"
    assert row =~ "at authorize"

    html = render(view)
    assert html =~ "ArgumentError: card declined"
    # One of two finished runs failed.
    assert html =~ "50%"
  end

  test "slowest steps lists the steps that ran, without compensations", %{conn: conn} do
    Fixtures.run!(Fixtures.Orders, %{"decline" => true})
    {:ok, view, _html} = live(conn, dash())

    slowest = view |> element("table", "Attempts") |> render() |> text()

    assert slowest =~ "fulfill_order › reserve"
    assert slowest =~ "fulfill_order › charge"
    refute slowest =~ "release"
  end

  test "the live feed shows lifecycle events broadcast while the page is open", %{conn: conn} do
    {:ok, view, html} = live(conn, dash())
    assert html =~ "Waiting for the next event…"

    id = Fixtures.run!(Fixtures.Payments)
    html = render(view)

    refute html =~ "Waiting for the next event…"
    assert has_element?(view, ~s(a[href="/dashboard/executions/#{id}"]), "process_payment")
    assert html =~ "completed"
  end

  test "a failed run reads 'failed at' its step in the feed", %{conn: conn} do
    {:ok, view, _html} = live(conn, dash())

    id = Fixtures.run!(Fixtures.Payments, %{"decline" => true})

    assert has_element?(view, ~s(a[href="/dashboard/executions/#{id}"]), "failed at authorize")
    assert has_element?(view, ~s(a[href="/dashboard/executions/#{id}"]), "started")
  end

  # Durable.Stats.overview/1 counts top-level runs only; the tooltip says so.
  test "the Runs started tooltip describes what it counts", %{conn: conn} do
    Fixtures.run_family!(Fixtures.Moderation)
    {:ok, view, _html} = live(conn, dash())

    tip =
      view
      |> element(~s([aria-label="Key metrics"] [data-tip-title="Runs started"]))
      |> render()

    assert kpi(view, "Runs started") =~ "Runs started 1"
    assert tip =~ "top-level only"
  end
end
