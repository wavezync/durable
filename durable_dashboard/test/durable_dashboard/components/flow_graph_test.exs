defmodule DurableDashboard.Components.FlowGraphTest do
  @moduledoc """
  Render-level coverage for the `FlowGraph` LiveComponent. Verifies the
  empty-state fallback (when no workflow definition is available) and the
  hook div shape (when a graph is built). The actual ReactFlow rendering
  happens client-side and is out of scope for ExUnit.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Durable.Definition
  alias DurableDashboard.Components.Workflow.FlowGraph
  alias DurableDashboard.GraphBuilder

  defp workflow_with_unknown_module do
    %{
      id: "wf-1",
      workflow_module: "Elixir.NoSuchModuleZZZ",
      workflow_name: "missing"
    }
  end

  describe "empty-state path" do
    test "renders empty_state when the workflow module isn't loaded" do
      html =
        render_component(FlowGraph,
          id: "flow-x",
          kind: :flow,
          workflow: workflow_with_unknown_module(),
          steps: []
        )

      assert html =~ "No graph available"
      # Apostrophe gets HTML-escaped — match on a stable substring instead.
      assert html =~ "workflow definition"
    end

    test "topology variant also renders empty_state when module is unknown" do
      html =
        render_component(FlowGraph,
          id: "topo-x",
          kind: :topology,
          workflow: workflow_with_unknown_module(),
          steps: []
        )

      assert html =~ "No graph available"
    end
  end

  describe "hook div shape (with a fake graph passed via update)" do
    # We can't easily exercise the build_graph path without a real workflow
    # module loaded into the BEAM. Instead, verify the render branch by
    # confirming the empty-state path is the *only* output when nodes is
    # empty — guarding against accidentally rendering the hook div with
    # an empty graph.
    test "does not render the phx-hook element when nodes are empty" do
      html =
        render_component(FlowGraph,
          id: "flow-y",
          kind: :flow,
          workflow: workflow_with_unknown_module(),
          steps: []
        )

      refute html =~ ~s(phx-hook="FlowGraph")
      refute html =~ "data-graph-version"
    end
  end

  # ============================================================================
  # GraphBuilder — overlay_status fallback + dedup
  # ============================================================================

  describe "GraphBuilder.build/1 — parallel children are emitted once" do
    test "skips standalone copies of parallel children that the DSL also splices" do
      definition = parallel_workflow(parallel_id: 100)
      %{nodes: nodes, edges: edges} = GraphBuilder.build(definition)

      ids = Enum.map(nodes, & &1.id)
      assert ids == Enum.uniq(ids), "node ids must be unique; got #{inspect(ids)}"

      child_ids = Enum.filter(ids, &String.starts_with?(&1, "parallel_100__"))
      assert length(child_ids) == 2

      escaped_edges =
        Enum.filter(edges, fn e ->
          String.starts_with?(e.source, "parallel_100__") and
            not String.contains?(e.target, "parallel_100")
        end)

      assert escaped_edges == [],
             "no edge should leave a parallel child to a sibling outside the block"
    end
  end

  describe "GraphBuilder.build/1 — no fork/join marker nodes" do
    test "parallel emits no fork or join nodes; fan-out is via edges only" do
      definition = parallel_followed_by_step(parallel_id: 100)
      %{nodes: nodes, edges: edges} = GraphBuilder.build(definition)

      types = Enum.map(nodes, & &1.type) |> Enum.uniq()
      refute "parallel_fork" in types, "parallel_fork node must not be emitted"
      refute "parallel_join" in types, "parallel_join node must not be emitted"

      # `next` step has one inbound edge per parallel child.
      next_inbound = Enum.filter(edges, &(&1.target == "next"))
      assert length(next_inbound) == 2

      assert Enum.map(next_inbound, & &1.source) |> Enum.sort() ==
               ["parallel_100__do_a", "parallel_100__do_b"] |> Enum.sort()
    end
  end

  describe "GraphBuilder.build/1 — decision step :goto branches" do
    test "emits one labelled flow-edge-conditional edge per branch target" do
      definition = decision_workflow(branches: [:auto_remove, :approve_content])

      %{edges: edges} = GraphBuilder.build(definition)

      goto_edges =
        Enum.filter(edges, &(Map.get(&1, :className) == "flow-edge-conditional"))

      targets = goto_edges |> Enum.map(& &1.target) |> Enum.sort()
      assert targets == ["approve_content", "auto_remove"]

      labels = goto_edges |> Enum.map(& &1.label) |> Enum.sort()
      assert labels == ["goto :approve_content", "goto :auto_remove"]
    end

    test "absent or empty :branches opt produces no conditional edges" do
      definition = decision_workflow(branches: [])

      %{edges: edges} = GraphBuilder.build(definition)

      refute Enum.any?(edges, &(Map.get(&1, :className) == "flow-edge-conditional"))
    end
  end

  describe "GraphBuilder.build/1 — onboarding-shape DAG" do
    test "linear-then-parallel-then-linear produces the expected fan-out shape" do
      definition = onboarding_shape()
      %{nodes: nodes, edges: edges} = GraphBuilder.build(definition)

      # 5 top-level steps + 1 parallel block (4 children) = 9 nodes.
      # The flat parallel-children entries are deduped by graph_builder.
      assert length(nodes) == 9

      # No marker nodes anywhere.
      types = Enum.map(nodes, & &1.type) |> Enum.uniq()
      refute "parallel_fork" in types
      refute "parallel_join" in types

      # collect_equipment_preferences fans out to every parallel child.
      collect_outbound =
        edges |> Enum.filter(&(&1.source == "collect_equipment_preferences"))

      assert length(collect_outbound) == 4

      # Every parallel child fans into manager_review.
      manager_inbound = Enum.filter(edges, &(&1.target == "manager_review"))
      assert length(manager_inbound) == 4

      # Terminal chain stays linear.
      assert edge_exists?(edges, "manager_review", "schedule_orientation")
      assert edge_exists?(edges, "schedule_orientation", "send_welcome_package")
    end
  end

  describe "GraphBuilder.overlay_status/2 — original_name fallback" do
    test "matches by qualified id when persisted name aligns with the definition" do
      definition = parallel_workflow(parallel_id: 100)
      graph = GraphBuilder.build(definition)

      execs = [
        step_execution(name: "parallel_100__do_a", status: :completed, duration_ms: 12),
        step_execution(name: "parallel_100__do_b", status: :running)
      ]

      %{nodes: nodes} = GraphBuilder.overlay_status(graph, execs)

      assert status_for(nodes, "parallel_100__do_a") == "completed"
      assert status_for(nodes, "parallel_100__do_b") == "running"
    end

    test "matches by original_name when the persisted parallel_id differs from the definition" do
      # The current definition compiled with parallel_id=200, but the
      # workflow was originally executed when parallel_id=100. The
      # persisted step_name reflects the older id.
      definition = parallel_workflow(parallel_id: 200)
      graph = GraphBuilder.build(definition)

      execs = [
        step_execution(name: "parallel_100__do_a", status: :completed, duration_ms: 12),
        step_execution(name: "parallel_100__do_b", status: :failed)
      ]

      %{nodes: nodes} = GraphBuilder.overlay_status(graph, execs)

      # Node id reflects the new compile (200), but lookup falls back to
      # original_name and finds the persisted execution.
      assert status_for(nodes, "parallel_200__do_a") == "completed"
      assert duration_for(nodes, "parallel_200__do_a") == 12
      assert status_for(nodes, "parallel_200__do_b") == "failed"
    end

    test "top-level step names continue to match by id" do
      definition = simple_workflow()
      graph = GraphBuilder.build(definition)

      execs = [step_execution(name: "register", status: :completed, duration_ms: 5)]

      %{nodes: nodes} = GraphBuilder.overlay_status(graph, execs)

      assert status_for(nodes, "register") == "completed"
    end

    test "exposes started_at, completed_at and step_execution_id on matched nodes" do
      definition = simple_workflow()
      graph = GraphBuilder.build(definition)

      started = ~U[2026-04-25 10:00:00Z]
      completed = ~U[2026-04-25 10:00:05Z]

      execs = [
        step_execution(
          id: "step-exec-1",
          name: "register",
          status: :completed,
          duration_ms: 5_000,
          started_at: started,
          completed_at: completed
        )
      ]

      %{nodes: nodes} = GraphBuilder.overlay_status(graph, execs)
      data = node_data(nodes, "register")

      assert data.started_at == DateTime.to_iso8601(started)
      assert data.completed_at == DateTime.to_iso8601(completed)
      assert data.step_execution_id == "step-exec-1"
    end
  end

  # ============================================================================
  # Test fixtures
  # ============================================================================

  defp simple_workflow do
    %Definition.Workflow{
      name: "simple",
      module: __MODULE__,
      steps: [
        %Definition.Step{name: :register, type: :step, module: __MODULE__, opts: %{}}
      ]
    }
  end

  # Mirrors what the parallel macro splices into @durable_current_steps:
  # the parallel block itself, plus a flat copy of each child as a
  # standalone :step entry. GraphBuilder must dedupe these.
  defp parallel_workflow(parallel_id: pid) do
    children = [
      :"parallel_#{pid}__do_a",
      :"parallel_#{pid}__do_b"
    ]

    %Definition.Workflow{
      name: "parallel_test",
      module: __MODULE__,
      steps: [
        %Definition.Step{
          name: :"parallel_#{pid}",
          type: :parallel,
          module: __MODULE__,
          opts: %{steps: children, all_steps: children}
        },
        %Definition.Step{
          name: :"parallel_#{pid}__do_a",
          type: :step,
          module: __MODULE__,
          opts: %{parallel_id: pid, original_name: :do_a}
        },
        %Definition.Step{
          name: :"parallel_#{pid}__do_b",
          type: :step,
          module: __MODULE__,
          opts: %{parallel_id: pid, original_name: :do_b}
        }
      ]
    }
  end

  defp parallel_followed_by_step(parallel_id: pid) do
    children = [:"parallel_#{pid}__do_a", :"parallel_#{pid}__do_b"]

    %Definition.Workflow{
      name: "parallel_then_next",
      module: __MODULE__,
      steps: [
        %Definition.Step{
          name: :"parallel_#{pid}",
          type: :parallel,
          module: __MODULE__,
          opts: %{steps: children, all_steps: children}
        },
        %Definition.Step{
          name: :"parallel_#{pid}__do_a",
          type: :step,
          module: __MODULE__,
          opts: %{parallel_id: pid, original_name: :do_a}
        },
        %Definition.Step{
          name: :"parallel_#{pid}__do_b",
          type: :step,
          module: __MODULE__,
          opts: %{parallel_id: pid, original_name: :do_b}
        },
        %Definition.Step{name: :next, type: :step, module: __MODULE__, opts: %{}}
      ]
    }
  end

  defp decision_workflow(branches: branches) do
    %Definition.Workflow{
      name: "decision_test",
      module: __MODULE__,
      steps: [
        %Definition.Step{
          name: :triage,
          type: :decision,
          module: __MODULE__,
          opts: %{branches: branches}
        },
        %Definition.Step{name: :auto_remove, type: :step, module: __MODULE__, opts: %{}},
        %Definition.Step{name: :approve_content, type: :step, module: __MODULE__, opts: %{}}
      ]
    }
  end

  # Mirrors PhoenixDemo.Workflows.OnboardingWorkflow's structural shape
  # without importing the demo (avoids cross-package test dep).
  defp onboarding_shape do
    children = [:setup_email, :setup_dev_tools, :order_equipment, :create_payroll_record]

    %Definition.Workflow{
      name: "onboarding_shape",
      module: __MODULE__,
      steps: [
        %Definition.Step{name: :register_employee, type: :step, module: __MODULE__, opts: %{}},
        %Definition.Step{
          name: :collect_equipment_preferences,
          type: :step,
          module: __MODULE__,
          opts: %{}
        },
        %Definition.Step{
          name: :provision_parallel,
          type: :parallel,
          module: __MODULE__,
          opts: %{steps: children, all_steps: children}
        },
        %Definition.Step{
          name: :setup_email,
          type: :step,
          module: __MODULE__,
          opts: %{parallel_id: 1}
        },
        %Definition.Step{
          name: :setup_dev_tools,
          type: :step,
          module: __MODULE__,
          opts: %{parallel_id: 1}
        },
        %Definition.Step{
          name: :order_equipment,
          type: :step,
          module: __MODULE__,
          opts: %{parallel_id: 1}
        },
        %Definition.Step{
          name: :create_payroll_record,
          type: :step,
          module: __MODULE__,
          opts: %{parallel_id: 1}
        },
        %Definition.Step{name: :manager_review, type: :step, module: __MODULE__, opts: %{}},
        %Definition.Step{name: :schedule_orientation, type: :step, module: __MODULE__, opts: %{}},
        %Definition.Step{name: :send_welcome_package, type: :step, module: __MODULE__, opts: %{}}
      ]
    }
  end

  defp edge_exists?(edges, source, target) do
    Enum.any?(edges, &(&1.source == source and &1.target == target))
  end

  defp step_execution(opts) do
    %{
      id:
        Keyword.get(opts, :id, "exec-" <> Integer.to_string(:erlang.unique_integer([:positive]))),
      step_name: Keyword.fetch!(opts, :name),
      status: Keyword.fetch!(opts, :status),
      attempt: Keyword.get(opts, :attempt, 1),
      duration_ms: Keyword.get(opts, :duration_ms),
      started_at: Keyword.get(opts, :started_at),
      completed_at: Keyword.get(opts, :completed_at),
      inserted_at: Keyword.get(opts, :inserted_at, DateTime.utc_now())
    }
  end

  defp status_for(nodes, id), do: nodes |> node_data(id) |> Map.get(:status)
  defp duration_for(nodes, id), do: nodes |> node_data(id) |> Map.get(:duration_ms)

  defp node_data(nodes, id) do
    Enum.find_value(nodes, fn node ->
      if node.id == id, do: node.data, else: nil
    end)
  end
end
