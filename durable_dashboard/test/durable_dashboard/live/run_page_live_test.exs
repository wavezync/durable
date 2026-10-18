defmodule DurableDashboard.Live.RunPageLiveTest do
  @moduledoc "One run's page: its views, the shared step inspector and its actions."
  use DurableDashboard.LiveCase

  import Ecto.Query

  alias Durable.Storage.Schemas.StepExecution

  setup do
    {:ok, ids: Fixtures.seed!()}
  end

  defp step_id(run_id, name) do
    Durable.Config.get(Durable).repo.one!(
      from(s in StepExecution,
        where: s.workflow_id == ^run_id and s.step_name == ^name,
        order_by: [desc: s.inserted_at],
        limit: 1,
        select: s.id
      )
    )
  end

  defp graph(view) do
    view
    |> element("[phx-hook=FlowGraph]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-graph")
    |> hd()
    |> Jason.decode!()
  end

  describe "trace view" do
    test "a failed run opens on its failed step's error, stack and all", %{conn: conn, ids: ids} do
      {:ok, view, html} = live(conn, dash("/executions/#{ids.failed}"))

      assert has_element?(view, "[aria-label='Step inspector']")
      assert has_element?(view, "[aria-label='Step details'] [aria-current=page]", "Error")
      assert html =~ "ArgumentError"
      assert html =~ "card declined"
      # The app's own frame reads the way the workflow was written.
      assert html =~ "Payments · step :authorize"
      assert html =~ "test/support/fixtures.ex"
    end

    test "?step= and ?pane= pick the step and the pane", %{conn: conn, ids: ids} do
      sid = step_id(ids.completed, "authorize")
      path = dash("/executions/#{ids.completed}?step=#{sid}")

      {:ok, _view, html} = live(conn, path <> "&pane=output")
      assert html =~ "AUTH-1"

      {:ok, view, html} = live(conn, path <> "&pane=attempts")
      assert has_element?(view, "[aria-label='Step details'] [aria-current=page]", "Attempts")
      assert html =~ "Attempt 1"

      {:ok, _view, html} = live(conn, path <> "&pane=logs")
      assert html =~ "No logs captured for this step."
    end
  end

  describe "graph view" do
    test "draws joins and branch gateways, and no inspector until a step is picked",
         %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, dash("/executions/#{ids.family}/graph"))

      types = graph(view)["nodes"] |> Enum.map(& &1["type"]) |> Enum.uniq()
      assert "join" in types
      assert "branch" in types
      refute has_element?(view, "[aria-label='Step inspector']")
    end

    test "clicking a card opens the shared inspector beside the graph", %{conn: conn, ids: ids} do
      sid = step_id(ids.family, "ingest")
      {:ok, view, _html} = live(conn, dash("/executions/#{ids.family}/graph"))

      # The hook pushes to its own component (pushEventTo(this.el, …)).
      view
      |> with_target("[data-phx-component]:has(> [phx-hook=FlowGraph])")
      |> render_hook("step-clicked", %{"step_execution_id" => sid})

      assert_patch(view, dash("/executions/#{ids.family}/graph?step=#{sid}"))
      assert has_element?(view, "[aria-label='Step inspector']")

      assert has_element?(
               view,
               "a[aria-label='Close the inspector'][href='#{dash("/executions/#{ids.family}/graph")}']"
             )

      # The inspected card is marked in the graph.
      assert Enum.any?(graph(view)["nodes"], &(&1["data"]["selected"] == true))
    end
  end

  test "Context folds the engine's own keys away", %{conn: conn, ids: ids} do
    {:ok, _view, html} = live(conn, dash("/executions/#{ids.family}/context"))
    assert html =~ "Engine bookkeeping"
  end

  defp texts(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.map(&LazyHTML.text/1)
  end

  # Durations need started_at, which the queue's claim sets; runs driven
  # inline here don't have one, so only the step names are checked.
  test "Family names each child's step", %{conn: conn, ids: ids} do
    {:ok, _view, html} = live(conn, dash("/executions/#{ids.family}/family"))

    rows = texts(html, "ol.divide-y > li")
    assert length(rows) == 2
    assert Enum.any?(rows, &(&1 =~ "spam_scan"))
    assert Enum.any?(rows, &(&1 =~ "nsfw_scan"))
    refute Enum.any?(rows, &(&1 =~ "(no step)"))
  end

  # The header's "N children" menu names children from the root's
  # `__parallel_children` context, which a finished parallel block drops —
  # so every child reads "(no step)". (The Family tab falls back to the
  # child's own step execution.)
  test "the children menu names each child's step", %{conn: conn, ids: ids} do
    {:ok, _view, html} = live(conn, dash("/executions/#{ids.family}"))

    rows = texts(html, "details ul li")
    assert length(rows) == 2
    refute Enum.any?(rows, &(&1 =~ "(no step)"))
    assert Enum.any?(rows, &(&1 =~ "spam_scan"))
  end

  test "Logs renders", %{conn: conn, ids: ids} do
    {:ok, _view, html} = live(conn, dash("/executions/#{ids.compensated}/logs"))
    assert html =~ "Search message"
  end

  describe "actions" do
    test "Rerun starts a new run linked back to this one", %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, dash("/executions/#{ids.completed}"))

      {:ok, _new_view, html} =
        view
        |> element("[phx-click=rerun]")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "Rerun of"
      assert html =~ String.slice(ids.completed, 0, 8)
    end

    test "Retry carries a failed run on from its failed step", %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, dash("/executions/#{ids.failed}"))

      assert view |> element("[phx-click=retry]") |> render() =~ "Retry from authorize"
      view |> element("[phx-click=retry]") |> render_click()

      refute Fixtures.get_run!(ids.failed).status == :failed
    end

    test "Cancel stops a waiting run", %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, dash("/executions/#{ids.waiting_input}"))

      view |> element("[phx-click=cancel]") |> render_click()

      assert Fixtures.get_run!(ids.waiting_input).status == :cancelled
      refute has_element?(view, "[phx-click=cancel]")
    end

    @tag role: :viewer
    test "a viewer gets no actions, and pushing one anyway is refused", %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, dash("/executions/#{ids.failed}"))

      for event <- ~w(rerun retry cancel), do: refute(has_element?(view, "[phx-click=#{event}]"))

      assert render_hook(view, "retry", %{}) =~ "You don&#39;t have permission to do that."
      assert Fixtures.get_run!(ids.failed).status == :failed

      {:ok, view, _html} = live(conn, dash("/executions/#{ids.waiting_input}"))
      render_hook(view, "cancel", %{})
      assert Fixtures.get_run!(ids.waiting_input).status == :waiting
    end
  end

  test "an unknown run id says so", %{conn: conn} do
    {:ok, _view, html} = live(conn, dash("/executions/#{Ecto.UUID.generate()}"))
    assert html =~ "Run not found"
  end
end
