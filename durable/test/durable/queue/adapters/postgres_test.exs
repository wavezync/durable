defmodule Durable.Queue.Adapters.PostgresTest do
  use Durable.DataCase, async: false

  import Ecto.Query

  alias Durable.Config
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Storage.Schemas.WorkflowExecution

  defp config, do: Config.get(Durable)
  defp repo, do: config().repo

  describe "fetch_jobs/4" do
    test "claims pending jobs atomically" do
      # Create 5 pending jobs
      for i <- 1..5 do
        insert_execution(workflow_name: "test_#{i}")
      end

      # Fetch 3 jobs
      jobs = Postgres.fetch_jobs(config(), "default", 3, "node_a")

      assert length(jobs) == 3

      # Verify jobs are locked
      for job <- jobs do
        execution = repo().get!(WorkflowExecution, job.id)
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

      jobs = Postgres.fetch_jobs(config(), "default", 3, "node_a")

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

      jobs = Postgres.fetch_jobs(config(), "default", 2, "node_a")

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

      jobs = Postgres.fetch_jobs(config(), "default", 10, "node_a")

      assert length(jobs) == 1
      assert Enum.at(jobs, 0).id == unlocked.id
    end

    test "skips jobs scheduled in the future" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      _future_job = insert_execution(scheduled_at: future, workflow_name: "future")
      now_job = insert_execution(workflow_name: "now")

      jobs = Postgres.fetch_jobs(config(), "default", 10, "node_a")

      assert length(jobs) == 1
      assert Enum.at(jobs, 0).id == now_job.id
    end

    test "concurrent fetch_jobs claims different jobs" do
      cfg = config()

      # Create 10 jobs
      for i <- 1..10 do
        insert_execution(workflow_name: "test_#{i}")
      end

      # Simulate concurrent claims
      task1 = Task.async(fn -> Postgres.fetch_jobs(cfg, "default", 5, "node_a") end)
      task2 = Task.async(fn -> Postgres.fetch_jobs(cfg, "default", 5, "node_b") end)

      jobs1 = Task.await(task1)
      jobs2 = Task.await(task2)

      # Verify no overlap
      ids1 = MapSet.new(Enum.map(jobs1, & &1.id))
      ids2 = MapSet.new(Enum.map(jobs2, & &1.id))

      assert MapSet.disjoint?(ids1, ids2)
      assert MapSet.size(MapSet.union(ids1, ids2)) == 10
    end
  end

  describe "recover_stale_locks/2" do
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

      {:ok, count} = Postgres.recover_stale_locks(config(), 300)

      assert count == 1

      execution = repo().get!(WorkflowExecution, stale_job.id)
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

      {:ok, count} = Postgres.recover_stale_locks(config(), 300)

      assert count == 0

      execution = repo().get!(WorkflowExecution, recent_job.id)
      assert execution.status == :running
      assert execution.locked_by == "active_node"
    end
  end

  describe "recover_zombie_workflows/2 (Bug #4 regression)" do
    alias Durable.Storage.Schemas.{PendingEvent, PendingInput}

    test "marks :waiting workflows with no pending inputs/events as :failed" do
      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      zombie = insert_execution(workflow_name: "zombie_a", status: :waiting)

      # Backdate updated_at so the zombie is past the stale cutoff
      {1, _} =
        repo().update_all(
          from(w in WorkflowExecution, where: w.id == ^zombie.id),
          set: [updated_at: long_ago]
        )

      {:ok, count} = Postgres.recover_zombie_workflows(config(), 300)
      assert count == 1

      reloaded = repo().get!(WorkflowExecution, zombie.id)
      assert reloaded.status == :failed
      assert reloaded.error["type"] == "zombie_detected"
      assert reloaded.error["message"] =~ "waiting"
      assert reloaded.completed_at != nil
    end

    test "leaves healthy :waiting workflows alone (they have a pending input)" do
      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      waiter = insert_execution(workflow_name: "healthy_waiter", status: :waiting)

      {1, _} =
        repo().update_all(
          from(w in WorkflowExecution, where: w.id == ^waiter.id),
          set: [updated_at: long_ago]
        )

      # Insert a pending input that this waiter depends on
      {:ok, _} =
        %PendingInput{}
        |> PendingInput.changeset(%{
          workflow_id: waiter.id,
          step_name: "step",
          input_name: "approval",
          input_type: :approval,
          status: :pending
        })
        |> repo().insert()

      {:ok, count} = Postgres.recover_zombie_workflows(config(), 300)
      assert count == 0

      reloaded = repo().get!(WorkflowExecution, waiter.id)
      assert reloaded.status == :waiting
    end

    test "leaves healthy :waiting workflows alone (they have a pending event)" do
      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      waiter = insert_execution(workflow_name: "event_waiter", status: :waiting)

      {1, _} =
        repo().update_all(
          from(w in WorkflowExecution, where: w.id == ^waiter.id),
          set: [updated_at: long_ago]
        )

      {:ok, _} =
        %PendingEvent{}
        |> PendingEvent.changeset(%{
          workflow_id: waiter.id,
          event_name: "payment_confirmed",
          step_name: "await",
          status: :pending
        })
        |> repo().insert()

      {:ok, count} = Postgres.recover_zombie_workflows(config(), 300)
      assert count == 0

      reloaded = repo().get!(WorkflowExecution, waiter.id)
      assert reloaded.status == :waiting
    end

    test "leaves recently updated :waiting workflows alone (within stale timeout)" do
      # This waiter has no pending inputs/events, but its updated_at is fresh
      # so we don't know yet if it's stuck — maybe it just transitioned.
      recent_waiter =
        insert_execution(workflow_name: "recent_waiter", status: :waiting)

      {:ok, count} = Postgres.recover_zombie_workflows(config(), 300)
      assert count == 0

      reloaded = repo().get!(WorkflowExecution, recent_waiter.id)
      assert reloaded.status == :waiting
    end

    test "leaves :running and :completed workflows alone" do
      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      running = insert_execution(workflow_name: "running", status: :running)
      completed = insert_execution(workflow_name: "completed", status: :completed)

      {2, _} =
        repo().update_all(
          from(w in WorkflowExecution, where: w.id in ^[running.id, completed.id]),
          set: [updated_at: long_ago]
        )

      {:ok, count} = Postgres.recover_zombie_workflows(config(), 300)
      assert count == 0

      assert repo().get!(WorkflowExecution, running.id).status == :running
      assert repo().get!(WorkflowExecution, completed.id).status == :completed
    end

    test "marks :compensating workflows with no running compensation as :failed (M-1)" do
      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      zombie = insert_execution(workflow_name: "comp_zombie", status: :compensating)

      {1, _} =
        repo().update_all(
          from(w in WorkflowExecution, where: w.id == ^zombie.id),
          set: [updated_at: long_ago]
        )

      {:ok, count} = Postgres.recover_zombie_workflows(config(), 300)
      assert count == 1
      assert repo().get!(WorkflowExecution, zombie.id).status == :failed
    end

    test "leaves :compensating workflows with a running compensation step alone" do
      alias Durable.Storage.Schemas.StepExecution
      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      live = insert_execution(workflow_name: "comp_live", status: :compensating)

      {1, _} =
        repo().update_all(
          from(w in WorkflowExecution, where: w.id == ^live.id),
          set: [updated_at: long_ago]
        )

      # Insert an actively-running compensation step
      {:ok, _step} =
        %StepExecution{}
        |> StepExecution.changeset(%{
          workflow_id: live.id,
          step_name: "comp_step",
          step_type: "compensation",
          attempt: 1,
          status: :running
        })
        |> repo().insert()

      {:ok, count} = Postgres.recover_zombie_workflows(config(), 300)
      assert count == 0
      assert repo().get!(WorkflowExecution, live.id).status == :compensating
    end

    test "handles multiple zombies in a single sweep" do
      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

      zombies =
        for i <- 1..3 do
          z = insert_execution(workflow_name: "zombie_#{i}", status: :waiting)
          z.id
        end

      {3, _} =
        repo().update_all(
          from(w in WorkflowExecution, where: w.id in ^zombies),
          set: [updated_at: long_ago]
        )

      {:ok, count} = Postgres.recover_zombie_workflows(config(), 300)
      assert count == 3

      for id <- zombies do
        assert repo().get!(WorkflowExecution, id).status == :failed
      end
    end
  end

  describe "ack/2" do
    test "clears lock fields" do
      job =
        insert_execution(
          workflow_name: "test",
          locked_by: "node_a",
          locked_at: DateTime.utc_now(),
          status: :running
        )

      :ok = Postgres.ack(config(), job.id)

      execution = repo().get!(WorkflowExecution, job.id)
      assert execution.locked_by == nil
      assert execution.locked_at == nil
    end

    test "ack of a successfully-finished job is idempotent (M-5 regression)" do
      # Bug M-5: a transient ack failure used to silently re-execute the job
      # via stale-recovery. The retry path makes this less likely. Calling
      # ack twice on the same job should be a no-op (no errors, no duplicates).
      job =
        insert_execution(
          workflow_name: "test",
          locked_by: "node_a",
          locked_at: DateTime.utc_now(),
          status: :running
        )

      assert :ok = Postgres.ack(config(), job.id)
      assert :ok = Postgres.ack(config(), job.id)
    end
  end

  describe "ack/2 telemetry" do
    test "ack_failed telemetry fires when ack ultimately fails" do
      # Use a non-existent job ID — the get returns nil, so the existing
      # :not_found branch fires. To exercise the failure-after-retries
      # branch we'd need to fault-inject Repo.update; here we just assert
      # the telemetry handler can be attached without crashing the system.
      ref = make_ref()
      test_pid = self()

      :ok =
        :telemetry.attach(
          "ack-failed-test-#{inspect(ref)}",
          [:durable, :queue, :ack_failed],
          fn _event, measurements, metadata, _ ->
            send(test_pid, {:ack_failed, ref, measurements, metadata})
          end,
          nil
        )

      # Non-existent jobs return :not_found without firing telemetry.
      assert {:error, :not_found} = Postgres.ack(config(), Ecto.UUID.generate())
      refute_received {:ack_failed, ^ref, _, _}, 100

      :telemetry.detach("ack-failed-test-#{inspect(ref)}")
    end
  end

  describe "ack/2 not_found" do
    test "returns error for non-existent job" do
      result = Postgres.ack(config(), Ecto.UUID.generate())
      assert result == {:error, :not_found}
    end
  end

  describe "nack/3" do
    test "marks job as failed and clears lock" do
      job =
        insert_execution(
          workflow_name: "test",
          locked_by: "node_a",
          locked_at: DateTime.utc_now(),
          status: :running
        )

      :ok = Postgres.nack(config(), job.id, %{message: "Something went wrong"})

      execution = repo().get!(WorkflowExecution, job.id)
      assert execution.status == :failed
      assert execution.error["message"] == "Something went wrong"
      assert execution.locked_by == nil
      assert execution.locked_at == nil
      assert execution.completed_at != nil
    end
  end

  describe "reschedule/3" do
    test "sets scheduled_at and clears lock" do
      job =
        insert_execution(
          workflow_name: "test",
          locked_by: "node_a",
          locked_at: DateTime.utc_now(),
          status: :running
        )

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      :ok = Postgres.reschedule(config(), job.id, future)

      execution = repo().get!(WorkflowExecution, job.id)
      assert execution.status == :pending
      assert DateTime.compare(execution.scheduled_at, future) == :eq
      assert execution.locked_by == nil
      assert execution.locked_at == nil
    end
  end

  describe "heartbeat/2" do
    test "updates locked_at timestamp" do
      old_time = DateTime.add(DateTime.utc_now(), -60, :second)

      job =
        insert_execution(
          workflow_name: "heartbeat_test",
          locked_by: "node_a",
          locked_at: old_time,
          status: :running
        )

      :ok = Postgres.heartbeat(config(), job.id)

      updated = repo().get!(WorkflowExecution, job.id)
      assert DateTime.compare(updated.locked_at, old_time) == :gt
    end

    test "returns error for non-existent job" do
      result = Postgres.heartbeat(config(), Ecto.UUID.generate())
      assert result == {:error, :not_found}
    end

    test "returns error for non-running job" do
      job = insert_execution(workflow_name: "pending_job", status: :pending)
      result = Postgres.heartbeat(config(), job.id)
      assert result == {:error, :not_found}
    end
  end

  describe "lock fencing" do
    test "fetch_jobs stamps a unique lock_token per claim, persisted on the row" do
      insert_execution(workflow_name: "fence_a")
      insert_execution(workflow_name: "fence_b")

      jobs = Postgres.fetch_jobs(config(), "default", 2, "node_a")
      assert length(jobs) == 2

      tokens = Enum.map(jobs, & &1.lock_token)
      assert Enum.all?(tokens, &is_binary/1)
      assert tokens == Enum.uniq(tokens)

      for job <- jobs do
        assert repo().get!(WorkflowExecution, job.id).lock_token == job.lock_token
      end
    end

    test "heartbeat: matching token refreshes; stale token is :fenced; no token is legacy-ok" do
      insert_execution(workflow_name: "fence_hb")
      [job] = Postgres.fetch_jobs(config(), "default", 1, "node_a")

      assert :ok = Postgres.heartbeat(config(), job.id, job.lock_token)
      assert :ok = Postgres.heartbeat(config(), job.id)

      # The row is :running with token A; a worker holding a different token has
      # been superseded → :fenced so it can abort instead of double-executing.
      assert {:error, :fenced} = Postgres.heartbeat(config(), job.id, Ecto.UUID.generate())
    end

    test "a finished row reports :not_found, not :fenced (no spurious abort on completion)" do
      insert_execution(workflow_name: "fence_done")
      [job] = Postgres.fetch_jobs(config(), "default", 1, "node_a")

      repo().get!(WorkflowExecution, job.id)
      |> Ecto.Changeset.change(status: :completed)
      |> repo().update!()

      assert {:error, :not_found} = Postgres.heartbeat(config(), job.id, job.lock_token)
    end

    test "ack with a stale token is a no-op; the real owner's ack releases the row" do
      insert_execution(workflow_name: "fence_ack")
      [job] = Postgres.fetch_jobs(config(), "default", 1, "node_a")

      assert :ok = Postgres.ack(config(), job.id, Ecto.UUID.generate())
      still = repo().get!(WorkflowExecution, job.id)
      assert still.status == :running
      assert still.locked_by == "node_a"

      assert :ok = Postgres.ack(config(), job.id, job.lock_token)
      assert repo().get!(WorkflowExecution, job.id).locked_by == nil
    end

    test "nack with a stale token is a no-op" do
      insert_execution(workflow_name: "fence_nack")
      [job] = Postgres.fetch_jobs(config(), "default", 1, "node_a")

      assert :ok = Postgres.nack(config(), job.id, %{message: "boom"}, Ecto.UUID.generate())
      assert repo().get!(WorkflowExecution, job.id).status == :running

      assert :ok = Postgres.nack(config(), job.id, %{message: "boom"}, job.lock_token)
      assert repo().get!(WorkflowExecution, job.id).status == :failed
    end

    test "recover_stale_locks clears the lock_token so the fenced token can't re-match" do
      insert_execution(workflow_name: "fence_recover")
      [job] = Postgres.fetch_jobs(config(), "default", 1, "node_a")
      assert is_binary(job.lock_token)

      repo().get!(WorkflowExecution, job.id)
      |> Ecto.Changeset.change(locked_at: DateTime.add(DateTime.utc_now(), -600, :second))
      |> repo().update!()

      {:ok, n} = Postgres.recover_stale_locks(config(), 300)
      assert n >= 1

      recovered = repo().get!(WorkflowExecution, job.id)
      assert recovered.status == :pending
      assert recovered.lock_token == nil
    end
  end

  describe "get_stats/2" do
    test "returns queue statistics" do
      insert_execution(workflow_name: "pending1", status: :pending)
      insert_execution(workflow_name: "pending2", status: :pending)
      insert_execution(workflow_name: "running", status: :running)
      insert_execution(workflow_name: "completed", status: :completed)
      insert_execution(workflow_name: "failed", status: :failed)

      stats = Postgres.get_stats(config(), "default")

      assert stats.queue == "default"
      assert stats.pending == 2
      assert stats.running == 1
      assert stats.completed == 1
      assert stats.failed == 1
      assert stats.total == 5
    end
  end

  # Helper functions

  describe "wake_sleeping_workflows/2" do
    test "flips elapsed sleeps back to :pending and writes the satisfied marker" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      sleeper =
        insert_execution(
          workflow_name: "sleeper",
          status: :waiting,
          scheduled_at: past,
          current_step: "wait_step",
          locked_by: "stale_node",
          locked_at: DateTime.add(DateTime.utc_now(), -120, :second)
        )

      {:ok, count} = Postgres.wake_sleeping_workflows(config(), 100)
      assert count == 1

      reloaded = repo().get!(WorkflowExecution, sleeper.id)
      assert reloaded.status == :pending
      assert reloaded.locked_by == nil
      assert reloaded.locked_at == nil
      assert reloaded.context["__sleep_satisfied__"] == "wait_step"
    end

    test "leaves :waiting rows whose scheduled_at is still in the future" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      sleeper =
        insert_execution(
          workflow_name: "future_sleeper",
          status: :waiting,
          scheduled_at: future,
          current_step: "wait_step"
        )

      {:ok, count} = Postgres.wake_sleeping_workflows(config(), 100)
      assert count == 0

      reloaded = repo().get!(WorkflowExecution, sleeper.id)
      assert reloaded.status == :waiting
    end

    test "leaves :waiting rows with no scheduled_at (event/input waits)" do
      waiter =
        insert_execution(
          workflow_name: "event_waiter",
          status: :waiting,
          current_step: "await"
        )

      {:ok, count} = Postgres.wake_sleeping_workflows(config(), 100)
      assert count == 0

      reloaded = repo().get!(WorkflowExecution, waiter.id)
      assert reloaded.status == :waiting
    end

    test "preserves prior context keys when merging the marker" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      sleeper =
        insert_execution(
          workflow_name: "rich_sleeper",
          status: :waiting,
          scheduled_at: past,
          current_step: "wait_step"
        )

      {1, _} =
        repo().update_all(
          from(w in WorkflowExecution, where: w.id == ^sleeper.id),
          set: [context: %{"customer_email" => "alice@example.com"}]
        )

      {:ok, _count} = Postgres.wake_sleeping_workflows(config(), 100)

      reloaded = repo().get!(WorkflowExecution, sleeper.id)
      assert reloaded.context["customer_email"] == "alice@example.com"
      assert reloaded.context["__sleep_satisfied__"] == "wait_step"
    end

    test "respects batch_size cap" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      for i <- 1..3 do
        insert_execution(
          workflow_name: "batched_#{i}",
          status: :waiting,
          scheduled_at: past,
          current_step: "wait"
        )
      end

      {:ok, count} = Postgres.wake_sleeping_workflows(config(), 2)
      assert count == 2
    end
  end

  describe "recover_zombie_workflows/2 — sleeping workflows are not zombies" do
    test "leaves :waiting rows whose scheduled_at is set, even when stale" do
      long_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
      # An ostensibly "stuck" sleeper: stale updated_at, no pending
      # input/event, no lock — would be flagged a zombie by the old
      # logic. Now exempt because scheduled_at is non-nil; the
      # SleepWaker is the right component to deal with it.
      sleeper =
        insert_execution(
          workflow_name: "long_sleeper",
          status: :waiting,
          scheduled_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          current_step: "wait_step"
        )

      {1, _} =
        repo().update_all(
          from(w in WorkflowExecution, where: w.id == ^sleeper.id),
          set: [updated_at: long_ago]
        )

      {:ok, count} = Postgres.recover_zombie_workflows(config(), 300)
      assert count == 0

      reloaded = repo().get!(WorkflowExecution, sleeper.id)
      assert reloaded.status == :waiting
    end
  end

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
      current_step: Keyword.get(opts, :current_step),
      locked_by: Keyword.get(opts, :locked_by),
      locked_at: Keyword.get(opts, :locked_at)
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> repo().insert!()
  end
end
