defmodule DurableDashboard.Live.HarnessTest do
  @moduledoc "The page-test harness itself: fixtures produce the runs the pages expect."
  use DurableDashboard.LiveCase

  test "the fixtures produce one run of every kind" do
    ids = Fixtures.seed!()

    assert %{
             completed: :completed,
             failed: :failed,
             compensated: :compensated,
             fulfilled: :completed,
             waiting_input: :waiting,
             waiting_event: :waiting,
             family: :completed
           } == Map.new(ids, fn {kind, id} -> {kind, Fixtures.get_run!(id).status} end)
  end

  test "the dashboard mounts through the test router", %{conn: conn} do
    {:ok, _view, html} = live(conn, dash())
    assert html =~ "Overview"
  end
end
