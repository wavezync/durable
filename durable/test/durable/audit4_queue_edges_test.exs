defmodule Audit4QueueEdgeRow do
  @moduledoc false
  use Durable

  workflow "audit4_queue_edge_row" do
    step(:save, fn data -> {:ok, data} end)
  end
end

defmodule Audit4QueueEdgeChild do
  @moduledoc false
  use Durable

  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query

  # Its parent finishes and is pruned while this step is still running.
  workflow "audit4_queue_edge_child" do
    step(:outlive_parent, fn data ->
      config = Durable.Config.get(Durable)
      long_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)

      {1, _} =
        config.repo.update_all(
          from(w in WorkflowExecution, where: w.id == ^data["parent"]),
          set: [completed_at: long_ago, updated_at: long_ago]
        )

      pruned = Durable.Pruner.prune(%{config | prune: [completed: 1_000]})
      {:ok, Map.put(data, "pruned", pruned.completed)}
    end)
  end
end

defmodule Audit4QueueEdgeParent do
  @moduledoc false
  use Durable
  use Durable.Context
  use Durable.Orchestration

  workflow "audit4_queue_edge_parent" do
    step(:kick_off, fn data ->
      {:ok, child} =
        start_workflow(Audit4QueueEdgeChild, %{"parent" => workflow_id()}, ref: :child)

      {:ok, Map.put(data, "child", child)}
    end)
  end
end

defmodule Durable.Audit4QueueEdgesTest do
  @moduledoc """
  Audit 4: odd inputs to `start_many`, schedules whose code isn't here, and
  the pruner deleting a run another run still points at.
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{ScheduledWorkflow, WorkflowExecution}

  defp runs, do: TestRepo.all(from(w in WorkflowExecution, order_by: w.inserted_at))

  describe "start_many/2" do
    test "with nothing to start starts nothing" do
      assert Durable.start_many([]) == []
      assert runs() == []
    end

    test "gives a bad item its own error and still starts the rest" do
      results =
        Durable.start_many([
          {Audit4QueueEdgeRow, %{"row" => 1}},
          {Audit4QueueEdgeRow, "not a map"},
          {NoSuchModule, %{}},
          {Audit4QueueEdgeRow, %{"row" => 2}, workflow: "no_such_workflow"},
          {Audit4QueueEdgeRow, %{"row" => 3}}
        ])

      assert [{:ok, one}, {:error, :invalid_input}, {:error, _}, {:error, _}, {:ok, three}] =
               results

      assert Enum.map(runs(), & &1.id) == [one, three]
    end

    test "starts nothing when an item raises" do
      assert_raise ArgumentError, fn ->
        Durable.start_many([
          {Audit4QueueEdgeRow, %{"row" => 1}},
          {Audit4QueueEdgeRow, %{"row" => 2}, on_duplicate: :no_such_mode, key: "k"}
        ])
      end

      assert runs() == []
    end

    test "a run scheduled for later keeps its time and its queue" do
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      [{:ok, now}, {:ok, then}] =
        Durable.start_many(
          [{Audit4QueueEdgeRow, %{}}, {Audit4QueueEdgeRow, %{}, scheduled_at: later}],
          queue: :imports
        )

      assert %{scheduled_at: nil, queue: "imports", status: :pending} =
               TestRepo.get!(WorkflowExecution, now)

      then = TestRepo.get!(WorkflowExecution, then)
      assert DateTime.diff(then.scheduled_at, later, :second) == 0
      assert then.queue == "imports"
    end
  end

  describe "trigger_schedule/2" do
    # BUG: raises ArgumentError instead of returning an error. API.trigger_schedule/2
    # (scheduler/api.ex:303) calls String.to_existing_atom/1 on the stored module
    # name, which the scheduler's own check guards (scheduler.ex:292) and this doesn't.
    @tag :skip
    test "for a schedule whose module isn't on this node is an error, not a raise" do
      {:ok, schedule} = Durable.schedule(Audit4QueueEdgeRow, "0 9 * * *", name: "elsewhere")

      schedule
      |> Ecto.Changeset.change(workflow_module: "Audit4Queue.OnAnotherNode")
      |> TestRepo.update!()

      assert {:error, _reason} = Durable.trigger_schedule("elsewhere")
      assert runs() == []

      assert %ScheduledWorkflow{enabled: true} =
               TestRepo.get_by!(ScheduledWorkflow, name: "elsewhere")
    end
  end

  describe "the pruner" do
    test "can delete a finished parent while its child is mid-step, and the child still finishes" do
      config = Config.get(Durable)
      {:ok, parent} = Durable.start(Audit4QueueEdgeParent, %{})

      {:ok, %{status: :completed, context: %{"child" => child}}} =
        Executor.execute_workflow(parent, config)

      assert {:ok, %{status: :completed}} = Executor.execute_workflow(child, config)

      assert TestRepo.get(WorkflowExecution, parent) == nil

      assert %{status: :completed, parent_workflow_id: nil, context: %{"pruned" => 1}} =
               TestRepo.get!(WorkflowExecution, child)
    end
  end
end
