defmodule Durable.ParallelRaceTest do
  @moduledoc """
  Regression tests for the parallel-children completion path. Each test
  exercises a state shape the production incident actually exhibited:

    * Multiple children of an `each` / parallel step completing
      concurrently can race on the shared WaitGroup row. Without
      row-level locking, the read-modify-write on `received_events`
      drops one of the children's payloads, the wait group never
      reaches `:completed`, the parent never resumes, and stale-lock
      recovery later marks the parent as a zombie.
    * Each `__parallel_done` PendingEvent must transition to `:received`
      AND the WaitGroup must record the event AND (when the wait is
      satisfied) the parent must flip `:waiting` -> `:pending`. All
      three updates run inside a single transaction so a crash mid-way
      can't leave a half-applied state behind.
  """

  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{PendingEvent, WaitGroup, WorkflowExecution}

  import Ecto.Query

  describe "WaitGroup.add_event_locked/4" do
    test "sequentially merges every event and only completes once the wait condition is satisfied" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, workflow} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(%{
          workflow_module: "Test.Module",
          workflow_name: "test",
          status: :waiting,
          queue: "default",
          priority: 0,
          input: %{},
          context: %{}
        })
        |> repo.insert()

      event_names = ["a", "b", "c"]

      {:ok, wait_group} =
        %WaitGroup{}
        |> WaitGroup.changeset(%{
          workflow_id: workflow.id,
          step_name: "fan_out",
          wait_type: :all,
          event_names: event_names
        })
        |> repo.insert()

      # First two events: still :pending.
      Enum.each(["a", "b"], fn name ->
        repo.transaction(fn ->
          {:ok, result} =
            WaitGroup.add_event_locked(repo, wait_group.id, name, %{"name" => name})

          refute result.just_completed
          assert result.wait_group.status == :pending
        end)
      end)

      # Third event flips the wait group to :completed exactly once.
      repo.transaction(fn ->
        {:ok, result} = WaitGroup.add_event_locked(repo, wait_group.id, "c", %{"name" => "c"})

        assert result.just_completed
        assert result.wait_group.status == :completed
      end)

      reloaded = repo.get!(WaitGroup, wait_group.id)
      assert reloaded.status == :completed

      assert Map.keys(reloaded.received_events) |> Enum.sort() == event_names
    end

    test "late arrivals after :completed are an idempotent no-op" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, workflow} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(%{
          workflow_module: "Test.Module",
          workflow_name: "test",
          status: :waiting,
          queue: "default",
          priority: 0,
          input: %{},
          context: %{}
        })
        |> repo.insert()

      {:ok, wait_group} =
        %WaitGroup{}
        |> WaitGroup.changeset(%{
          workflow_id: workflow.id,
          step_name: "any_branch",
          wait_type: :any,
          event_names: ["a", "b"]
        })
        |> repo.insert()

      # First event satisfies the :any wait.
      repo.transaction(fn ->
        {:ok, result} = WaitGroup.add_event_locked(repo, wait_group.id, "a", %{"first" => true})
        assert result.just_completed
      end)

      # Late "b" arrival doesn't grow received_events and doesn't mark
      # itself as just_completed (which would re-resume the parent).
      repo.transaction(fn ->
        {:ok, result} = WaitGroup.add_event_locked(repo, wait_group.id, "b", %{"second" => true})

        refute result.just_completed
        assert result.wait_group.status == :completed
        refute Map.has_key?(result.wait_group.received_events, "b")
      end)

      reloaded = repo.get!(WaitGroup, wait_group.id)
      assert Map.keys(reloaded.received_events) == ["a"]
    end
  end

  describe "parallel children completing concurrently" do
    test "all children's events land in received_events and parent resumes" do
      # 5 concurrently-completing children is enough for the lost-update
      # race in the old code to almost always drop at least one event;
      # the new code locks the wait_group row, so every event ends up in
      # received_events regardless of execution order.
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(FiveWayParallelWorkflow, %{})
      assert parent.status == :waiting

      children = list_children(repo, parent.id)
      assert length(children) == 5

      # Drive all children concurrently. With the sandbox in shared mode
      # the spawned tasks serialize on the test connection, but the test
      # still exercises the full multi-step transaction for each child
      # and asserts the merged final state.
      children
      |> Task.async_stream(
        fn child -> Executor.execute_workflow(child.id, config) end,
        max_concurrency: 5,
        ordered: false,
        timeout: 10_000
      )
      |> Stream.run()

      [wait_group] = repo.all(from(w in WaitGroup, where: w.workflow_id == ^parent.id))
      assert wait_group.status == :completed
      assert map_size(wait_group.received_events) == 5

      pending_events = repo.all(from(p in PendingEvent, where: p.workflow_id == ^parent.id))
      assert length(pending_events) == 5
      assert Enum.all?(pending_events, &(&1.status == :received))

      reloaded = repo.get!(WorkflowExecution, parent.id)
      assert reloaded.status == :pending

      Executor.execute_workflow(reloaded.id, config)
      finalized = repo.get!(WorkflowExecution, parent.id)
      assert finalized.status == :completed
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp create_and_execute_workflow(module, input) do
    config = Config.get(Durable)
    repo = config.repo
    {:ok, workflow_def} = module.__default_workflow__()

    {:ok, execution} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(%{
        workflow_module: Atom.to_string(module),
        workflow_name: workflow_def.name,
        status: :pending,
        queue: "default",
        priority: 0,
        input: input,
        context: %{}
      })
      |> repo.insert()

    Executor.execute_workflow(execution.id, config)
    {:ok, repo.get!(WorkflowExecution, execution.id)}
  end

  defp list_children(repo, parent_id) do
    repo.all(
      from(w in WorkflowExecution,
        where: w.parent_workflow_id == ^parent_id,
        order_by: [asc: :inserted_at]
      )
    )
  end
end

defmodule FiveWayParallelWorkflow do
  use Durable
  use Durable.Helpers

  workflow "five_way_parallel" do
    step(:setup, fn data -> {:ok, assign(data, :initialized, true)} end)

    parallel do
      step(:branch_1, fn data -> {:ok, assign(data, :b1, true)} end)
      step(:branch_2, fn data -> {:ok, assign(data, :b2, true)} end)
      step(:branch_3, fn data -> {:ok, assign(data, :b3, true)} end)
      step(:branch_4, fn data -> {:ok, assign(data, :b4, true)} end)
      step(:branch_5, fn data -> {:ok, assign(data, :b5, true)} end)
    end

    step(:done, fn data -> {:ok, assign(data, :done, true)} end)
  end
end
