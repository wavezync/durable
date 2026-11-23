defmodule DurableDashboard.Live.QueuesLiveTest do
  @moduledoc "Queues & nodes: the queue row, pause/resume, nodes, the operations feed."
  use DurableDashboard.LiveCase

  @pause ~s(button[phx-click="toggle"][phx-value-queue="default"])

  test "the default queue shows its state and ready backlog", %{conn: conn} do
    {:ok, _id} = Durable.start(Fixtures.Payments, %{})
    {:ok, _id} = Durable.start(Fixtures.Payments, %{})

    {:ok, view, html} = live(conn, dash("/queues"))

    assert html =~ "default"
    assert has_element?(view, "tbody tr", "Idle")
    # Two runs waiting to be claimed, in the Ready column.
    assert has_element?(view, "tbody tr:first-child td:nth-child(4)", "2")
    assert has_element?(view, @pause, "Pause")
  end

  test "Pause stops the queue on every node and is recorded; Resume undoes it", %{conn: conn} do
    {:ok, view, html} = live(conn, dash("/queues"))
    assert html =~ "Nothing to report"

    html = view |> element(@pause) |> render_click()

    assert Durable.paused_queues!() == ["default"]
    assert has_element?(view, "tbody tr", "Paused")
    assert has_element?(view, @pause, "Resume")
    assert html =~ "on every node"
    assert has_element?(view, "li", "by admin@example.com")

    view |> element(@pause) |> render_click()

    assert Durable.paused_queues!() == []
    assert has_element?(view, @pause, "Pause")
    assert has_element?(view, "li", "Resumed")
  end

  test "a rollback cut short by a lost worker is in the operations feed", %{conn: conn} do
    {:ok, id} = Durable.start(Fixtures.Payments, %{})

    Durable.Activity.record(Durable.Config.get(Durable), "rollback_interrupted",
      workflow_id: id,
      queue: "default",
      details: %{reason: "zombie_detected", message: "No worker heartbeat"}
    )

    {:ok, view, _html} = live(conn, dash("/queues"))

    assert has_element?(view, "li", "lost its worker part-way through its rollback")
    assert has_element?(view, "li a[href='#{dash("/executions/#{id}")}']")
  end

  test "this node is listed as alive", %{conn: conn} do
    node_id = Durable.Config.get(Durable).node_id

    {:ok, view, _html} = live(conn, dash("/queues"))

    assert has_element?(view, "tr", node_id)
    assert has_element?(view, "tr", "This node")
    assert has_element?(view, "tr", "Alive")
  end
end
