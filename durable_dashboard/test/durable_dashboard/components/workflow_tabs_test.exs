defmodule DurableDashboard.Components.WorkflowTabsTest do
  @moduledoc """
  Static-render coverage for the workflow detail tab components. The live
  WorkflowLive shell + live_isolated tab navigation lives in
  `workflow_live_test.exs`; here we focus on each tab component rendering
  the right content from sample data.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Workflow.{
    HistoryTab,
    IoTab,
    SummaryTab,
    Tabs
  }

  defp sample_workflow do
    %{
      id: "11111111-2222-3333-4444-555555555555",
      workflow_name: "process_order",
      workflow_module: "Elixir.MyApp.OrderWorkflow",
      status: :running,
      queue: "default",
      priority: 5,
      input: %{"order_id" => 42, "items" => ["a", "b"]},
      context: %{"step1_done" => true},
      current_step: "charge_card",
      error: nil,
      scheduled_at: nil,
      started_at: DateTime.add(DateTime.utc_now(), -300, :second),
      completed_at: nil,
      inserted_at: DateTime.add(DateTime.utc_now(), -300, :second),
      updated_at: DateTime.utc_now()
    }
  end

  defp sample_steps do
    now = DateTime.utc_now()

    [
      %{
        id: "s-1",
        step_name: "validate",
        step_type: "step",
        attempt: 1,
        status: :completed,
        input: %{"order_id" => 42},
        output: %{"valid" => true},
        error: nil,
        logs: [],
        duration_ms: 12,
        started_at: DateTime.add(now, -300, :second),
        completed_at: DateTime.add(now, -298, :second),
        inserted_at: DateTime.add(now, -300, :second)
      },
      %{
        id: "s-2",
        step_name: "charge_card",
        step_type: "step",
        attempt: 2,
        status: :running,
        input: nil,
        output: nil,
        error: nil,
        logs: [
          %{
            "level" => "info",
            "message" => "Charging card",
            "timestamp" => DateTime.to_iso8601(now)
          }
        ],
        duration_ms: nil,
        started_at: DateTime.add(now, -200, :second),
        completed_at: nil,
        inserted_at: DateTime.add(now, -200, :second)
      }
    ]
  end

  describe "Tabs.tabs/1" do
    test "renders the five default tabs with the active one highlighted" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Tabs.tabs base_path="/dashboard" workflow_id="abc-123" active={:summary} />
        """)

      for label <- ["Summary", "Flow", "Logs", "I/O", "History"] do
        assert html =~ label
      end

      refute html =~ "Topology", "Topology tab was dropped (DESIGN.md §11)"

      # Active tab gets the primary border
      assert html =~ "border-primary"
    end

    test "every link points at <base>/workflows/:id/:tab" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Tabs.tabs base_path="/dashboard" workflow_id="abc-123" active={:summary} />
        """)

      assert html =~ "/dashboard/workflows/abc-123/summary"
      assert html =~ "/dashboard/workflows/abc-123/flow"
      assert html =~ "/dashboard/workflows/abc-123/logs"
    end
  end

  describe "SummaryTab.summary_tab/1" do
    test "renders metadata fields and step stats" do
      assigns = %{wf: sample_workflow(), steps: sample_steps(), pending: []}

      html =
        rendered_to_string(~H"""
        <SummaryTab.summary_tab workflow={@wf} steps={@steps} pending_inputs={@pending} />
        """)

      assert html =~ "Metadata"
      assert html =~ "Steps"
      assert html =~ "Timing"
      # Status pill
      assert html =~ "running"
      # Current step shown
      assert html =~ "charge_card"
      # Queue
      assert html =~ "default"
    end

    test "shows the error card when workflow has an error" do
      wf = %{
        sample_workflow()
        | status: :failed,
          error: %{"type" => "RuntimeError", "message" => "boom"}
      }

      assigns = %{wf: wf, steps: [], pending: []}

      html =
        rendered_to_string(~H"""
        <SummaryTab.summary_tab workflow={@wf} steps={@steps} pending_inputs={@pending} />
        """)

      assert html =~ "Error"
      assert html =~ "RuntimeError"
      assert html =~ "boom"
    end

    test "shows the awaiting-input section when there are pending inputs" do
      pending = [
        %{
          id: "p-1",
          input_name: "approve_payment",
          input_type: :approval,
          step_name: "approval",
          prompt: "Approve this $100 charge?",
          inserted_at: DateTime.utc_now()
        }
      ]

      assigns = %{wf: sample_workflow(), steps: [], pending: pending}

      html =
        rendered_to_string(~H"""
        <SummaryTab.summary_tab workflow={@wf} steps={@steps} pending_inputs={@pending} />
        """)

      assert html =~ "Awaiting input"
      assert html =~ "approve_payment"
      assert html =~ "Approve this $100 charge?"
    end
  end

  describe "IoTab.io_tab/1" do
    test "renders both input and context sections with JSON" do
      assigns = %{wf: sample_workflow()}

      html =
        rendered_to_string(~H"""
        <IoTab.io_tab workflow={@wf} />
        """)

      assert html =~ "Input"
      assert html =~ "Context"
      # JSON-pretty output
      assert html =~ "&quot;order_id&quot;"
      assert html =~ "step1_done"
    end

    test "shows empty placeholders when input/context are empty" do
      wf = %{sample_workflow() | input: %{}, context: %{}}
      assigns = %{wf: wf}

      html =
        rendered_to_string(~H"""
        <IoTab.io_tab workflow={@wf} />
        """)

      assert html =~ "No input"
      assert html =~ "No context yet"
    end
  end

  describe "HistoryTab.history_tab/1" do
    test "renders empty state with no steps" do
      assigns = %{steps: []}

      html =
        rendered_to_string(~H"""
        <HistoryTab.history_tab steps={@steps} />
        """)

      assert html =~ "No step executions yet"
    end

    test "lists every step with its status" do
      assigns = %{steps: sample_steps()}

      html =
        rendered_to_string(~H"""
        <HistoryTab.history_tab steps={@steps} />
        """)

      assert html =~ "validate"
      assert html =~ "charge_card"
      assert html =~ "completed"
      assert html =~ "running"
    end

    test "marks attempt > 1 with a warning indicator" do
      assigns = %{steps: sample_steps()}

      html =
        rendered_to_string(~H"""
        <HistoryTab.history_tab steps={@steps} />
        """)

      assert html =~ "attempt 2"
    end

    test "expandable details block when input/output/error present" do
      assigns = %{steps: sample_steps()}

      html =
        rendered_to_string(~H"""
        <HistoryTab.history_tab steps={@steps} />
        """)

      assert html =~ "<details"
      assert html =~ "Input"
      assert html =~ "Output"
    end
  end
end
