defmodule DurableDashboard.Live.ParkedRunsLiveTest do
  @moduledoc """
  What the pages say about a run that's waiting to go again, on real parked
  runs: a retry's backoff, a snooze, a step's queue, and `on_duplicate:
  :run_again`. Plus tags, which the Runs list can filter by.
  """
  use DurableDashboard.LiveCase

  alias Durable.{Config, Executor}

  defp short(id), do: String.slice(id, 0, 8)
  defp again(id), do: Executor.execute_workflow(id, Config.get(Durable))

  defp graph_nodes(view) do
    view
    |> element("[phx-hook=FlowGraph]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-graph")
    |> hd()
    |> Jason.decode!()
    |> Map.fetch!("nodes")
  end

  defp status_of(nodes, name),
    do: Enum.find(nodes, &(&1["data"]["name"] == name))["data"]["status"]

  defp query(view) do
    view
    |> assert_patch()
    |> URI.parse()
    |> Map.get(:query, "")
    |> to_string()
    |> URI.decode_query()
  end

  describe "a retry waiting out its backoff" do
    setup do
      id = Fixtures.run!(Fixtures.Retrying)
      assert %{status: :pending, scheduled_at: %DateTime{}} = Fixtures.get_run!(id)
      {:ok, id: id}
    end

    test "the list says where, when and how many attempts, over its error", %{conn: conn} do
      {:ok, view, html} = live(conn, dash("/executions"))

      assert has_element?(view, "td .st-retrying")
      assert html =~ "Retrying"
      assert html =~ ~r/charge_card<\/span><span> in \d+[hm] .*· 1 of 5/
      assert html =~ "gateway timeout"
    end

    test "the page says it too, with the error a click away", %{conn: conn, id: id} do
      {:ok, view, html} = live(conn, dash("/executions/#{id}"))

      assert has_element?(view, "header .st-retrying")
      assert html =~ ~r/failed on attempt 1 of 5 and tries again in \d+[hm]/
      assert html =~ "gateway timeout"
      assert has_element?(view, "a[href*='pane=error']", "Show error")
      # The step's own row and the gap running on to now.
      assert has_element?(view, "[aria-label='Step inspector'] .st-retrying")
      assert html =~ "Backoff"
    end

    test "the graph shows the step as retrying, not failed", %{conn: conn, id: id} do
      {:ok, view, _html} = live(conn, dash("/executions/#{id}/graph"))
      assert status_of(graph_nodes(view), "charge_card") == "retrying"
    end
  end

  describe "a snooze" do
    setup do
      id = Fixtures.run!(Fixtures.Snoozing)
      assert %{status: :pending, scheduled_at: %DateTime{}} = Fixtures.get_run!(id)
      {:ok, id: id}
    end

    test "the list shows how long and why, in grey", %{conn: conn} do
      {:ok, view, html} = live(conn, dash("/executions"))

      assert has_element?(view, "td .st-snoozed")
      assert html =~ "Snoozed"
      assert html =~ ~r/render_pdf<\/span><span> for \d+[hm]/
      assert html =~ "another export is running"
    end

    test "the page says until when, and never calls it an error", %{conn: conn, id: id} do
      {:ok, view, html} = live(conn, dash("/executions/#{id}"))

      assert has_element?(view, "header .st-snoozed")
      assert html =~ "snoozed until"
      assert html =~ "another export is running"
      assert html =~ "A snooze doesn&#39;t use an attempt."

      refute has_element?(view, "[aria-label='Step details'] a", "Error")
      assert has_element?(view, "[aria-label='Step details'] [aria-current=page]", "Attempts")
      refute html =~ "snooze_ms"
    end

    test "snoozes are counted apart from attempts", %{conn: conn, id: id} do
      again(id)

      {:ok, _view, html} = live(conn, dash("/executions/#{id}"))

      assert html =~ "0 across 1 step"
      assert html =~ "snoozed 2×"
    end
  end

  describe "a run on a step's queue" do
    setup do
      id = Fixtures.run!(Fixtures.OnStepQueue)
      run = Fixtures.get_run!(id)
      assert {run.status, run.queue, run.home_queue} == {:pending, "ocr", "default"}
      {:ok, id: id}
    end

    test "stays Pending and says what it's waiting for", %{conn: conn} do
      {:ok, view, html} = live(conn, dash("/executions"))

      assert has_element?(view, "td .st-pending")
      refute has_element?(view, "td .st-retrying")
      assert html =~ ~r/next <span[^>]*>run_ocr/
      assert html =~ "Waiting for a slot on ocr"
      assert html =~ "its home queue is default"
    end

    test "the page names both queues", %{conn: conn, id: id} do
      {:ok, _view, html} = live(conn, dash("/executions/#{id}"))

      assert html =~ "is waiting for a slot on"
      assert html =~ "after this step, unless the next step names a queue."
      assert html =~ "home queue default"
    end
  end

  describe "a run_again run" do
    setup do
      {:ok, holder} =
        Executor.start_workflow(Fixtures.RunsAgain, %{"v" => 1}, inline: true, key: "account:7")

      {:ok, waiting} = Durable.start(Fixtures.RunsAgain, %{"v" => 2}, key: "account:7")
      assert Fixtures.get_run!(waiting).runs_after_id == holder
      {:ok, holder: holder, waiting: waiting}
    end

    test "the list says whose turn it's waiting for", %{conn: conn, holder: holder} do
      {:ok, _view, html} = live(conn, dash("/executions"))
      assert html =~ "Waiting for run #{short(holder)} to finish"
    end

    test "the page links the run it's behind", %{conn: conn, holder: holder, waiting: waiting} do
      {:ok, view, html} = live(conn, dash("/executions/#{waiting}"))

      assert html =~ "then runs with the newest input. Newer starts replace this input."
      assert has_element?(view, "a[href$='/executions/#{holder}']", "Open that run")
    end

    test "the Key view gives it a sentence", %{conn: conn, holder: holder, waiting: waiting} do
      {:ok, _view, html} = live(conn, dash("/executions/#{waiting}/key"))

      assert html =~ "Runs after"
      assert html =~ short(holder)
      assert html =~ "with the newest input"
    end
  end

  describe "tags" do
    setup do
      {:ok, tagged} =
        Durable.start(Fixtures.Payments, %{}, tags: ["account:7", "nightly", "priority"])

      {:ok, other} = Durable.start(Fixtures.Payments, %{}, tags: ["account:9"])
      {:ok, tagged: tagged, other: other}
    end

    test "a row shows two chips and how many more, outside its link", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/executions"))

      assert has_element?(view, "button[phx-click=filter-tag]", "account:7")
      assert has_element?(view, "button[phx-click=filter-tag]", "nightly")
      refute has_element?(view, "button[phx-click=filter-tag]", "priority")
      assert has_element?(view, "[data-tip='priority']", "+1")
      refute has_element?(view, "a button")
    end

    test "clicking one filters by it, and clicking again changes nothing", %{
      conn: conn,
      tagged: tagged,
      other: other
    } do
      {:ok, view, _html} = live(conn, dash("/executions"))

      chip = "button[phx-click=filter-tag][phx-value-tag='account:7']"
      view |> element(chip) |> render_click()
      assert query(view) == %{"q" => "tag:account:7"}

      html = render(view)
      assert html =~ short(tagged)
      refute html =~ short(other)

      view |> element(chip) |> render_click()
      assert query(view) == %{"q" => "tag:account:7"}
    end

    test "tag: can be typed, and several must all match", %{
      conn: conn,
      tagged: tagged,
      other: other
    } do
      {:ok, _view, html} = live(conn, dash("/executions?q=tag:account:7+tag:nightly"))
      assert html =~ short(tagged)
      refute html =~ short(other)

      {:ok, _view, html} = live(conn, dash("/executions?q=tag:account:9+tag:nightly"))
      refute html =~ short(tagged)
      refute html =~ short(other)
    end

    test "the run page lists them, each a link to its runs", %{conn: conn, tagged: tagged} do
      {:ok, view, _html} = live(conn, dash("/executions/#{tagged}"))

      assert has_element?(view, "a[href$='/executions?q=tag%3Aaccount%3A7']", "account:7")
    end
  end

  test "a schedule shows the key it starts runs with", %{conn: conn} do
    {:ok, _} =
      Durable.schedule(Fixtures.Payments, "*/5 * * * *", name: "keyed", key: "sweep")

    {:ok, _view, html} = live(conn, dash("/schedules"))
    assert html =~ "sweep"
  end

  test "a run that parks while the list is open updates", %{conn: conn} do
    {:ok, id} = Durable.start(Fixtures.Retrying, %{})
    {:ok, view, _html} = live(conn, dash("/executions"))
    refute has_element?(view, "td .st-retrying")

    again(id)
    send(view.pid, {:durable_event, :workflow_parked, %{id: id}})
    send(view.pid, :refresh)

    assert has_element?(view, "td .st-retrying")
  end
end
