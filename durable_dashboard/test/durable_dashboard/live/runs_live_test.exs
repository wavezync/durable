defmodule DurableDashboard.Live.RunsLiveTest do
  @moduledoc "The Runs list: saved views, the query bar, bulk actions and live refresh."
  use DurableDashboard.LiveCase

  setup do
    {:ok, ids: Fixtures.seed!()}
  end

  defp short(id), do: String.slice(id, 0, 8)

  # The patched URL's query, decoded.
  defp patched_query(view) do
    view
    |> assert_patch()
    |> URI.parse()
    |> Map.get(:query, "")
    |> to_string()
    |> URI.decode_query()
  end

  defp tags(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[phx-click=remove_tag]")
    |> LazyHTML.attribute("phx-value-tag")
  end

  defp commit(view, text) do
    view |> element("#executions-filters-query") |> render_submit(%{"draft" => text})
  end

  test "lists top-level runs with their status and where they stopped", %{conn: conn, ids: ids} do
    {:ok, _view, html} = live(conn, dash("/executions"))

    for kind <- [:completed, :failed, :compensated, :waiting_input, :family] do
      assert html =~ short(ids[kind])
    end

    # The failed run says where and why; the waiting one, that it waits.
    assert html =~ "card declined"
    assert html =~ "waiting"
  end

  test "the Failed tab filters to failed runs and patches the URL", %{conn: conn, ids: ids} do
    {:ok, view, _html} = live(conn, dash("/executions"))

    view |> element("[phx-click=view][phx-value-view=failed]") |> render_click()

    assert patched_query(view) == %{"status" => "failed,compensated,compensation_failed"}

    html = render(view)
    assert html =~ short(ids.failed)
    assert html =~ short(ids.compensated)
    refute html =~ short(ids.completed)
    assert has_element?(view, "[phx-value-view=failed][aria-current=page]")
  end

  describe "query bar" do
    test "typed search terms become tags and patch q", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      commit(view, "step:authorize error:declined")

      assert patched_query(view) == %{"q" => "step:authorize error:declined"}
      assert tags(view) == ["q:0", "q:1"]
    end

    test "typed facets set the same filters as the menus", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      commit(view, "status:waiting workflow:process_payment")

      assert patched_query(view) == %{"status" => "waiting", "workflow" => "process_payment"}
      assert has_element?(view, "[phx-value-view=waiting][aria-current=page]")
      # A status a tab already names needs no tag; the workflow gets one.
      assert tags(view) == ["workflow"]
    end

    test "a facet value the menus don't offer is dropped", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      commit(view, "status:nope")

      assert tags(view) == []
      refute render(view) =~ "nope"
    end

    test "a tag's × removes just that term", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/executions?q=step:authorize%20error:declined"))
      assert tags(view) == ["q:0", "q:1"]

      view |> element("[phx-click=remove_tag][phx-value-tag='q:0']") |> render_click()

      assert patched_query(view) == %{"q" => "error:declined"}
    end

    test "Backspace in an empty field removes the last tag", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/executions?q=step:authorize&range=24h"))

      view |> element("#run-query-0") |> render_keydown(%{"key" => "Backspace", "value" => ""})
      assert patched_query(view) == %{"range" => "24h"}

      # With text in the field, Backspace edits the text, not the tags.
      view
      |> element("input[name=draft]")
      |> render_keydown(%{"key" => "Backspace", "value" => "abc"})

      assert tags(view) == ["time"]
    end

    test "clear all drops every filter", %{conn: conn} do
      {:ok, view, _html} =
        live(conn, dash("/executions?q=error:declined&workflow=process_payment&range=24h"))

      view |> element("[aria-label='Clear all filters']") |> render_click()

      assert_patch(view, dash("/executions"))
      assert tags(view) == []
    end

    test "the Workflow menu sets a workflow tag", %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      view |> element("[phx-click=toggle_facet][phx-value-facet=workflow]") |> render_click()

      view
      |> element("[phx-click=select_workflow][phx-value-name=process_payment]")
      |> render_click()

      assert patched_query(view) == %{"workflow" => "process_payment"}

      html = render(view)
      assert html =~ short(ids.failed)
      refute html =~ short(ids.compensated)
      assert tags(view) == ["workflow"]
    end

    test "a Time preset adds a since tag", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      view |> element("[phx-click=toggle_facet][phx-value-facet=time]") |> render_click()
      view |> element("[phx-click=set_range][phx-value-range='24h']") |> render_click()

      assert patched_query(view) == %{"range" => "24h"}
      assert tags(view) == ["time"]
    end

    test "on a workflow's runs page the workflow tag can't be removed", %{conn: conn, ids: ids} do
      {:ok, view, html} = live(conn, dash("/workflows/process_payment/runs"))

      assert html =~ short(ids.failed)
      refute html =~ short(ids.compensated)
      assert tags(view) == []
      refute has_element?(view, "[phx-click=toggle_facet][phx-value-facet=workflow]")
    end
  end

  describe "bulk actions" do
    test "retry a selected failed run", %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      view |> element("[phx-click=toggle][phx-value-id='#{ids.failed}']") |> render_click()
      assert has_element?(view, "[aria-label='Bulk actions']")

      html = view |> element("[phx-click=bulk][phx-value-action=retry]") |> render_click()

      assert html =~ "Retried 1 of 1 run."
      refute Fixtures.get_run!(ids.failed).status == :failed
    end

    test "cancel a selected waiting run", %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      view |> element("[phx-click=toggle][phx-value-id='#{ids.waiting_input}']") |> render_click()
      html = view |> element("[phx-click=bulk][phx-value-action=cancel]") |> render_click()

      assert html =~ "Cancelled 1 of 1 run."
      assert Fixtures.get_run!(ids.waiting_input).status == :cancelled
    end

    test "an action only shows when it fits a selected run", %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      view |> element("[phx-click=toggle][phx-value-id='#{ids.completed}']") |> render_click()

      assert has_element?(view, "[phx-click=bulk][phx-value-action=rerun]")
      refute has_element?(view, "[phx-click=bulk][phx-value-action=retry]")
      refute has_element?(view, "[phx-click=bulk][phx-value-action=cancel]")
    end

    test "changing the view starts the selection over", %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      view |> element("[phx-click=toggle][phx-value-id='#{ids.failed}']") |> render_click()
      assert has_element?(view, "[aria-label='Bulk actions']")

      view |> element("[phx-click=view][phx-value-view=failed]") |> render_click()

      refute has_element?(view, "[aria-label='Bulk actions']")
    end

    @tag role: :viewer
    test "viewers get no selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      refute has_element?(view, "[phx-click=toggle]")
      refute has_element?(view, "[phx-click=toggle-all]")
    end
  end

  test "new runs wait behind a pill instead of moving the rows", %{conn: conn, ids: ids} do
    {:ok, view, _html} = live(conn, dash("/executions"))

    new_id = Fixtures.run!(Fixtures.Payments)
    send(view.pid, :refresh)

    html = render(view)
    assert html =~ "1 new run"
    refute html =~ short(new_id)
    assert html =~ short(ids.failed)

    html = view |> element("[phx-click=show-latest]") |> render_click()
    assert html =~ short(new_id)
    refute has_element?(view, "[phx-click=show-latest]")
  end
end
