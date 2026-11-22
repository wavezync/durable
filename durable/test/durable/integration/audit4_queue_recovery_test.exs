defmodule Audit4QueueGate do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit4_queue_gate" do
    step(:work, fn data ->
      Probe.inside([:slots], fn ->
        Probe.note(:gate)
        Probe.wait_for(data["flag"])
      end)

      {:ok, data}
    end)
  end
end

defmodule Audit4QueueOnce do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit4_queue_once" do
    step(:work, fn data ->
      Probe.note(:once)
      {:ok, data}
    end)
  end
end

defmodule Audit4QueueTwoSteps do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit4_queue_two_steps" do
    step(:first, fn data ->
      Probe.note(:first)
      {:ok, Map.put(data, "first", "done")}
    end)

    step(:second, fn data ->
      Probe.note(:second)
      {:ok, data}
    end)
  end
end

defmodule Audit4QueueSlowUndo do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit4_queue_slow_undo", on_failure: :rollback do
    step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
    step(:charge, fn _data -> {:fail, "declined"} end)

    compensate(:unbook, fn data ->
      Probe.note(:undoing)
      Probe.wait_for(:never)
      {:ok, data}
    end)
  end
end

defmodule Audit4QueueCooperative do
  @moduledoc false
  use Durable
  use Durable.Context
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit4_queue_cooperative" do
    step(:first, fn data ->
      Probe.note(:first)
      Probe.put(:stopping_seen, shutting_down?())
      {:ok, data}
    end)

    step(:second, fn data ->
      Probe.here(:second)
      {:ok, data}
    end)
  end
end

defmodule Audit4QueueRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :durable, adapter: Ecto.Adapters.Postgres
end

defmodule Durable.Integration.Audit4QueueRecoveryTest do
  @moduledoc """
  Audit 4: the queue's own processes dying, and claims that change hands at
  the moments nothing else covers.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.Config
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Queue.Drainer
  alias Durable.Queue.Worker

  @poller Durable.Queue.Poller.Default
  @manager Durable.Queue.Manager

  defp start_idle!(opts \\ []) do
    Durable.DataCase.start_supervised_durable!(
      [repo: IntegrationRepo, queue_enabled: false] ++ opts
    )

    Config.get(Durable)
  end

  defp stale!(id) do
    {1, _} =
      IntegrationRepo.update_all(
        from(w in WorkflowExecution, where: w.id == ^id),
        set: [locked_at: DateTime.add(DateTime.utc_now(), -3_600, :second)]
      )
  end

  defp step_rows(id) do
    IntegrationRepo.all(from(s in StepExecution, where: s.workflow_id == ^id))
  end

  defp restarted!(name, old) do
    assert_eventually(fn -> Process.whereis(name) not in [nil, old] end, 5_000, 10)
    Process.whereis(name)
  end

  # Kills the process running a step at one of its telemetry events, once.
  def kill_once(_event, _measurements, %{step: step}, step) do
    if Probe.note(:killed) == 1, do: Process.exit(self(), :kill)
  end

  def kill_once(_event, _measurements, _meta, _step), do: :ok

  defp kill_at!(event, step) do
    handler = "audit4-queue-kill-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, event, &__MODULE__.kill_once/4, step)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "a task killed as its attempt begins" do
    # BUG: the attempt's row stays :pending for good, on a run that finished
    # (:running, if the kill lands while the write that marks it running is in
    # flight, which the kill fuzz hits). The row is inserted, then marked
    # running (step_runner.ex:358 and :377), and whoever cleans up after the
    # dead task only closes rows that are :running then (step_runner.ex:108).
    @tag :skip
    test "leaves no step row open" do
      kill_at!([:durable, :step, :start], :second)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit4QueueTwoSteps, %{})
      await_status(id, :completed)

      assert Probe.hits(:killed) == 2
      assert Probe.hits(:second) == 1

      assert Enum.sort(for row <- step_rows(id), do: {row.step_name, row.status}) ==
               [{"first", :completed}, {"second", :completed}]
    end

    test "runs the step once the run is claimed again, without using an attempt" do
      kill_at!([:durable, :step, :start], :second)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit4QueueTwoSteps, %{})
      run = await_status(id, :completed)

      assert {Probe.hits(:first), Probe.hits(:second)} == {1, 1}
      assert run.context["first"] == "done"

      assert [%{attempt: 1}] =
               for(
                 row <- step_rows(id),
                 row.status == :completed and row.step_name == "second",
                 do: row
               )
    end
  end

  describe "a task killed after its step's row was written, before the run saved the result" do
    # NEEDS A DECISION: the step runs a second time, though its row says
    # :completed and holds its output. A run that comes back goes by its own
    # saved context (Executor.close_and_requeue/3, executor.ex:3369) and never
    # looks at the row. At-least-once allows it, but the row could spare it.
    @tag :skip
    test "doesn't run the step again" do
      kill_at!([:durable, :step, :stop], :first)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit4QueueTwoSteps, %{})
      await_status(id, :completed)

      assert Probe.hits(:killed) == 2
      assert Probe.hits(:first) == 1
      assert [_one] = for(row <- step_rows(id), row.step_name == "first", do: row)
    end

    test "still finishes the run, with every step's result" do
      kill_at!([:durable, :step, :stop], :first)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit4QueueTwoSteps, %{})
      run = await_status(id, :completed)

      assert Probe.hits(:second) == 1
      assert run.context["first"] == "done"
      assert run.locked_by == nil
    end
  end

  describe "a claim taken over before its worker began" do
    # BUG: the worker that lost the claim runs the step anyway, next to the new
    # owner. Executor.execute_workflow/2 (executor.ex:782) loads the run by id
    # and adopts whatever lock_token is on the row, so the claim's own token
    # (job.lock_token, worker.ex:157) is never checked before the first step.
    @tag :skip
    test "isn't run by the worker that lost it" do
      config = start_idle!()
      {:ok, id} = Durable.start(Audit4QueueOnce, %{})

      [lost] = Postgres.fetch_jobs(config, "default", 1, "node-a")
      stale!(id)
      {:ok, 1} = Postgres.recover_stale_locks(config, 300)
      [taken] = Postgres.fetch_jobs(config, "default", 1, "node-b")
      assert taken.lock_token != lost.lock_token

      {:ok, worker} = Worker.start_link(job: lost, config: config, poller_pid: self())
      assert_receive {:job_complete, ^worker, ^id, result, _ms}, 5_000

      assert Probe.hits(:once) == 0
      assert result == :fenced
      assert %{status: :running, locked_by: "node-b"} = get(id)
    end

    test "is run by the worker that has it now" do
      config = start_idle!()
      {:ok, id} = Durable.start(Audit4QueueOnce, %{})

      [_lost] = Postgres.fetch_jobs(config, "default", 1, "node-a")
      stale!(id)
      {:ok, 1} = Postgres.recover_stale_locks(config, 300)
      [taken] = Postgres.fetch_jobs(config, "default", 1, "node-b")

      {:ok, worker} = Worker.start_link(job: taken, config: config, poller_pid: self())
      assert_receive {:job_complete, ^worker, ^id, :ok, _ms}, 5_000

      assert Probe.hits(:once) == 1
      assert get(id).status == :completed
    end
  end

  describe "a poller that is killed" do
    # BUG: the queue runs over its limit. The new poller starts with no workers
    # (poller.ex:119) while the old one's are still running under the worker
    # supervisor, so it claims `concurrency` more.
    @tag :skip
    test "still counts the runs its workers hold against the queue's limit" do
      start_durable!(%{default: 1})

      {:ok, _first} = Durable.start(Audit4QueueGate, %{"flag" => "first"})
      assert_eventually(fn -> Probe.hits(:gate) == 1 end)

      poller = Process.whereis(@poller)
      Process.exit(poller, :kill)
      restarted!(@poller, poller)

      {:ok, second} = Durable.start(Audit4QueueGate, %{"flag" => "second"})
      # Long enough for many polls: the second run has to stay where it is.
      Process.sleep(500)

      assert Probe.peak(:slots) == 1
      assert get(second).status == :pending
    end

    test "leaves the step it interrupted nothing to do twice" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit4QueueGate, %{"flag" => "go"})
      assert_eventually(fn -> Probe.hits(:gate) == 1 end)

      poller = Process.whereis(@poller)
      Process.exit(poller, :kill)
      restarted!(@poller, poller)
      Probe.set("go")

      run = await_status(id, :completed)
      assert Probe.hits(:gate) == 1
      assert run.locked_by == nil
      assert [%{status: :completed}] = step_rows(id)
    end

    test "is replaced by one that picks up new work" do
      start_durable!(%{default: 1})

      poller = Process.whereis(@poller)
      Process.exit(poller, :kill)
      restarted!(@poller, poller)

      {:ok, id} = Durable.start(Audit4QueueOnce, %{})
      await_status(id, :completed)
      assert Probe.hits(:once) == 1
    end
  end

  describe "a repo that isn't running" do
    # BUG: the poller dies, and its replacement polls at once and dies too, so
    # four crashes take a moment and the queue manager goes down with every
    # worker. Poller.poll_and_process/1 (poller.ex:251) lets a raise from
    # fetch_jobs through ("could not lookup Ecto repo"), where the scheduler
    # and the sweeps rescue it.
    @tag :skip
    test "doesn't take the queue manager down" do
      Application.put_env(
        :durable,
        Audit4QueueRepo,
        Application.fetch_env!(:durable, IntegrationRepo)
      )

      start_supervised!(Audit4QueueRepo)

      Durable.DataCase.start_supervised_durable!(
        repo: Audit4QueueRepo,
        queues: queue_opts(%{default: 1})
      )

      manager = Process.monitor(Process.whereis(@manager))
      stop_supervised!(Audit4QueueRepo)

      refute_receive {:DOWN, ^manager, :process, _pid, _reason}, 500
    end
  end

  describe "the queue manager restarting" do
    # BUG: no run on this node ever runs a step again. Stopping, the old
    # manager's Drainer sets its `stopping?` flag (drainer.ex:55), and only
    # Durable.Supervisor.init/1 clears it (supervisor.ex:106), which a restart
    # of the manager alone doesn't reach. Every claim is then handed straight
    # back by Executor.queue_move/3 (executor.ex:3450), on every poll.
    @tag :skip
    test "doesn't leave the node believing it is stopping" do
      start_durable!(%{default: 1}, shutdown_grace_period: 200)
      refute Drainer.stopping?(Durable)

      manager = Process.whereis(@manager)
      top = Process.whereis(Durable.Supervisor)

      # More crashes than the manager allows its children.
      for _ <- 1..4 do
        poller = Process.whereis(@poller)
        Process.exit(poller, :kill)
        assert_eventually(fn -> Process.whereis(@poller) != poller end, 5_000, 1)
      end

      restarted!(@manager, manager)
      restarted!(@poller, nil)
      assert Process.whereis(Durable.Supervisor) == top

      {:ok, id} = Durable.start(Audit4QueueCooperative, %{})
      await_status(id, :completed, 3_000)

      assert Probe.fetch(:stopping_seen) == false
      refute Drainer.stopping?(Durable)
    end
  end

  describe "a node stopping while a compensation outlasts the grace period" do
    # NEEDS A DECISION: the run is left :compensating and locked by the node
    # that is gone, until the stale sweep fails it stale_lock_timeout later.
    # Drainer.hand_back_running/1 (drainer.ex:91) releases through
    # release_node_jobs/2, which only takes :running runs (postgres.ex:303).
    @tag :skip
    test "doesn't leave the run locked by the node that is gone" do
      start_durable!(%{default: 1}, shutdown_grace_period: 200)
      {:ok, id} = Durable.start(Audit4QueueSlowUndo, %{})
      assert_eventually(fn -> Probe.hits(:undoing) == 1 end)

      stop_supervised!(Durable)

      assert get(id).locked_by == nil
    end
  end
end
