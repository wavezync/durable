defmodule DurableDashboard.Components.DataTableTest do
  @moduledoc """
  Render-level coverage for the `DataTable` LiveComponent. Uses
  `Phoenix.LiveViewTest.render_component/3`, which invokes mount → update →
  render but does NOT exercise interactive `handle_event/3`. Interactive
  tests need the test endpoint scaffold and live_isolated/3, which lands
  with phase 3 when WorkflowLive's tab interactions need it.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Data.DataTable

  defp columns do
    [
      %{key: :name, label: "Name", render: fn row -> row.name end},
      %{
        key: :status,
        label: "Status",
        sortable?: false,
        render: fn row -> row.status end
      }
    ]
  end

  defp empty_fetcher, do: fn _q -> {[], 0} end

  defp populated_fetcher(rows) do
    fn _q -> {rows, length(rows)} end
  end

  describe "empty state" do
    test "renders empty_title and empty_description when no rows" do
      html =
        render_component(DataTable,
          id: "t1",
          fetcher: empty_fetcher(),
          columns: columns(),
          query: %{page: 1, per_page: 20, sort_dir: :desc, sort_by: nil, search: nil},
          empty_title: "No workflows yet",
          empty_description: "Try starting one.",
          empty_icon: "queue"
        )

      assert html =~ "No workflows yet"
      assert html =~ "Try starting one"
    end

    test "does not render the table body when empty" do
      html =
        render_component(DataTable,
          id: "t2",
          fetcher: empty_fetcher(),
          columns: columns(),
          query: %{page: 1, per_page: 20, sort_dir: :desc, sort_by: nil, search: nil}
        )

      refute html =~ "<tbody"
    end
  end

  describe "populated table" do
    test "renders one row per fetched record" do
      rows = [
        %{id: "a1", name: "alpha", status: "running"},
        %{id: "b2", name: "bravo", status: "completed"}
      ]

      html =
        render_component(DataTable,
          id: "t3",
          fetcher: populated_fetcher(rows),
          columns: columns(),
          query: %{page: 1, per_page: 20, sort_dir: :desc, sort_by: nil, search: nil}
        )

      assert html =~ "alpha"
      assert html =~ "bravo"
      assert html =~ "running"
      assert html =~ "completed"
      # Column headers
      assert html =~ "Name"
      assert html =~ "Status"
    end

    test "uses :render function from column spec when provided" do
      rows = [%{id: "x", name: "Custom-rendered", status: nil}]

      columns = [
        %{
          key: :name,
          label: "Custom",
          render: fn row -> "[" <> row.name <> "]" end
        }
      ]

      html =
        render_component(DataTable,
          id: "t4",
          fetcher: populated_fetcher(rows),
          columns: columns,
          query: %{page: 1, per_page: 20, sort_dir: :desc, sort_by: nil, search: nil}
        )

      assert html =~ "[Custom-rendered]"
    end
  end

  describe "filters" do
    test "search filter renders an input with current value" do
      filters = [%{key: :search, type: :search, label: "Search"}]

      html =
        render_component(DataTable,
          id: "t5",
          fetcher: empty_fetcher(),
          columns: columns(),
          filters: filters,
          query: %{
            page: 1,
            per_page: 20,
            sort_dir: :desc,
            sort_by: nil,
            search: "needle"
          }
        )

      assert html =~ ~s(value="needle")
      assert html =~ ~s(type="search")
    end

    test "select filter renders options including the current selection" do
      filters = [
        %{key: :status, type: :select, label: "Status", options: ["", "running", "failed"]}
      ]

      html =
        render_component(DataTable,
          id: "t6",
          fetcher: empty_fetcher(),
          columns: columns(),
          filters: filters,
          query: %{
            page: 1,
            per_page: 20,
            sort_dir: :desc,
            sort_by: nil,
            search: nil,
            status: "running"
          }
        )

      assert html =~ "<option"
      assert html =~ "running"
      assert html =~ "selected"
    end
  end

  describe "fetcher safety" do
    test "renders error_state with the exception message when fetcher raises" do
      fetcher = fn _q -> raise "boom" end

      html =
        render_component(DataTable,
          id: "t7",
          fetcher: fetcher,
          columns: columns(),
          query: %{page: 1, per_page: 20, sort_dir: :desc, sort_by: nil, search: nil},
          empty_title: "Nothing",
          empty_description: "Fetcher failed silently."
        )

      # Error state distinct from empty state — surfaces the exception message
      # so operators see what's actually broken.
      assert html =~ "Failed to load"
      assert html =~ "boom"
      assert html =~ ~s(role="alert")
    end
  end

  describe "pagination footer" do
    test "shows page indicator when populated" do
      rows = [%{id: "x", name: "one", status: "running"}]

      html =
        render_component(DataTable,
          id: "t8",
          fetcher: populated_fetcher(rows),
          columns: columns(),
          query: %{page: 1, per_page: 20, sort_dir: :desc, sort_by: nil, search: nil}
        )

      # "1 / 1" page indicator
      assert html =~ "1 / 1"
      assert html =~ "of"
    end
  end
end
