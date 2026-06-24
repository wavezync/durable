defmodule DurableDashboard.PathTest do
  @moduledoc """
  The host app picks the dashboard's mount prefix when calling the
  `dashboard_routes/2` macro (e.g. `/dashboard`, `/admin/durable`). Path
  helpers append per-page suffixes onto that prefix.
  """

  use ExUnit.Case, async: true

  alias DurableDashboard.Path, as: P

  describe "with a typical /dashboard mount" do
    @base "/dashboard"

    test "overview" do
      assert P.overview(@base) == "/dashboard"
    end

    test "workflows list (definitions)" do
      assert P.workflows(@base) == "/dashboard/workflows"
    end

    test "workflow_executions list (executions for one workflow)" do
      assert P.workflow_executions(@base, "drip_email_campaign") ==
               "/dashboard/workflows/drip_email_campaign"
    end

    test "executions list (all)" do
      assert P.executions(@base) == "/dashboard/executions"
    end

    test "execution detail" do
      assert P.execution(@base, "abc-123") == "/dashboard/executions/abc-123"
    end

    test "execution tab" do
      assert P.execution_tab(@base, "abc-123", "logs") == "/dashboard/executions/abc-123/logs"
    end

    test "deprecated workflow/2 still returns the new execution path" do
      assert P.workflow(@base, "abc-123") == "/dashboard/executions/abc-123"
    end

    test "deprecated workflow_tab/3 still returns the new execution path" do
      assert P.workflow_tab(@base, "abc-123", "logs") == "/dashboard/executions/abc-123/logs"
    end

    test "inputs / schedules / settings" do
      assert P.inputs(@base) == "/dashboard/inputs"
      assert P.schedules(@base) == "/dashboard/schedules"
      assert P.settings(@base) == "/dashboard/settings"
    end
  end

  describe "with a deeper /admin/durable mount" do
    @base "/admin/durable"

    test "preserves the prefix" do
      assert P.overview(@base) == "/admin/durable"
      assert P.workflows(@base) == "/admin/durable/workflows"
      assert P.executions(@base) == "/admin/durable/executions"
      assert P.execution_tab(@base, "x", "summary") == "/admin/durable/executions/x/summary"
    end
  end

  describe "edge cases" do
    test "trailing slash on base is normalised" do
      assert P.overview("/dashboard/") == "/dashboard"
    end

    test "root mount" do
      assert P.overview("/") == "/"
      assert P.workflows("/") == "/workflows"
    end

    test "empty base behaves like root mount" do
      assert P.overview("") == "/"
      assert P.workflows("") == "/workflows"
    end
  end
end
