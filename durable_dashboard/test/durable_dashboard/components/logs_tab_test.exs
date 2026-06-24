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

  test "error and warning rows get a tinted left accent" do
    html =
      render_component(LogsTab,
        id: "logs-tint",
        steps: sample_steps_with_logs()
      )

    assert html =~ "border-l-destructive"
    assert html =~ "bg-destructive/5"
    assert html =~ "border-l-warning"
  end

  test "a JSON message shows compact inline and pretty-prints in the expanded fields table" do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    steps = [
      %{
        id: "s-json",
        step_name: "emit",
        logs: [
          %{
            "level" => "info",
            "message" => ~s({"order_id":42,"total":9.99}),
            "timestamp" => now
          }
        ]
      }
    ]

    html = render_component(LogsTab, id: "logs-json", steps: steps)

    assert html =~ "<details"
    assert html =~ "order_id"
    # Syntax-highlighted in the expanded message block: the key renders in the
    # primary color, the numeric value in the warning color (separate spans).
    assert html =~ ~s(<span class="text-primary">&quot;total&quot;</span>)
    assert html =~ ~s(<span class="text-warning">9.99</span>)
  end

  test "an embedded Elixir map in the message is highlighted, not dumped as text" do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    steps = [
      %{
        id: "s-elixir",
        step_name: "gather",
        logs: [
          %{
            "level" => "info",
            "message" =>
              ~S|[Cron] Metrics gathered: %{"active_users" => 491, "error_rate" => 0.046}|,
            "timestamp" => now
          }
        ]
      }
    ]

    html = render_component(LogsTab, id: "logs-elixir", steps: steps)

    # The text prefix survives, and the map is syntax-highlighted (separate
    # spans), not rendered as a flat `%{...}` blob.
    assert html =~ "[Cron] Metrics gathered:"
    assert html =~ ~s(<span class="text-primary">&quot;active_users&quot;</span>)
    assert html =~ ~s(<span class="text-warning">491</span>)
  end

  test "metadata: meaningful keys inline (key=value), source noise filtered, all keys in detail" do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    steps = [
      %{
        id: "s-meta",
        step_name: "emit",
        logs: [
          %{
            "level" => "info",
            "message" => "plain text line",
            "timestamp" => now,
            "metadata" => %{"request_id" => "req-abc", "user_id" => 7, "line" => 33}
          }
        ]
      }
    ]

    html = render_component(LogsTab, id: "logs-meta", steps: steps)

    # Inline labels surface meaningful keys, not source-location noise.
    assert html =~ "request_id=req-abc"
    assert html =~ "user_id=7"
    refute html =~ "line=33"

    # The message renders in its own labeled block, and the expanded fields
    # table (a clean key/value grid, not a JSON box) DOES include the
    # noise-filtered source field.
    assert html =~ "plain text line"
    assert html =~ ">line</span>"
  end

  test "each line is an expandable detail row with a fields table" do
    html = render_component(LogsTab, id: "logs-plain", steps: sample_steps_with_logs())

    assert html =~ "<details"
    # The expanded detail renders a key/value fields table with labeled keys.
    assert html =~ ">level</span>"
  end

  test "renders the timestamp sort toggle and a pager count" do
    html = render_component(LogsTab, id: "logs-sort", steps: sample_steps_with_logs())

    # Sort control (defaults to ascending).
    assert html =~ "sort:toggle"
    assert html =~ "Time"

    # Pager shows the visible range over the total (4 entries in the sample).
    assert html =~ "of 4"
  end
end
