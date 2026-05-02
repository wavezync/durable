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

    test "workflows list" do
      assert P.workflows(@base) == "/dashboard/workflows"
    end

    test "workflow detail" do
      assert P.workflow(@base, "abc-123") == "/dashboard/workflows/abc-123"
    end

    test "workflow tab" do
      assert P.workflow_tab(@base, "abc-123", "logs") == "/dashboard/workflows/abc-123/logs"
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
      assert P.workflow_tab(@base, "x", "summary") == "/admin/durable/workflows/x/summary"
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
