defmodule DurableDashboard.Live.WorkflowsLiveTest do
  use DurableDashboard.LiveCase

  defp text(html),
    do:
      html
      |> String.replace("><", "> <")
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.split()
      |> Enum.join(" ")

  defp row(view, workflow), do: view |> element("tbody tr", workflow) |> render() |> text()

  describe "the catalog" do
    test "has one row per workflow that ran, with its numbers", %{conn: conn} do
      Fixtures.seed!()
      {:ok, view, html} = live(conn, dash("/workflows"))

      # Top-level workflows only: Moderation's child runs aren't a row of their own.
      assert text(html) =~ "5 workflows · numbers for the last 24h"

      for name <-
            ~w(process_payment fulfill_order expense_approval await_webhook moderate_content) do
        assert has_element?(view, ~s(a[href="/dashboard/workflows/#{name}"]), name)
      end

      # Two runs, one failed: 50%.
      assert row(view, "process_payment") =~ "process_payment"
      assert row(view, "process_payment") =~ ~r/Payments 2 50%/

      # Waiting right now, rather than idle.
      assert row(view, "expense_approval") =~ "Waiting"
      assert row(view, "process_payment") =~ "idle"
    end

    test "says so before anything has run", %{conn: conn} do
      {:ok, _view, html} = live(conn, dash("/workflows"))
      assert html =~ "No workflows have run yet"
      assert text(html) =~ "0 workflows"
    end

    test "the range switch patches ?range=", %{conn: conn} do
      Fixtures.run!(Fixtures.Payments)
      {:ok, view, _html} = live(conn, dash("/workflows"))

      view |> element(~s(a[href="/dashboard/workflows?range=30d"])) |> render_click()

      assert_patch(view, "/dashboard/workflows?range=30d")
      assert render(view) =~ "numbers for the last 30d"
      assert has_element?(view, ~s(a[href="/dashboard/workflows/process_payment"]))
    end
  end

  describe "a workflow's page" do
    setup do
      Fixtures.run!(Fixtures.Orders)
      Fixtures.run!(Fixtures.Orders, %{"decline" => true})
      :ok
    end

    test "shows its numbers", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/workflows/fulfill_order"))

      kpis = view |> element("section", "Failure rate") |> render() |> text()
      assert kpis =~ "Runs 2 0 running · 0 waiting"
      assert kpis =~ "Failure rate 50% 1 failed"
    end

    test "draws its structure, compensation included", %{conn: conn} do
      {:ok, view, html} = live(conn, dash("/workflows/fulfill_order"))

      assert html =~ "Structure"

      for step <- ~w(reserve charge ship) do
        assert has_element?(view, ~s([data-tip-title="#{step}"]))
      end

      assert has_element?(view, ~s([data-tip-title="Compensation release"]))
    end

    test "lists its steps with their numbers", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/workflows/fulfill_order"))

      steps = view |> element("table", "p95 vs the run") |> render() |> text()

      for step <- ~w(reserve charge ship) do
        assert steps =~ step
      end

      # The compensation is listed, and marked as one.
      assert steps =~ "compensation"
    end

    test "groups its errors and links to the runs that hit them", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/workflows/fulfill_order"))

      errors = view |> element("section", "grouped by type + message") |> render()
      assert errors =~ "payment_failed"
      assert errors =~ "1 rolled back"

      href =
        "/dashboard/workflows/fulfill_order/runs?" <>
          URI.encode_query(status: "failed,compensated,compensation_failed", q: "step:charge")

      assert has_element?(view, ~s(a[href="#{href}"]), "View runs")
    end

    test "describes the definition as compiled", %{conn: conn} do
      {:ok, _view, html} = live(conn, dash("/workflows/fulfill_order"))
      html = text(html)

      assert html =~ "Steps 3 steps · 1 compensation"
      assert html =~ "Timeout none"
      assert html =~ "Queue default"
      assert html =~ "Retries default (1 attempt)"
    end

    test "links to its runs and switches range", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/workflows/fulfill_order"))

      assert has_element?(
               view,
               ~s(a[href="/dashboard/workflows/fulfill_order/runs"]),
               "View runs"
             )

      view |> element(~s(a[href="/dashboard/workflows/fulfill_order?range=1h"])) |> render_click()
      assert_patch(view, "/dashboard/workflows/fulfill_order?range=1h")
      assert render(view) =~ "where the time and the failures go · last 1h"
    end
  end

  test "a workflow whose runs are all still going has empty charts that say so", %{conn: conn} do
    Fixtures.run!(Fixtures.Approvals)
    {:ok, _view, html} = live(conn, dash("/workflows/expense_approval"))

    assert html =~ "No runs finished in this window"
    assert html =~ "No runs completed in this window"
  end

  test "an unknown workflow says it hasn't run yet", %{conn: conn} do
    {:ok, _view, html} = live(conn, dash("/workflows/no_such_workflow"))

    assert html =~ "no_such_workflow hasn&#39;t run yet"
    refute html =~ "Structure"
  end
end
