defmodule DurableDashboard.Components.TimelineTabTest do
  @moduledoc """
  Render coverage for the `TimelineTab` LiveComponent: the Gantt rows render,
  each row is a clickable toggle, and an expanded row reveals the inline
  inspector (timing, I/O, logs, error). The expanded state is injected by
  passing `expanded:` straight through `update/2` — the same set the
  `toggle-row` event maintains.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Workflow.TimelineTab

  defp t(ms), do: DateTime.add(~U[2026-06-23 10:00:00.000000Z], ms, :millisecond)

  defp sample_steps do
    [
      %{
        id: "s-charge",
        step_name: "charge_customer",
        status: :completed,
        attempt: 1,
        started_at: t(0),
        completed_at: t(22),
        updated_at: t(22),
        inserted_at: t(0),
        duration_ms: 22,
        input: %{"amount" => 100},
        output: %{"charged" => true},
        error: nil,
        logs: [
          %{
            "level" => "info",
            "message" => "charging card",
            "timestamp" => "2026-06-23T10:00:00Z"
          }
        ]
      },
      %{
        id: "s-ship",
        step_name: "ship_order",
        status: :failed,
        attempt: 2,
        started_at: t(40),
        completed_at: t(120),
        updated_at: t(120),
        inserted_at: t(40),
        duration_ms: 80,
        input: %{},
        output: nil,
        error: %{"type" => "RuntimeError", "message" => "carrier timeout"},
        logs: []
      }
    ]
  end

  defp render_timeline(opts) do
    base = %{
      id: "timeline-1",
      steps: sample_steps(),
      workflow: %{status: :completed},
      now: t(200)
    }

    render_component(TimelineTab, Map.merge(base, Map.new(opts)))
  end

  test "renders a row per step with status pills and a clickable toggle" do
    html = render_timeline([])

    assert html =~ "charge_customer"
    assert html =~ "ship_order"
    # Each row is a toggle target.
    assert html =~ ~s(phx-click="toggle-row")
    assert html =~ ~s(phx-value-row="charge_customer")
    # Retry count surfaces on the row.
    assert html =~ "×2"
  end

  test "rows are collapsed by default — no inline inspector" do
    html = render_timeline([])

    refute html =~ ">started</span>"
    refute html =~ ">input</span>"
    refute html =~ "charging card"
  end

  test "an expanded row reveals timing, I/O and logs" do
    html = render_timeline(expanded: MapSet.new(["charge_customer"]))

    # Inline inspector sections — the stat strip carries the timing facts.
    assert html =~ ">started</span>"
    assert html =~ ">duration</span>"
    assert html =~ ">input</span>"
    assert html =~ ">output</span>"
    assert html =~ ">logs</span>"

    # I/O is syntax-highlighted JSON (the shared Core.json), not a raw dump.
    assert html =~ ~s(<span class="text-warning">100</span>)
    assert html =~ ~s(<span class="text-info">true</span>)

    # The step's captured logs render via the shared LogLine row.
    assert html =~ "charging card"
    assert html =~ "aria-expanded=\"true\""
  end

  test "an expanded failed row shows the error panel" do
    html = render_timeline(expanded: MapSet.new(["ship_order"]))

    assert html =~ ">error</span>"
    assert html =~ "carrier timeout"
    # The error is syntax-highlighted JSON, and with an error present the
    # "no logs" placeholder is suppressed in favour of the error panel.
    assert html =~ ~s(<span class="text-primary">&quot;type&quot;</span>)
    refute html =~ "No logs captured"
  end

  test "an expanded step with neither logs nor error shows the empty-logs note" do
    step = %{
      id: "s-quiet",
      step_name: "noop",
      status: :completed,
      attempt: 1,
      started_at: t(0),
      completed_at: t(5),
      updated_at: t(5),
      inserted_at: t(0),
      duration_ms: 5,
      input: %{},
      output: %{},
      error: nil,
      logs: []
    }

    html =
      render_component(TimelineTab, %{
        id: "timeline-quiet",
        steps: [step],
        workflow: %{status: :completed},
        now: t(50),
        expanded: MapSet.new(["noop"])
      })

    assert html =~ "No logs captured"
  end

  test "expanding one row leaves the other collapsed" do
    html = render_timeline(expanded: MapSet.new(["charge_customer"]))

    assert html =~ "charging card"
    refute html =~ "carrier timeout"
  end

  test "the chart is horizontally scrollable with a frozen gutter" do
    html = render_timeline([])

    # A scroll viewport with a min-width content wrapper so dense/long runs
    # overflow instead of crushing.
    assert html =~ "overflow-x-auto"
    assert html =~ ~r/min-width:\s*\d+px/
    # The step/status gutter is frozen on the left while the axis scrolls.
    assert html =~ "sticky left-0"
  end

  test "empty state when no steps have started" do
    html =
      render_component(TimelineTab, %{
        id: "timeline-empty",
        steps: [],
        workflow: %{status: :completed},
        now: t(0)
      })

    assert html =~ "No step executions yet"
  end
end
