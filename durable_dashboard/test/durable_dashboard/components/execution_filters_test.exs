defmodule DurableDashboard.Components.ExecutionFiltersTest do
  @moduledoc """
  Render coverage for the Runs query bar: tags for every filter in force, the
  fixed-width menus beside it, and the locked workflow on the per-workflow
  page. Typing and removing are exercised in dev (events need a host
  LiveView); these assert the structure that drives them.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Data.ExecutionFilters
  alias DurableDashboard.Live.ExecutionsLive

  defp render_bar(overrides) do
    render_component(
      ExecutionFilters,
      Map.merge(
        %{
          id: "filters",
          workflows: [
            %{
              workflow_name: "process_payment",
              workflow_module: "Elixir.PaymentWorkflow",
              total_runs: 12,
              last_status: :completed
            }
          ],
          status_options: ~w(running completed failed),
          q: nil,
          workflow: nil,
          locked_workflow?: false,
          statuses: [],
          status_tag?: true,
          range: nil,
          from: nil,
          to: nil
        },
        overrides
      )
    )
  end

  defp tags(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[phx-click=remove_tag]")
    |> LazyHTML.attribute("phx-value-tag")
  end

  test "no filters: the menus and an empty field, nothing to clear" do
    html = render_bar(%{})

    for label <- ~w(Workflow Status Time), do: assert(html =~ label)
    assert tags(html) == []
    refute html =~ "Clear all filters"
  end

  test "every filter in force is a removable tag, search terms one each" do
    html =
      render_bar(%{
        workflow: "process_payment",
        statuses: ["failed"],
        range: "24h",
        q: ~s(step:charge error:"rate limited")
      })

    assert tags(html) == ["workflow", "status", "time", "q:0", "q:1"]
    assert html =~ "rate limited"
    assert html =~ "Clear all filters"
  end

  test "the menus don't carry values, so they keep their width" do
    menus =
      %{workflow: "process_payment", statuses: ["failed"], range: "24h"}
      |> render_bar()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[phx-click=toggle_facet]")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert menus == ["Workflow", "Status", "Time"]
  end

  test "statuses a saved-view tab already names get no tag" do
    assert tags(render_bar(%{statuses: ["failed"], status_tag?: false})) == []
  end

  test "a locked workflow is a tag that can't be removed, and has no menu" do
    html = render_bar(%{locked_workflow?: true, workflow: "process_payment"})

    assert html =~ "process_payment"
    assert tags(html) == []
    refute html =~ ~s(phx-value-facet="workflow")
  end

  describe "ExecutionsLive.reconcile/2" do
    defp run(id, status \\ :running), do: %{id: id, status: status}

    test "the same runs update in place" do
      assert ExecutionsLive.reconcile([run("a"), run("b")], [run("a", :completed), run("b")]) ==
               {[run("a", :completed), run("b")], nil}
    end

    test "new runs are held; the rows on screen stay put with fresh data" do
      assert ExecutionsLive.reconcile([run("a"), run("b")], [run("c"), run("a", :failed)]) ==
               {[run("a", :failed), run("b")], %{new: 1}}
    end

    test "an empty list just shows what arrived" do
      assert ExecutionsLive.reconcile([], [run("a")]) == {[run("a")], nil}
    end
  end
end
