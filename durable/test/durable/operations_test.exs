defmodule Durable.OperationsTest do
  @moduledoc """
  Running Durable in production: the retention pruner and the node registry.
  """
  use Durable.DataCase, async: false
  use ExUnitProperties

  alias Durable.Config
  alias Durable.Pruner
  alias Durable.Storage.Schemas.{Node, StepExecution, WorkflowExecution}

  @statuses [:pending, :running, :waiting, :completed, :failed, :cancelled, :compensated]
  @group %{completed: :completed, failed: :failed, compensated: :failed, cancelled: :cancelled}

  defp insert_run!(status, age_ms) do
    repo = Config.get(Durable).repo
    finished_at = DateTime.add(DateTime.utc_now(), -age_ms, :millisecond)

    run =
      repo.insert!(%WorkflowExecution{
        workflow_module: "Elixir.Unused",
        workflow_name: "unused",
        status: status,
        completed_at: if(status in [:completed, :failed, :cancelled], do: finished_at),
        updated_at: finished_at
      })

    repo.insert!(%StepExecution{workflow_id: run.id, step_name: "s", status: :completed})
    run
  end

  defp ids(schema), do: schema |> Config.get(Durable).repo.all() |> MapSet.new(& &1.id)

  describe "pruner" do
    test "deletes finished runs past their group's age, with their steps" do
      config = %{Config.get(Durable) | prune: [completed: 1_000, failed: 60_000]}

      old_done = insert_run!(:completed, 5_000)
      fresh_done = insert_run!(:completed, 10)
      old_failed = insert_run!(:failed, 120_000)
      rolled_back = insert_run!(:compensated, 120_000)
      young_failed = insert_run!(:failed, 5_000)
      old_cancelled = insert_run!(:cancelled, 120_000)
      old_running = insert_run!(:running, 120_000)

      assert Pruner.prune(config) == %{completed: 1, failed: 2}

      survivors = ids(WorkflowExecution)
      for gone <- [old_done, old_failed, rolled_back], do: refute(gone.id in survivors)

      for kept <- [fresh_done, young_failed, old_cancelled, old_running],
          do: assert(kept.id in survivors)

      steps = Config.get(Durable).repo.all(StepExecution)
      refute Enum.any?(steps, &(&1.workflow_id == old_done.id))
    end

    test "is a no-op without a :prune policy" do
      insert_run!(:completed, 999_999_999)
      assert Durable.prune() == %{}
    end
  end

  property "the pruner deletes exactly the finished runs older than their group's limit" do
    check all(
            runs <- list_of(tuple({member_of(@statuses), integer(0..100_000)}), max_length: 12),
            policy <-
              fixed_map(%{
                completed: one_of([constant(nil), integer(1..100_000)]),
                failed: one_of([constant(nil), integer(1..100_000)]),
                cancelled: one_of([constant(nil), integer(1..100_000)])
              }),
            max_runs: 40
          ) do
      Config.get(Durable).repo.delete_all(WorkflowExecution)
      policy = for {group, ms} <- policy, ms, do: {group, ms}
      config = %{Config.get(Durable) | prune: policy}

      inserted = for {status, age} <- runs, do: {insert_run!(status, age), status, age}
      Pruner.prune(config)
      survivors = ids(WorkflowExecution)

      for {run, status, age} <- inserted do
        limit = policy[@group[status]]
        # A run right at its limit races the clock; only assert clear cases.
        if limit == nil or age < limit - 50, do: assert(run.id in survivors)
        if limit != nil and age > limit + 50, do: refute(run.id in survivors)
      end
    end
  end

  describe "node registry" do
    test "this node heartbeats into durable.nodes and is reported alive" do
      node_id = Config.get(Durable).node_id

      assert_eventually(fn ->
        Enum.any?(Durable.list_nodes(), &(&1.id == node_id and &1.status == :alive))
      end)
    end

    test "a node whose heartbeat is 30 s old is reported missing" do
      stale = DateTime.add(DateTime.utc_now(), -31, :second)

      Config.get(Durable).repo.insert!(%Node{
        id: "gone-node",
        queues: ["default"],
        started_at: stale,
        heartbeat_at: stale
      })

      assert %{status: :missing} = Enum.find(Durable.list_nodes(), &(&1.id == "gone-node"))
    end

    test "counts the runs each node holds a lock on" do
      now = DateTime.utc_now()
      repo = Config.get(Durable).repo
      repo.insert!(%Node{id: "busy-node", queues: [], started_at: now, heartbeat_at: now})

      for status <- [:running, :running, :completed] do
        repo.insert!(%WorkflowExecution{
          workflow_module: "Elixir.Unused",
          workflow_name: "unused",
          status: status,
          locked_by: "busy-node"
        })
      end

      assert %{running: 2} = Enum.find(Durable.list_nodes(), &(&1.id == "busy-node"))
    end

    test "a cleanly stopped node removes its row" do
      node_id = Config.get(Durable).node_id
      assert_eventually(fn -> Enum.any?(Durable.list_nodes(), &(&1.id == node_id)) end)

      stop_supervised!(Durable)

      repo = Durable.TestRepo
      refute repo.get(Node, node_id, prefix: "durable")
    end
  end
end
