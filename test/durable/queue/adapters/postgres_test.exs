defmodule Durable.Queue.Adapters.PostgresTest do
  use Durable.DataCase, async: false

  alias Durable.Queue.Adapters.Postgres
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

  describe "fetch_jobs/3" do
    test "claims pending jobs atomically" do
      # Create 5 pending jobs
      for i <- 1..5 do
        insert_execution(workflow_name: "test_#{i}")
      end

      # Fetch 3 jobs
      jobs = Postgres.fetch_jobs("default", 3, "node_a")

      assert length(jobs) == 3

      # Verify jobs are locked
      for job <- jobs do
        execution = Repo.get!(WorkflowExecution, job.id)
        assert execution.locked_by == "node_a"
        assert execution.status == :running
        assert execution.locked_at != nil
      end
    end

    test "respects priority ordering (higher first)" do
      # Create jobs with different priorities
      low = insert_execution(priority: 0, workflow_name: "low")
      high = insert_execution(priority: 10, workflow_name: "high")
      medium = insert_execution(priority: 5, workflow_name: "medium")

      jobs = Postgres.fetch_jobs("default", 3, "node_a")

      assert length(jobs) == 3
      assert Enum.at(jobs, 0).id == high.id
      assert Enum.at(jobs, 1).id == medium.id
      assert Enum.at(jobs, 2).id == low.id
    end

    test "respects scheduled_at ordering after priority" do
      now = DateTime.utc_now()
      later = DateTime.add(now, -60, :second)
      earlier = DateTime.add(now, -120, :second)

      job_later = insert_execution(scheduled_at: later, workflow_name: "later")
      job_earlier = insert_execution(scheduled_at: earlier, workflow_name: "earlier")

      jobs = Postgres.fetch_jobs("default", 2, "node_a")

      assert length(jobs) == 2
      # Earlier scheduled_at should come first
      assert Enum.at(jobs, 0).id == job_earlier.id
      assert Enum.at(jobs, 1).id == job_later.id
    end

    test "skips already locked jobs" do
      # Create a locked job
      _locked =
        insert_execution(
          workflow_name: "locked",
          locked_by: "other_node",
          locked_at: DateTime.utc_now(),
          status: :running
        )

      # Create an unlocked job
      unlocked = insert_execution(workflow_name: "unlocked")

      jobs = Postgres.fetch_jobs("default", 10, "node_a")

      assert length(jobs) == 1
      assert Enum.at(jobs, 0).id == unlocked.id
    end

    test "skips jobs scheduled in the future" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      _future_job = insert_execution(scheduled_at: future, workflow_name: "future")
      now_job = insert_execution(workflow_name: "now")

      jobs = Postgres.fetch_jobs("default", 10, "node_a")

      assert length(jobs) == 1
      assert Enum.at(jobs, 0).id == now_job.id
    end

    test "concurrent fetch_jobs claims different jobs" do
      # Create 10 jobs
      for i <- 1..10 do
        insert_execution(workflow_name: "test_#{i}")
      end

      # Simulate concurrent claims
      task1 = Task.async(fn -> Postgres.fetch_jobs("default", 5, "node_a") end)
      task2 = Task.async(fn -> Postgres.fetch_jobs("default", 5, "node_b") end)

      jobs1 = Task.await(task1)
      jobs2 = Task.await(task2)

      # Verify no overlap
      ids1 = MapSet.new(Enum.map(jobs1, & &1.id))
      ids2 = MapSet.new(Enum.map(jobs2, & &1.id))

      assert MapSet.disjoint?(ids1, ids2)
      assert MapSet.size(MapSet.union(ids1, ids2)) == 10
    end
  end

  describe "recover_stale_locks/1" do
    test "releases jobs locked longer than timeout" do
      # Create a job with stale lock (10 minutes ago)
      stale_time = DateTime.add(DateTime.utc_now(), -600, :second)

      stale_job =
        insert_execution(
          workflow_name: "stale",
          locked_by: "dead_node",
          locked_at: stale_time,
          status: :running
        )

      {:ok, count} = Postgres.recover_stale_locks(300)

      assert count == 1

      execution = Repo.get!(WorkflowExecution, stale_job.id)
      assert execution.status == :pending
      assert execution.locked_by == nil
      assert execution.locked_at == nil
    end

    test "does not release recently locked jobs" do
      # Create a job locked 1 minute ago
      recent_time = DateTime.add(DateTime.utc_now(), -60, :second)

      recent_job =
        insert_execution(
          workflow_name: "recent",
          locked_by: "active_node",
          locked_at: recent_time,
          status: :running
        )

      {:ok, count} = Postgres.recover_stale_locks(300)

      assert count == 0

      execution = Repo.get!(WorkflowExecution, recent_job.id)
      assert execution.status == :running
      assert execution.locked_by == "active_node"
    end
  end

  describe "ack/1" do
    test "clears lock fields" do
      job =
        insert_execution(
          workflow_name: "test",
          locked_by: "node_a",
          locked_at: DateTime.utc_now(),
          status: :running
        )

      :ok = Postgres.ack(job.id)

      execution = Repo.get!(WorkflowExecution, job.id)
      assert execution.locked_by == nil
      assert execution.locked_at == nil
    end

    test "returns error for non-existent job" do
      result = Postgres.ack(Ecto.UUID.generate())
      assert result == {:error, :not_found}
    end
  end

  describe "nack/2" do
    test "marks job as failed and clears lock" do
      job =
        insert_execution(
          workflow_name: "test",
          locked_by: "node_a",
          locked_at: DateTime.utc_now(),
          status: :running
        )

      :ok = Postgres.nack(job.id, %{message: "Something went wrong"})

      execution = Repo.get!(WorkflowExecution, job.id)
      assert execution.status == :failed
      assert execution.error["message"] == "Something went wrong"
      assert execution.locked_by == nil
      assert execution.locked_at == nil
      assert execution.completed_at != nil
    end
  end

  describe "reschedule/2" do
    test "sets scheduled_at and clears lock" do
      job =
        insert_execution(
          workflow_name: "test",
          locked_by: "node_a",
          locked_at: DateTime.utc_now(),
          status: :running
        )

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      :ok = Postgres.reschedule(job.id, future)

      execution = Repo.get!(WorkflowExecution, job.id)
      assert execution.status == :pending
      assert DateTime.compare(execution.scheduled_at, future) == :eq
      assert execution.locked_by == nil
      assert execution.locked_at == nil
    end
  end

  describe "heartbeat/1" do
    test "updates locked_at timestamp" do
      old_time = DateTime.add(DateTime.utc_now(), -60, :second)

      job =
        insert_execution(
          workflow_name: "heartbeat_test",
          locked_by: "node_a",
          locked_at: old_time,
          status: :running
        )

      :ok = Postgres.heartbeat(job.id)

      updated = Repo.get!(WorkflowExecution, job.id)
      assert DateTime.compare(updated.locked_at, old_time) == :gt
    end

    test "returns error for non-existent job" do
      result = Postgres.heartbeat(Ecto.UUID.generate())
      assert result == {:error, :not_found}
    end

    test "returns error for non-running job" do
      job = insert_execution(workflow_name: "pending_job", status: :pending)
      result = Postgres.heartbeat(job.id)
      assert result == {:error, :not_found}
    end
  end

  describe "get_stats/1" do
    test "returns queue statistics" do
      insert_execution(workflow_name: "pending1", status: :pending)
      insert_execution(workflow_name: "pending2", status: :pending)
      insert_execution(workflow_name: "running", status: :running)
      insert_execution(workflow_name: "completed", status: :completed)
      insert_execution(workflow_name: "failed", status: :failed)

      stats = Postgres.get_stats("default")

      assert stats.queue == "default"
      assert stats.pending == 2
      assert stats.running == 1
      assert stats.completed == 1
      assert stats.failed == 1
      assert stats.total == 5
    end
  end

  # Helper functions

  defp insert_execution(opts) do
    attrs = %{
      workflow_module: "TestWorkflow",
      workflow_name: Keyword.get(opts, :workflow_name, "test"),
      status: Keyword.get(opts, :status, :pending),
      queue: Keyword.get(opts, :queue, "default"),
      priority: Keyword.get(opts, :priority, 0),
      input: %{},
      context: %{},
      scheduled_at: Keyword.get(opts, :scheduled_at),
      locked_by: Keyword.get(opts, :locked_by),
      locked_at: Keyword.get(opts, :locked_at)
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> Repo.insert!()
  end
end
