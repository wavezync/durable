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

defmodule Audit4QueueSeesData do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit4_queue_sees_data" do
    step(:first, fn data ->
      Probe.note(:first)
      {:ok, Map.put(data, :total, data["order"] * 3)}
    end)

    step(:second, fn data ->
      Probe.put(:second_got, data)
      {:ok, data}
    end)
  end
end

defmodule Audit4QueuePutsContext do
  @moduledoc false
  use Durable
  use Durable.Context
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit4_queue_puts_context" do
    step(:first, fn data ->
      Probe.note(:first)
      put_context(:receipt, "r-1")
      {:ok, data}
    end)

    step(:second, fn data ->
      Probe.put(:second_got, {data, get_context(:receipt)})
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

defmodule Audit4QueueTwoUndos do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The refund goes through, and the node stops while the booking is released.
  workflow "audit4_queue_two_undos", on_failure: :rollback do
    step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
    step(:pay, [compensate: :refund], fn data -> {:ok, data} end)

    step(:ship, fn _data ->
      Probe.note(:ship)
      {:fail, "declined"}
    end)

    compensate(:refund, fn data ->
      Probe.note(:refund)
      {:ok, data}
    end)

    compensate(:unbook, fn data ->
      Probe.note(:unbook)
      Probe.wait_for("unbooked")
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
    # The attempt's row is written once, running, after its start event, so a
    # task killed before that leaves none.
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

    def forward_stop(_event, _measurements, meta, pid),
      do: send(pid, {:attempt_ended, meta.step_execution_id, meta.result})

    # The write of its row can land after whoever cleaned up had looked. That
    # can't be raced on purpose, so the row is put there as the write would.
    test "whose row lands after the clean-up has it closed, once, by the next attempt" do
      config = start_idle!()
      handler = "audit4-queue-stop-#{System.unique_integer([:positive])}"
      :telemetry.attach(handler, [:durable, :step, :stop], &__MODULE__.forward_stop/4, self())
      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, id} = Durable.start(Audit4QueueTwoSteps, %{})

      late =
        IntegrationRepo.insert!(%StepExecution{
          workflow_id: id,
          step_name: "first",
          step_type: "step",
          attempt: 1,
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %{status: :completed}} = Durable.Executor.execute_workflow(id, config)

      late_id = late.id
      assert_received {:attempt_ended, ^late_id, :error}
      refute_received {:attempt_ended, ^late_id, _result}

      assert %{status: :failed, error: %{"type" => "worker_lost"}} =
               IntegrationRepo.get!(StepExecution, late_id)

      assert Enum.sort(for row <- step_rows(id), do: {row.step_name, row.status, row.attempt}) ==
               [{"first", :completed, 1}, {"first", :failed, 1}, {"second", :completed, 1}]

      assert {Probe.hits(:first), Probe.hits(:second)} == {1, 1}
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
    # The run that comes back takes the result from the row. The attempt ended
    # once, in the process that was killed, so its end isn't sent again.
    test "doesn't run the step again" do
      kill_at!([:durable, :step, :stop], :first)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit4QueueTwoSteps, %{})
      await_status(id, :completed)

      assert Probe.hits(:killed) == 1
      assert Probe.hits(:first) == 1
      assert [_one] = for(row <- step_rows(id), row.step_name == "first", do: row)
    end

    # The task's worker, and so its heartbeat: what a node that dies leaves.
    def kill_worker_once(_event, _measurements, %{step: :first}, _config) do
      if Probe.note(:killed) == 1, do: Process.exit(hd(Process.get(:"$ancestors")), :kill)
    end

    def kill_worker_once(_event, _measurements, _meta, _config), do: :ok

    test "doesn't run the step again when the stale sweep is what brings the run back" do
      handler = "audit4-queue-kill-worker-#{System.unique_integer([:positive])}"
      :telemetry.attach(handler, [:durable, :step, :stop], &__MODULE__.kill_worker_once/4, nil)
      on_exit(fn -> :telemetry.detach(handler) end)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit4QueueTwoSteps, %{"order" => 7})
      assert_eventually(fn -> Probe.hits(:killed) == 1 end)
      assert_eventually(fn -> :sys.get_state(@poller).workers == %{} end)
      assert %{status: :running, current_step: "first"} = get(id)

      stale!(id)
      {:ok, 1} = Postgres.recover_stale_locks(Config.get(Durable), 300)
      run = await_status(id, :completed)

      assert {Probe.hits(:first), Probe.hits(:second)} == {1, 1}
      assert [_one] = for(row <- step_rows(id), row.step_name == "first", do: row)
      assert %{"order" => 7, "first" => "done"} = run.context
    end

    test "gives the next step what the step returned, with the input's keys as they were" do
      kill_at!([:durable, :step, :stop], :first)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit4QueueSeesData, %{"order" => 7})
      await_status(id, :completed)

      assert Probe.hits(:first) == 1
      assert %{"order" => 7, total: 21} = Probe.fetch(:second_got)
    end

    test "gives the next step what the step put in the context without returning it" do
      kill_at!([:durable, :step, :stop], :first)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit4QueuePutsContext, %{"order" => 7})
      run = await_status(id, :completed)

      assert Probe.hits(:first) == 1
      assert {%{"order" => 7}, "r-1"} = Probe.fetch(:second_got)
      assert run.context["receipt"] == "r-1"
    end

    test "runs the step again for a run retried since: the row is from before the retry" do
      kill_at!([:durable, :step, :stop], :first)
      config = start_idle!()
      {:ok, id} = Durable.start(Audit4QueueTwoSteps, %{})

      [job] = Postgres.fetch_jobs(config, "default", 1, "node-a")
      {:ok, worker} = Worker.start_link(job: job, config: config, poller_pid: self())
      assert_receive {:job_complete, ^worker, ^id, :waiting, _ms}, 5_000
      assert %{status: :pending, current_step: "first"} = get(id)

      # Failed where it stood, as three such losses in a row would leave it.
      {1, _} =
        IntegrationRepo.update_all(
          from(w in WorkflowExecution, where: w.id == ^id),
          set: [status: :failed]
        )

      {:ok, ^id} = Durable.retry(id)
      assert {:ok, %{status: :completed}} = Durable.Executor.execute_workflow(id, config)
      assert Probe.hits(:first) == 2
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
    # The worker gives the executor its claim's token, and the row has another.
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

    test "isn't run by the worker that lost it when nobody has claimed it since" do
      config = start_idle!()
      {:ok, id} = Durable.start(Audit4QueueOnce, %{})

      [lost] = Postgres.fetch_jobs(config, "default", 1, "node-a")
      stale!(id)
      {:ok, 1} = Postgres.recover_stale_locks(config, 300)

      {:ok, worker} = Worker.start_link(job: lost, config: config, poller_pid: self())
      assert_receive {:job_complete, ^worker, ^id, :fenced, _ms}, 5_000

      assert Probe.hits(:once) == 0
      assert %{status: :pending, locked_by: nil, current_step: nil} = get(id)
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
    # The old poller's workers live on under the worker supervisor, and the
    # new poller takes them over.
    test "still counts the runs its workers hold against the queue's limit" do
      start_durable!(%{default: 1})

      {:ok, first} = Durable.start(Audit4QueueGate, %{"flag" => "first"})
      assert_eventually(fn -> Probe.hits(:gate) == 1 end)

      poller = Process.whereis(@poller)
      Process.exit(poller, :kill)
      restarted!(@poller, poller)

      {:ok, second} = Durable.start(Audit4QueueGate, %{"flag" => "second"})
      # Long enough for many polls: the second run has to stay where it is.
      Process.sleep(500)

      assert Probe.peak(:slots) == 1
      assert get(second).status == :pending

      # The slot comes free when the worker it took over is done.
      Probe.set("first")
      await_status(first, :completed)
      assert_eventually(fn -> Probe.hits(:gate) == 2 end)
      Probe.set("second")
      await_status(second, :completed)

      assert Probe.peak(:slots) == 1
      assert_eventually(fn -> :sys.get_state(@poller).workers == %{} end)
    end

    test "is told how the workers it took over ended, and fails a run for one" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Audit4QueueSlowUndo, %{})
      assert_eventually(fn -> Probe.hits(:undoing) == 1 end)

      poller = Process.whereis(@poller)
      Process.exit(poller, :kill)
      restarted!(@poller, poller)

      # A compensation that dies is the poller's to fail the run for.
      [{_id, worker, _type, _modules}] =
        DynamicSupervisor.which_children(Durable.Queue.WorkerSupervisor.Default)

      Process.exit(:sys.get_state(worker).task_pid, :kill)

      assert %{locked_by: nil, error: %{"type" => "task_crash"}} = await_status(id, :failed)
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
    # Durable on a repo of its own, which the test can stop.
    defp start_on_own_repo!(opts \\ []) do
      Application.put_env(
        :durable,
        Audit4QueueRepo,
        Application.fetch_env!(:durable, IntegrationRepo)
      )

      start_supervised!(Audit4QueueRepo)

      Durable.DataCase.start_supervised_durable!(
        [repo: Audit4QueueRepo, queues: queue_opts(%{default: 1})] ++ opts
      )
    end

    # A poll raises ("could not lookup Ecto repo"): the poller logs it and
    # polls again, as the scheduler and the sweeps do.
    test "doesn't take the queue manager down" do
      start_on_own_repo!()

      manager = Process.monitor(Process.whereis(@manager))
      stop_supervised!(Audit4QueueRepo)

      refute_receive {:DOWN, ^manager, :process, _pid, _reason}, 500
    end

    test "leaves the same poller to pick up work once the repo is back" do
      start_on_own_repo!()
      poller = Process.whereis(@poller)

      {:ok, id} = Durable.start(Audit4QueueOnce, %{}, queue: :elsewhere)
      stop_supervised!(Audit4QueueRepo)
      # Long enough for several polls to raise.
      Process.sleep(200)
      start_supervised!(Audit4QueueRepo)

      {1, _} =
        IntegrationRepo.update_all(
          from(w in WorkflowExecution, where: w.id == ^id),
          set: [queue: "default"]
        )

      await_status(id, :completed)
      assert Process.whereis(@poller) == poller
    end

    test "when the node stops past its grace period doesn't crash the drainer" do
      start_on_own_repo!(shutdown_grace_period: 100)

      {:ok, _id} = Durable.start(Audit4QueueGate, %{"flag" => "never"})
      assert_eventually(fn -> Probe.hits(:gate) == 1 end)
      stop_supervised!(Audit4QueueRepo)

      log = ExUnit.CaptureLog.capture_log(fn -> stop_supervised!(Durable) end)
      assert log =~ "couldn't hand back this node's runs"
      refute log =~ "MatchError"
    end
  end

  describe "the queue manager restarting" do
    # The old manager's Drainer sets `stopping?` as it stops; the new manager
    # clears it.
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

  describe "a poller restarted after Durable.drain/1" do
    test "doesn't claim: the node is still stopping" do
      start_durable!(%{default: 1})
      :ok = Durable.drain()

      poller = Process.whereis(@poller)
      Process.exit(poller, :kill)
      restarted!(@poller, poller)

      {:ok, id} = Durable.start(Audit4QueueOnce, %{})
      # Long enough for many polls.
      Process.sleep(300)

      assert :sys.get_state(@poller).paused
      assert %{status: :pending, locked_by: nil, current_step: nil} = get(id)
      assert Probe.hits(:once) == 0
    end
  end

  describe "a node stopping while a compensation outlasts the grace period" do
    # The run goes back on its queue to be rolled back by whoever claims it.
    test "doesn't leave the run locked by the node that is gone" do
      start_durable!(%{default: 1}, shutdown_grace_period: 200)
      {:ok, id} = Durable.start(Audit4QueueSlowUndo, %{})
      assert_eventually(fn -> Probe.hits(:undoing) == 1 end)

      stop_supervised!(Durable)

      assert get(id).locked_by == nil
    end

    test "has the next node finish the rollback: what was undone stays undone, and no step runs" do
      start_durable!(%{default: 1}, shutdown_grace_period: 200)
      {:ok, id} = Durable.start(Audit4QueueTwoUndos, %{})
      assert_eventually(fn -> Probe.hits(:unbook) == 1 end)
      assert Probe.hits(:refund) == 1

      stop_supervised!(Durable)
      assert %{status: :pending, locked_by: nil, lock_token: nil} = get(id)
      assert [] = for(row <- step_rows(id), row.status == :running, do: row)

      start_durable!(%{default: 1})
      assert_eventually(fn -> Probe.hits(:unbook) == 2 end)
      Probe.set("unbooked")
      run = await_status(id, :compensated)

      assert {Probe.hits(:refund), Probe.hits(:ship)} == {1, 1}
      assert %{"message" => "declined"} = run.error
      assert run.locked_by == nil
      refute is_map_key(run.engine_state, "__rollback__")
    end
  end
end
