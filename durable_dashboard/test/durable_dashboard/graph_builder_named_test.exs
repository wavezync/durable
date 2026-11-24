defmodule DurableDashboard.GraphBuilderNamedTest do
  @moduledoc "The graph of named branches and lanes, and how a run's state lands on it."
  use ExUnit.Case, async: true

  alias DurableDashboard.GraphBuilder
  alias DurableDashboard.NamedBlocksWorkflow

  setup do
    {:ok, definition} = NamedBlocksWorkflow.__workflow_definition__("named_blocks")
    {:ok, graph: GraphBuilder.build(definition), definition: definition}
  end

  defp node(graph, id), do: Enum.find(graph.nodes, &(&1.id == id))

  # The labelled edges out of a gateway, one for each arm that holds something.
  defp arms(graph, id) do
    graph.edges |> Enum.filter(&(&1.source == id and &1[:label])) |> Enum.sort_by(& &1.target)
  end

  defp into(graph, id),
    do: graph.edges |> Enum.filter(&(&1.target == id)) |> Enum.map(& &1.source) |> Enum.sort()

  defp ran(name, status \\ :completed, more \\ []) do
    Map.merge(
      %{
        id: "exec-#{name}",
        step_name: name,
        status: status,
        attempt: 1,
        duration_ms: 1,
        started_at: nil,
        completed_at: nil,
        child_workflow_id: nil,
        inserted_at: DateTime.utc_now()
      },
      Map.new(more)
    )
  end

  defp decided(name, arm, more \\ []),
    do:
      ran(name, :completed, [output: %{"decision_type" => "goto", "target_step" => arm}] ++ more)

  describe "the shape" do
    test "every step is drawn once", %{graph: graph, definition: definition} do
      ids = Enum.map(graph.nodes, & &1.id)

      assert ids == Enum.uniq(ids)

      # Everything that runs code, and a join for each parallel block.
      runs_code =
        for %{type: type} = step <- definition.steps, type != :parallel, do: to_string(step.name)

      assert Enum.sort(ids) ==
               Enum.sort(runs_code ++ ["fulfil__join", "fulfil__papers__docs__join"])
    end

    test "a branch is its deciding step, with a labelled edge into each arm that holds something",
         %{graph: graph} do
      assert %{type: "branch", data: %{label: "risk", decider: true, paths: paths}} =
               node(graph, "risk")

      assert paths == [
               %{clause: "clear", first: nil},
               %{clause: "review", first: "risk__review__ask"},
               %{clause: "blocked", first: "risk__blocked__ask"}
             ]

      assert into(graph, "risk") == ["first"]

      assert [
               %{
                 target: "risk__blocked__ask",
                 label: "blocked",
                 className: "flow-edge-conditional"
               },
               %{target: "risk__review__ask", label: "review", className: "flow-edge-conditional"}
             ] = arms(graph, "risk")
    end

    test "a branch inside an arm hangs off that arm", %{graph: graph} do
      assert into(graph, "risk__review__inner") == ["risk__review__ask"]

      assert [%{target: "risk__review__inner__x__x1", label: "x"}] =
               arms(graph, "risk__review__inner")

      assert node(graph, "risk__review__inner__x__x1").data.clause == "x"
      assert node(graph, "risk__review__ask").data.clause == "review"
    end

    test "every way out of a branch leads to what follows it, an empty arm from the gateway",
         %{graph: graph} do
      # clear (from risk itself), review → inner's x1 or inner itself (y), blocked.
      tails = ["risk", "risk__blocked__ask", "risk__review__inner", "risk__review__inner__x__x1"]

      for first <- ["fulfil__ship__pack", "fulfil__papers__docs__invoice", "fulfil__points"] do
        assert into(graph, first) == tails
      end
    end

    test "lanes run side by side and meet in a join", %{graph: graph} do
      assert %{type: "join", data: %{members: ["ship", "papers", "points"], lanes: lanes}} =
               node(graph, "fulfil__join")

      assert Enum.map(lanes, & &1.tails) == [
               ["fulfil__ship__where__home__courier", "fulfil__ship__where__abroad__freight"],
               ["fulfil__papers__file"],
               ["fulfil__points"]
             ]

      assert into(graph, "fulfil__join") == [
               "fulfil__papers__file",
               "fulfil__points",
               "fulfil__ship__where__abroad__freight",
               "fulfil__ship__where__home__courier"
             ]

      assert into(graph, "close") == ["fulfil__join"]
    end

    test "a lane is a sequence, and can hold a block of its own", %{graph: graph} do
      assert into(graph, "fulfil__ship__where") == ["fulfil__ship__pack"]

      assert into(graph, "fulfil__papers__docs__join") ==
               ["fulfil__papers__docs__invoice", "fulfil__papers__docs__receipt"]

      assert into(graph, "fulfil__papers__file") == ["fulfil__papers__docs__join"]
    end
  end

  describe "a run's state" do
    test "the gateway shows the arm its step recorded, and only that arm's steps ran",
         %{graph: graph} do
      %{nodes: nodes, edges: edges} =
        GraphBuilder.overlay_status(
          graph,
          [ran("first"), decided("risk", "blocked"), ran("risk__blocked__ask")],
          run_status: :running
        )

      graph = %{nodes: nodes, edges: edges}

      assert %{status: "completed", taken: "blocked", step_execution_id: "exec-risk"} =
               node(graph, "risk").data

      # The other arm holds a step with the same name; it didn't run.
      assert node(graph, "risk__review__ask").data.status == "pending"
      assert node(graph, "risk__blocked__ask").data.status == "completed"

      taken = Enum.find(edges, &(&1.target == "risk__blocked__ask"))
      untaken = Enum.find(edges, &(&1.target == "risk__review__ask"))
      assert taken.className == "flow-edge-completed"
      assert untaken.className == "flow-edge-conditional"
    end

    test "an empty arm is taken without a step of its own", %{graph: graph} do
      %{nodes: nodes} =
        GraphBuilder.overlay_status(graph, [ran("first"), decided("risk", "clear")], [])

      assert %{status: "completed", taken: "clear"} = Enum.find(nodes, &(&1.id == "risk")).data
    end

    test "a gateway that hasn't run has taken nothing", %{graph: graph} do
      %{nodes: nodes} = GraphBuilder.overlay_status(graph, [ran("first")], [])

      assert %{status: "pending", taken: nil} = Enum.find(nodes, &(&1.id == "risk")).data
    end

    test "a gateway inside a lane stays a gateway, though it ran in the lane's run",
         %{graph: graph} do
      %{nodes: nodes} =
        GraphBuilder.overlay_status(
          graph,
          [decided("fulfil__ship__where", "home", workflow_id: "lane-run")],
          current_workflow_id: "parent-run"
        )

      assert %{type: "branch", data: %{taken: "home"}} =
               Enum.find(nodes, &(&1.id == "fulfil__ship__where"))
    end

    test "a join counts the lanes that are done, by the arm each ended on", %{graph: graph} do
      done = fn steps ->
        %{nodes: nodes} = GraphBuilder.overlay_status(graph, Enum.map(steps, &ran/1), [])
        Map.take(Enum.find(nodes, &(&1.id == "fulfil__join")).data, [:status, :done])
      end

      assert done.([]) == %{status: "pending", done: 0}
      assert done.(["fulfil__points"]) == %{status: "pending", done: 1}

      # The ship lane ends on a branch: one arm's last step finishes it.
      assert done.(["fulfil__points", "fulfil__ship__pack", "fulfil__ship__where__home__courier"]) ==
               %{status: "pending", done: 2}

      assert done.([
               "fulfil__points",
               "fulfil__ship__where__abroad__freight",
               "fulfil__papers__file"
             ]) == %{status: "completed", done: 3}
    end

    test "a join's lanes each carry how they did, for the frames around them", %{graph: graph} do
      steps = [ran("fulfil__points"), ran("fulfil__ship__pack", :running)]
      %{nodes: nodes} = GraphBuilder.overlay_status(graph, steps, [])
      lanes = Enum.find(nodes, &(&1.id == "fulfil__join")).data.lanes

      assert Map.new(lanes, &{&1.name, &1.status}) ==
               %{"points" => "completed", "ship" => "running", "papers" => "pending"}
    end

    test "a join is running while a lane is, and failed when one failed", %{graph: graph} do
      status = fn steps ->
        %{nodes: nodes} = GraphBuilder.overlay_status(graph, steps, [])
        Enum.find(nodes, &(&1.id == "fulfil__join")).data.status
      end

      assert status.([ran("fulfil__points"), ran("fulfil__ship__pack", :running)]) == "running"
      assert status.([ran("fulfil__points"), ran("fulfil__ship__pack", :failed)]) == "failed"
    end
  end

  describe "a lane that ends on a block, and a block that collects" do
    setup do
      {:ok, definition} = NamedBlocksWorkflow.__workflow_definition__("lookups")
      {:ok, lookups: GraphBuilder.build(definition)}
    end

    @inner "lookups__sanctions__lists__join"

    test "the lane is done when the block it ends on is", %{lookups: graph} do
      rows =
        Enum.map(
          ~w(lookups__credit lookups__sanctions__query lookups__sanctions__lists__eu
             lookups__sanctions__lists__un decide),
          &ran/1
        )

      graph = GraphBuilder.overlay_status(graph, rows, run_status: :completed)

      assert %{status: "completed", done: 2} = node(graph, @inner).data
      assert %{status: "completed", done: 2} = node(graph, "lookups__join").data
    end

    test "and still open while that block is", %{lookups: graph} do
      rows = [
        ran("lookups__credit"),
        ran("lookups__sanctions__query"),
        ran("lookups__sanctions__lists__eu"),
        ran("lookups__sanctions__lists__un", :running)
      ]

      graph = GraphBuilder.overlay_status(graph, rows, run_status: :running)

      assert %{status: "running", done: 1} = node(graph, @inner).data
      assert %{status: "running", done: 1} = node(graph, "lookups__join").data
    end

    test "a collecting join is done once every lane has ended, and says how many failed",
         %{lookups: graph} do
      assert node(graph, "lookups__join").data.collect
      refute node(graph, @inner).data[:collect]

      rows = [
        ran("lookups__credit", :failed),
        ran("lookups__sanctions__query"),
        ran("lookups__sanctions__lists__eu"),
        ran("lookups__sanctions__lists__un"),
        ran("decide")
      ]

      graph = GraphBuilder.overlay_status(graph, rows, run_status: :completed)

      assert %{status: "completed", done: 1, failed: 1} = node(graph, "lookups__join").data
    end

    test "a collecting join waits for a lane that is still going", %{lookups: graph} do
      rows = [ran("lookups__credit", :failed), ran("lookups__sanctions__query", :running)]
      graph = GraphBuilder.overlay_status(graph, rows, run_status: :running)

      assert %{status: "running", done: 0, failed: 1} = node(graph, "lookups__join").data
    end
  end

  describe "a lane the block can do without" do
    setup do
      {:ok, definition} = NamedBlocksWorkflow.__workflow_definition__("enrich")
      {:ok, enrich: GraphBuilder.build(definition)}
    end

    test "is marked on the join", %{enrich: graph} do
      assert [%{name: "credit", optional: false}, %{name: "device", optional: true}] =
               node(graph, "lookups__join").data.lanes
    end

    test "doesn't fail the join when it fails", %{enrich: graph} do
      rows = [ran("lookups__credit"), ran("lookups__device", :failed), ran("decide")]
      graph = GraphBuilder.overlay_status(graph, rows, run_status: :completed)

      assert %{status: "completed", done: 1, failed: 1} = node(graph, "lookups__join").data
    end

    test "and a lane the block needs still does", %{enrich: graph} do
      rows = [ran("lookups__credit", :failed), ran("lookups__device")]
      graph = GraphBuilder.overlay_status(graph, rows, run_status: :failed)

      assert %{status: "failed", done: 1, failed: 1} = node(graph, "lookups__join").data
    end
  end

  describe "what a workflow's definition says about its steps and lanes" do
    setup do
      {:ok, definition} = NamedBlocksWorkflow.__workflow_definition__("loan")
      %{loan: GraphBuilder.build(definition)}
    end

    test "a step carries its retry budget, time limit, undo and queue", %{loan: graph} do
      assert %{max_attempts: 1, timeout_ms: 30_000, compensate: "withdraw"} =
               node(graph, "open").data

      assert node(graph, "lookups__credit").data.max_attempts == 3
      assert node(graph, "lookups__social__rate").data.queue == "scoring"
      refute Map.has_key?(node(graph, "lookups__social__find").data, :queue)
    end

    test "a lane of one step carries the lane's options on that step", %{loan: graph} do
      assert node(graph, "lookups__device").data.lane ==
               %{name: "device", optional: true, default: true, timeout_ms: nil}

      refute Map.has_key?(node(graph, "lookups__credit").data, :lane)
    end

    test "a lane of several steps is listed on its join, options and all", %{loan: graph} do
      %{data: %{lanes: lanes}} = node(graph, "lookups__join")
      social = Enum.find(lanes, &(&1.name == "social"))

      assert %{optional: true, default: true, timeout_ms: 5_000} = social
      assert Enum.sort(social.nodes) == ["lookups__social__find", "lookups__social__rate"]

      assert %{optional: false, default: false, timeout_ms: nil} =
               Enum.find(lanes, &(&1.name == "credit"))
    end
  end
end
