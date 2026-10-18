defmodule DurableDashboard.StructureTest do
  use ExUnit.Case, async: true

  alias Durable.Definition.{Step, Workflow}
  alias DurableDashboard.Components.Workflow.Structure

  defp step(name, type \\ :step, opts \\ %{}),
    do: %Step{name: name, type: type, module: __MODULE__, opts: opts}

  defp stats(step, runs, failed_runs, p95, extra \\ %{}) do
    Map.merge(
      %{step: step, runs: runs, failed_runs: failed_runs, p95_ms: p95, retried_runs: 0},
      extra
    )
  end

  defp definition(steps, compensations \\ %{}),
    do: %Workflow{name: "w", module: __MODULE__, steps: steps, compensations: compensations}

  test "steps carry traffic; compensations attach to the step they undo" do
    definition =
      definition(
        [step(:reserve, :step, %{compensate: :release}), step(:charge), step(:ship)],
        %{release: %{}}
      )

    built =
      Structure.build(
        definition,
        [
          stats("reserve", 100, 0, 120),
          stats("charge", 100, 30, 1),
          stats("ship", 70, 7, 80),
          # Compensation attempts are recorded as compensate_<name>.
          stats("compensate_release", 37, 0, 5)
        ],
        110
      )

    assert [reserve, charge, ship] = built.nodes
    assert %{runs: 100, compensation: %{name: "release", runs: 37}} = reserve
    assert %{failed_runs: 30, failed_share: 0.3, flags: [:most_failures]} = charge
    assert ship.failed_share == 0.1
    assert built.peak == 110
    assert built.loose_compensations == []
    # 120 ms is over half the summed p95 (201 ms): that step is the slow one.
    assert reserve.flags == [:slowest]
  end

  test "near-equal millisecond steps aren't flagged slowest" do
    built =
      Structure.build(
        definition([step(:a), step(:b)]),
        [stats("a", 5, 0, 3), stats("b", 5, 0, 1)],
        5
      )

    assert Enum.all?(built.nodes, &(&1.flags == []))
  end

  test "parallel and branch blocks list what's inside, without their internal ids" do
    definition =
      definition([
        step(:parallel_1, :parallel, %{steps: [:parallel_1__a, :parallel_1__b]}),
        step(:parallel_1__a, :step, %{parallel_id: 1}),
        step(:parallel_1__b, :step, %{parallel_id: 1}),
        step(:branch_2, :branch, %{
          clauses: %{{:high, 0} => [:branch_2__high__x], {:_, 1} => [:branch_2__default__y]}
        }),
        step(:branch_2__high__x, :step, %{branch_id: 2}),
        step(:branch_2__default__y, :step, %{branch_id: 2})
      ])

    built =
      Structure.build(
        definition,
        [
          stats("parallel_1__a", 10, 1, 200),
          stats("parallel_1__b", 10, 0, 50),
          stats("branch_2__high__x", 3, 0, 1),
          stats("branch_2__default__y", 6, 0, 1)
        ],
        10
      )

    assert [parallel, branch] = built.nodes
    assert %{label: "parallel", runs: 10, failed_runs: 1, p95_ms: 200} = parallel
    assert Enum.map(parallel.children, & &1.label) == ["a", "b"]

    assert %{label: "branch", runs: 9} = branch
    assert [%{label: "high", runs: 3}, %{label: "otherwise", runs: 6}] = branch.clauses
  end
end
