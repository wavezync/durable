defmodule DurableDashboard.Live.CommandPaletteTest do
  @moduledoc """
  The ⌘K palette inside a real page. Its JS hook sends events with
  `pushEventTo(this.el)` — to the component — so the tests push them with
  `with_target/2`.
  """
  use DurableDashboard.LiveCase

  @palette "#command-palette"

  defp open(conn) do
    {:ok, view, _html} = live(conn, dash())
    hook(view, "palette:open")
    view
  end

  defp search(view, q), do: view |> element(@palette <> " form") |> render_change(%{value: q})

  defp hook(view, event, params \\ %{}),
    do: view |> with_target(@palette) |> render_hook(event, params)

  defp labels(view) do
    view
    |> element(@palette <> " [role=listbox]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[role=option] span.flex-1")
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  defp groups(view) do
    view
    |> element(@palette <> " [role=listbox]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[role=presentation] > div:first-child")
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  test "opening lists the pages, then the most recent runs", %{conn: conn} do
    ids = for _ <- 1..3, do: Fixtures.run!(Fixtures.Payments)
    view = open(conn)

    assert has_element?(view, ~s(#{@palette}[data-open="true"]))
    assert groups(view) == ["Go to", "Recent runs"]

    assert Enum.take(labels(view), 8) ==
             [
               "Overview",
               "Runs",
               "Workflows",
               "Inbox",
               "Queues & nodes",
               "Schedules",
               "Telemetry",
               "Settings"
             ]

    for id <- ids, do: assert(render(view) =~ String.slice(id, 0, 8))
  end

  test "typing filters pages and finds workflows by name", %{conn: conn} do
    Fixtures.run!(Fixtures.Payments)
    view = open(conn)

    search(view, "sched")
    assert labels(view) == ["Schedules"]

    search(view, "pay")
    assert "Workflows" in groups(view)
    assert "process_payment" in labels(view)
    refute "Overview" in labels(view)
  end

  test "a run id finds any run, not just the recent ones", %{conn: conn} do
    [oldest | _] = for _ <- 1..8, do: Fixtures.run!(Fixtures.Payments)
    prefix = String.slice(oldest, 0, 8)
    view = open(conn)

    # The snapshot only holds the newest six…
    refute render(view) =~ prefix

    # …but an id-shaped query is looked up in the database.
    search(view, prefix)
    assert groups(view) == ["Runs"]
    assert render(view) =~ prefix
  end

  test "schedules are found by name, with their cadence and state", %{conn: conn} do
    Fixtures.schedule!("card_sweep", cron: "*/5 * * * *")
    Fixtures.schedule!("card_audit", cron: "0 2 * * *", enabled: false)
    view = open(conn)

    search(view, "card")
    assert groups(view) == ["Schedules"]
    assert labels(view) == ["card_audit", "card_sweep"]

    html = view |> element(@palette <> " [role=listbox]") |> render()
    assert html =~ DurableDashboard.Cron.describe("*/5 * * * *")
    assert html =~ "On"
    assert html =~ "Off"
  end

  test "a saved view is offered by name, and Enter opens it", %{conn: conn} do
    view = open(conn)

    search(view, "fail")
    assert labels(view) == ["Failed runs"]

    assert {:error, {:live_redirect, %{to: to}}} = hook(view, "palette:activate")
    assert to == "/dashboard/executions?status=failed,compensated,compensation_failed"
  end

  test "arrow keys move the selection and Enter opens it", %{conn: conn} do
    view = open(conn)

    assert has_element?(view, ~s(#{@palette} [role=option][aria-selected]), "Overview")

    hook(view, "palette:move", %{"dir" => "down"})
    assert has_element?(view, ~s(#{@palette} [role=option][aria-selected]), "Runs")

    # Up from the top wraps to the last result; down from there wraps back.
    hook(view, "palette:move", %{"dir" => "up"})
    hook(view, "palette:move", %{"dir" => "up"})
    assert has_element?(view, ~s(#{@palette} [role=option][aria-selected]), "Settings")

    hook(view, "palette:move", %{"dir" => "down"})
    assert has_element?(view, ~s(#{@palette} [role=option][aria-selected]), "Overview")
    assert {:error, {:live_redirect, %{to: "/dashboard"}}} = hook(view, "palette:activate")
  end

  test "a workflow result opens the workflow's page", %{conn: conn} do
    Fixtures.run!(Fixtures.Orders)
    view = open(conn)

    search(view, "fulfill")

    assert {:error, {:live_redirect, %{to: "/dashboard/workflows/fulfill_order"}}} =
             hook(view, "palette:activate")
  end

  test "no matches says what to try", %{conn: conn} do
    view = open(conn)

    search(view, "zzzz")
    html = render(view)

    assert html =~ "No matches for"
    assert html =~ "zzzz"
    assert labels(view) == []

    # Enter with nothing to open stays put.
    assert is_binary(hook(view, "palette:activate"))
    assert has_element?(view, ~s(#{@palette}[data-open="true"]))
  end

  test "closing hides it and forgets the query", %{conn: conn} do
    view = open(conn)
    search(view, "pay")

    hook(view, "palette:close")
    assert has_element?(view, ~s(#{@palette}[data-open="false"]))

    hook(view, "palette:open")
    assert "Overview" in labels(view)
  end
end
