defmodule DurableDashboard.Components.ExecutionFiltersTest do
  @moduledoc """
  Render coverage for the faceted Executions filter bar — the closed (no-popover)
  state: facet triggers, active chips + clear-all, and the locked-workflow chip
  on the per-workflow page. Popover interaction is exercised in dev (events need
  a host LiveView); these assert the structure that drives it.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Data.ExecutionFilters

  defp assigns(overrides) do
    Map.merge(
      %{
        id: "filters",
        base_path: "/dashboard",
        workflows: [
          %{
            workflow_name: "process_payment",
            workflow_module: "Elixir.PaymentWorkflow",
            total_runs: 12,
            last_status: :completed
          }
        ],
        status_options: ~w(running completed failed),
        workflow: nil,
        locked_workflow?: false,
        statuses: [],
        range: nil,
        from: nil,
        to: nil,
        exec_id: nil
      },
      overrides
    )
  end

  test "renders all four facet triggers and no clear-all when empty" do
    html = render_component(ExecutionFilters, assigns(%{}))

    assert html =~ "Workflow"
    assert html =~ "Status"
    assert html =~ "Time"
    assert html =~ "ID"
    refute html =~ "Clear all"
  end

  test "shows active values and a clear-all when filters are set" do
    html =
      render_component(
        ExecutionFilters,
        assigns(%{workflow: "process_payment", statuses: ["failed"], range: "24h"})
      )

    assert html =~ "process_payment"
    assert html =~ "Last 24 hours"
    assert html =~ "Clear all"
  end

  test "locked workflow renders the name as a fixed chip" do
    html =
      render_component(
        ExecutionFilters,
        assigns(%{locked_workflow?: true, workflow: "process_payment"})
      )

    assert html =~ "process_payment"
    # The locked chip replaces the toggle: no workflow facet button to open.
    refute html =~ ~s(phx-value-facet="workflow")
  end

  test "multiple statuses summarize as 'first +N'" do
    html =
      render_component(ExecutionFilters, assigns(%{statuses: ["failed", "running"]}))

    assert html =~ "failed +1"
  end
end
