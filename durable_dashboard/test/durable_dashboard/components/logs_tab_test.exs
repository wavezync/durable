defmodule DurableDashboard.Components.LogsTabTest do
  @moduledoc """
  Render-level coverage for the `LogsTab` LiveComponent. Filter interactions
  exercise `handle_event/3` indirectly via `render_component/3` (which goes
  mount → update → render); deeper interactive coverage with phx-click
  events lives in `workflow_live_test.exs`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Workflow.LogsTab

  defp sample_steps_with_logs do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    [
      %{
        id: "s-1",
        step_name: "validate",
        logs: [
          %{"level" => "info", "message" => "Validating order", "timestamp" => now},
          %{"level" => "debug", "message" => "Order id 42", "timestamp" => now}
        ]
      },
      %{
        id: "s-2",
        step_name: "charge_card",
        logs: [
          %{"level" => "warning", "message" => "Card expired soon", "timestamp" => now},
          %{"level" => "error", "message" => "Charge declined", "timestamp" => now}
        ]
      }
    ]
  end

  test "renders empty state when no steps have logs" do
    html =
      render_component(LogsTab,
        id: "logs-1",
        steps: [%{step_name: "x", logs: []}]
      )

    assert html =~ "No log entries match"
  end

  test "renders all log lines across all steps by default" do
    html =
      render_component(LogsTab,
        id: "logs-2",
        steps: sample_steps_with_logs()
      )

    assert html =~ "Validating order"
    assert html =~ "Order id 42"
    assert html =~ "Card expired soon"
    assert html =~ "Charge declined"
  end

  test "renders the level filter with counts" do
    html =
      render_component(LogsTab,
        id: "logs-3",
        steps: sample_steps_with_logs()
      )

    # Each level appears as an <option>
    assert html =~ ~s(value="all")
    assert html =~ ~s(value="info")
    assert html =~ ~s(value="error")

    # Counts are rendered
    assert html =~ "(1)" or html =~ "(2)"
  end

  test "renders the step filter with each step's name" do
    html =
      render_component(LogsTab,
        id: "logs-4",
        steps: sample_steps_with_logs()
      )

    assert html =~ ~s(value="validate")
    assert html =~ ~s(value="charge_card")
  end

  test "every entry shows the step name as a code chip" do
    html =
      render_component(LogsTab,
        id: "logs-5",
        steps: sample_steps_with_logs()
      )

    assert html =~ "validate"
    assert html =~ "charge_card"
  end

  test "level styling applies the right semantic color" do
    html =
      render_component(LogsTab,
        id: "logs-6",
        steps: sample_steps_with_logs()
      )

    assert html =~ "text-destructive"
    assert html =~ "text-warning"
    assert html =~ "text-info"
  end
end
