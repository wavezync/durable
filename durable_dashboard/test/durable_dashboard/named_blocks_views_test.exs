defmodule DurableDashboard.NamedBlocksViewsTest do
  @moduledoc "Named branches and lanes in the structure map and the family views."
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Workflow.{FamilyChip, Structure}
  alias DurableDashboard.NamedBlocksWorkflow

  defp stats(step, runs, failed_runs, p95),
    do: %{step: step, runs: runs, failed_runs: failed_runs, p95_ms: p95, retried_runs: 0}

  describe "the structure map" do
    setup do
      {:ok, definition} = NamedBlocksWorkflow.__workflow_definition__("named_blocks")

      built =
        Structure.build(
          definition,
          [
            stats("first", 100, 0, 5),
            stats("risk", 100, 2, 3),
            stats("risk__review__ask", 30, 0, 9),
            stats("risk__blocked__ask", 8, 1, 9),
            stats("fulfil__ship__pack", 90, 0, 20),
            stats("fulfil__ship__where", 90, 0, 1),
            stats("fulfil__ship__where__home__courier", 80, 4, 40),
            stats("fulfil__papers__docs__invoice", 90, 0, 7),
            stats("fulfil__papers__file", 90, 0, 2),
            stats("fulfil__points", 90, 3, 1),
            stats("close", 83, 0, 1)
          ],
          100
        )

      {:ok, built: built}
    end

    test "has a card for each top-level step and block, and none for what a block holds",
         %{built: built} do
      assert Enum.map(built.nodes, &{&1.type, &1.label}) == [
               {:step, "first"},
               {:branch, "risk"},
               {:parallel, "fulfil"},
               {:step, "close"}
             ]
    end

    test "a named branch lists its arms, and its traffic is its deciding step's",
         %{built: built} do
      branch = Enum.at(built.nodes, 1)

      assert %{runs: 100, note: "3 paths"} = branch

      assert Enum.map(branch.clauses, &{&1.label, &1.runs}) ==
               [{"clear", 0}, {"review", 30}, {"blocked", 8}]

      # The deciding step's own failures, and those inside its arms.
      assert branch.failed_runs == 3
    end

    test "a named parallel block lists its lanes", %{built: built} do
      block = Enum.at(built.nodes, 2)

      assert block.note == "3 lanes · fail fast"

      assert Enum.map(block.children, &{&1.label, &1.runs, &1.failed_runs, &1.p95_ms}) == [
               {"ship", 90, 4, 40},
               {"papers", 90, 0, 7},
               {"points", 90, 3, 1}
             ]

      assert %{runs: 90, failed_runs: 7} = block
    end

    test "draws: the branch by name with its arms, the block with its lanes", %{built: built} do
      html =
        render_component(&Structure.map/1,
          structure: built,
          finished: %{completed: 83, failed: 17, cancelled: 0, compensated: 0},
          base_path: "/durable",
          workflow: "named_blocks"
        )

      for text <- ~w(risk review blocked fulfil ship papers points), do: assert(html =~ text)
      refute html =~ "risk__review__ask"
    end

    test "a block that collects says so" do
      {:ok, definition} = NamedBlocksWorkflow.__workflow_definition__("lookups")
      assert [%{note: "2 lanes · collect"}, _decide] = Structure.build(definition, [], 0).nodes
    end
  end

  test "a child run is named after the lane it is, however deep the block" do
    html =
      render_component(&FamilyChip.family_chip/1,
        family: %{parent: nil, children: [%{id: "c1c1c1c1-0000", status: :completed}]},
        workflow: %{id: "w"},
        base_path: "/durable",
        parent_step_lookup: %{"c1c1c1c1-0000" => "risk__review__fulfil__papers"}
      )

    assert html =~ "Started by step papers"
    refute html =~ "risk__review"
  end
end
