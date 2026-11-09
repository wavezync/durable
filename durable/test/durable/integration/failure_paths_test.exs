defmodule Durable.Integration.FailurePathsTest do
  @moduledoc """
  What happens when something goes wrong underneath a run: its step's process
  dies, the pool is busy, the node stops heartbeating, or two callers race.
  Each `#n` in a describe is that item of GitHub issue #32, and each `audit n`
  that item of the re-audit posted on it.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.Queue.Adapters.Postgres
  alias Durable.Queue.StaleJobRecovery
  alias Durable.Scheduler
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.ScheduledWorkflow
  alias Durable.Wait.SleepWaker

  defmodule BusyRepo do
    use Ecto.Repo, otp_app: :durable, adapter: Ecto.Adapters.Postgres
  end

  defmodule LinkedCrash do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_linked_crash" do
      step(:work, [retry: [max_attempts: 1]], fn data ->
        Probe.note(:body)
        Task.async(fn -> raise "boom" end) |> Task.await()
        {:ok, data}
      end)
    end
  end

  defmodule LinkedCrashRetried do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_linked_crash_retried" do
      step(:work, [retry: [max_attempts: 3, backoff: :constant, base: 1]], fn data ->
        if Probe.note(:body) < 3, do: Process.exit(self(), :kill)
        {:ok, data}
      end)
    end
  end

  defmodule DiesThenWaits do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_dies_then_waits" do
      step(
        :work,
        [retry: [max_attempts: 2, backoff: :constant, base: 400, jitter: false]],
        fn data ->
          if Probe.note(:body) == 1, do: Process.exit(self(), :kill)
          {:ok, data}
        end
      )
    end
  end

  defmodule CrashCompensated do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_crash_compensated" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)

      step(:work, fn data ->
        Task.async(fn -> raise "boom" end) |> Task.await()
        {:ok, data}
      end)

      compensate(:unbook, fn data ->
        Probe.note(:undone)
        {:ok, data}
      end)
    end
  end

  defmodule Held do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_held" do
      step(:work, fn data ->
        Probe.note(:body)
        Probe.wait_for(:release)
        Probe.note(:finished)
        {:ok, data}
      end)
    end
  end

  defmodule SlowCancellable do
    use Durable
    use Durable.Context
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_slow_cancellable" do
      step(:work, fn data ->
        Probe.note(:body)
        Process.sleep(1_500)
        Probe.note(:finished)
        {:ok, data}
      end)

      step(:after, fn data ->
        Probe.note(:after)
        {:ok, data}
      end)
    end
  end

  defmodule PollsCancelled do
    use Durable
    use Durable.Context
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_polls_cancelled" do
      step(:work, fn data ->
        Probe.note(:body)
        Probe.wait_for(:cancelled)
        Probe.note({:saw_cancelled, cancelled?()})
        {:ok, data}
      end)
    end
  end

  defmodule RetriedThenDone do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_retried_then_done" do
      step(
        :work,
        [retry: [max_attempts: 2, backoff: :constant, base: 300, jitter: false]],
        fn data ->
          if Probe.note(:attempt) == 1, do: {:error, "again"}, else: {:ok, data}
        end
      )
    end
  end

  defmodule Quick do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_quick" do
      step(:work, fn data ->
        Process.sleep(30)
        Probe.note(:fresh)
        {:ok, data}
      end)
    end
  end

  defmodule KilledCompensation do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_killed_compensation" do
      step(:a, [compensate: :undo_a], fn data -> {:ok, data} end)
      step(:b, fn _data -> {:fail, "stop here"} end)

      compensate(:undo_a, fn data ->
        Probe.note(:undo)
        Probe.wait_for(:release_undo)
        {:ok, data}
      end)
    end
  end

  defmodule ChildKilledInCompensation do
    use Durable
    use Durable.Orchestration
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_parent_of_killed" do
      step(:call, fn data ->
        Probe.note(:parent)
        {:error, _} = call_workflow(KilledCompensation, %{})
        {:ok, data}
      end)
    end
  end

  defmodule Keyed do
    use Durable

    workflow "fp_keyed" do
      step(:work, fn data -> {:ok, data} end)
    end
  end

  # Looking it up fails the way a refused connection does.
  defmodule RefusedOnStart do
    def __workflow_definition__(_name) do
      raise DBConnection.ConnectionError, "connection not available"
    end
  end

  defmodule DiesOnSignal do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_dies_on_signal" do
      step(:work, fn _data ->
        Probe.note(:body)
        Probe.wait_for(:die)
        Process.exit(self(), :kill)
      end)
    end
  end

  # Only the first attempt waits; the one that replaces it finishes at once.
  defmodule StaleOnce do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_stale_once" do
      step(:work, fn data ->
        if Probe.note(:body) == 1, do: Probe.wait_for(:release)
        {:ok, data}
      end)
    end
  end

  # The first attempt waits, then ends however the test says.
  defmodule EndsLate do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_ends_late" do
      step(:work, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
        if Probe.note(:body) > 1 do
          {:ok, data}
        else
          Probe.wait_for(:release)

          case Probe.fetch(:ending) do
            :ok -> {:ok, data}
            :error -> {:error, "too late"}
            :sleep -> sleep(20)
          end
        end
      end)
    end
  end

  defmodule Tick do
    use Durable

    workflow "fp_tick" do
      step(:work, fn data -> {:ok, data} end)
    end
  end

  defmodule Declares do
    use Durable
    use Durable.Scheduler.DSL

    @schedule cron: "0 9 * * *", name: "declared"
    workflow "fp_declares" do
      step(:work, fn data -> {:ok, data} end)
    end
  end

  defmodule ReadsAfterSleep do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_reads_after_sleep" do
      step(:first, fn d ->
        id = d["id"]
        Probe.note({:first, id})
        sleep(20)
        {:ok, Map.put(d, "seen", id)}
      end)

      step(:second, fn d ->
        Probe.note({:second, d["id"]})
        {:ok, d}
      end)
    end
  end

  defmodule ReadsAfterEvent do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_reads_after_event" do
      step(:first, fn d ->
        Probe.note({:first, d["id"]})
        wait_for_event("go")
        {:ok, d}
      end)

      step(:second, fn d ->
        Probe.note({:second, d["id"]})
        {:ok, d}
      end)
    end
  end

  defmodule ReadsAfterInput do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_reads_after_input" do
      step(:first, fn d ->
        Probe.note({:first, d["id"]})
        wait_for_input("ok")
        {:ok, d}
      end)

      step(:second, fn d ->
        Probe.note({:second, d["id"]})
        {:ok, d}
      end)
    end
  end

  defmodule ReadsInParallel do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_reads_in_parallel" do
      parallel do
        step(:branch, fn d ->
          Probe.note({:branch, d["id"]})
          {:ok, d}
        end)
      end

      step(:second, fn d ->
        Probe.note({:second, d["id"]})
        {:ok, d}
      end)
    end
  end

  defmodule KeepsAtomKeys do
    use Durable
    use Durable.Helpers
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_keeps_atom_keys" do
      step(:first, fn d -> {:ok, assign(d, :total, 7)} end)

      step(:second, fn d ->
        Probe.note({:second, d.total})
        sleep(20)
        {:ok, d}
      end)

      step(:third, fn d ->
        Probe.note({:third, d.total, d["id"]})
        {:ok, d}
      end)
    end
  end

  defmodule ReadsAfterCrash do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_reads_after_crash" do
      step(:first, fn d -> {:ok, Map.put(d, "x", 1)} end)

      step(:second, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn d ->
        attempt = Probe.note({:second, d["x"]})
        if attempt == 1, do: Process.exit(self(), :kill)
        {:ok, d}
      end)
    end
  end

  defp step_rows(id) do
    IntegrationRepo.all(
      from(s in StepExecution, where: s.workflow_id == ^id, order_by: s.inserted_at)
    )
  end

  defp labels, do: Enum.map(Probe.log(), &elem(&1, 0))

  defp insert_schedule!(name, source) do
    %ScheduledWorkflow{}
    |> ScheduledWorkflow.changeset(%{
      name: name,
      workflow_module: inspect(Declares),
      workflow_name: "fp_declares",
      cron_expression: "0 9 * * *",
      source: source
    })
    |> IntegrationRepo.insert!()
  end

  # A long heartbeat is how a test gets here. A long outage or a frozen VM
  # leaves the same state: the worker is fine, its lock isn't.
  defp lose_lock! do
    Process.sleep(1_100)
    {:ok, 1} = StaleJobRecovery.recover_now(Durable)
  end

  defp due_schedule!(name, overrides \\ []) do
    {:ok, schedule} = API.schedule(Tick, "* * * * *", name: name)
    make_due!(schedule, overrides)
    schedule
  end

  defp make_due!(schedule, overrides \\ []) do
    {1, _} =
      IntegrationRepo.update_all(from(s in ScheduledWorkflow, where: s.id == ^schedule.id),
        set: [next_run_at: DateTime.add(DateTime.utc_now(), -5, :second)] ++ overrides
      )
  end

  # The cast is handled before the call that follows it.
  defp run_check! do
    Scheduler.check_schedules(Durable)
    Scheduler.status(Durable)
  end

  defp schedule_row(name), do: IntegrationRepo.get_by!(ScheduledWorkflow, name: name)

  defp idle_durable!(opts \\ []) do
    Durable.DataCase.start_supervised_durable!(
      [repo: IntegrationRepo, queue_enabled: false] ++ opts
    )
  end

  defp worker_pid!(id) do
    with_worker = fn -> Durable.DataCase.get_worker_pid(Durable, "default", id) end
    assert_eventually(fn -> is_pid(with_worker.()) end)
    with_worker.()
  end

  # A pool small and strict enough to start refusing requests within a second,
  # as a 10-connection pool does after about 5 s of slow queries.
  defp start_on_busy_pool!(opts) do
    config =
      :durable
      |> Application.fetch_env!(IntegrationRepo)
      |> Keyword.merge(pool_size: 2, queue_target: 10, queue_interval: 100)

    Application.put_env(:durable, BusyRepo, config)
    start_supervised!(BusyRepo)

    Durable.DataCase.start_supervised_durable!(
      [repo: BusyRepo, queues: queue_opts(%{default: 1})] ++ opts
    )
  end

  # Holds every connection until the pool refuses requests, and runs `fun` then.
  defp with_busy_pool(fun) do
    holders =
      for _ <- 1..2 do
        Task.async(fn -> BusyRepo.query!("SELECT pg_sleep(2)", [], timeout: 10_000) end)
      end

    assert_eventually(
      fn -> match?({:error, %DBConnection.ConnectionError{}}, BusyRepo.query("SELECT 1")) end,
      1_900,
      1
    )

    result = fun.()
    Task.await_many(holders, 10_000)
    result
  end

  describe "#1 a step that dies" do
    test "through a link fails its attempt and runs once" do
      start_durable!(%{default: 1}, stale_lock_timeout: 1)

      {:ok, id} = Durable.start(LinkedCrash, %{})
      assert_eventually(fn -> Probe.hits(:body) >= 1 end)

      for _ <- 1..3 do
        Process.sleep(1_100)
        StaleJobRecovery.recover_now(Durable)
      end

      run = await_status(id, :failed, 2_000)

      assert Probe.hits(:body) == 1
      assert run.error["message"] =~ "boom"
      assert run.locked_by == nil
      assert [%{status: :failed, error: %{"message" => message}}] = step_rows(id)
      assert message =~ "boom"
    end

    test "uses its retries, then the run goes on" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(LinkedCrashRetried, %{})

      await_status(id, :completed)
      assert Probe.hits(:body) == 3
      assert Enum.map(step_rows(id), & &1.status) == [:failed, :failed, :completed]
      assert Enum.map(step_rows(id), & &1.attempt) == [1, 2, 3]
    end

    test "waits out the step's backoff before its next attempt" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(DiesThenWaits, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)

      assert_eventually(fn -> get(id).status == :pending end)
      assert DateTime.after?(get(id).scheduled_at, DateTime.utc_now())
      assert Probe.hits(:body) == 1

      await_status(id, :completed)
      assert Probe.hits(:body) == 2
    end

    test "out of attempts fails the run the normal way, running compensations" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(CrashCompensated, %{})

      run = await_status(id, :compensated)
      assert Probe.hits(:undone) == 1
      assert run.error["message"] =~ "boom"
    end

    test "with no running step row fails the run instead of looping" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Held, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)

      # As if it had died outside a step, in a branch condition or `into:`.
      {1, _} =
        IntegrationRepo.update_all(from(s in StepExecution, where: s.workflow_id == ^id),
          set: [status: :completed]
        )

      Process.exit(:sys.get_state(worker_pid!(id)).task_pid, :kill)

      run = await_status(id, :failed)
      assert run.error["type"] == "task_crash"
      assert Probe.hits(:body) == 1
    end

    test "a fenced worker records it" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Held, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)

      # What a takeover by another node looks like from here.
      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [lock_token: Ecto.UUID.generate()]
        )

      assert_eventually(fn ->
        Enum.any?(Durable.Activity.list(kinds: ["worker_fenced"]), &(&1.workflow_id == id))
      end)

      assert Durable.DataCase.get_worker_pid(Durable, "default", id) == nil
    end
  end

  describe "#2 a busy pool" do
    test "doesn't kill the running step" do
      start_on_busy_pool!(heartbeat_interval: 20)

      {:ok, id} = Durable.start(Held, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)
      worker = worker_pid!(id)

      with_busy_pool(fn ->
        Process.sleep(300)
        assert Process.alive?(worker)
      end)

      :ok = Probe.set(:release)
      await_status(id, :completed)
      assert Probe.hits(:body) == 1
    end

    test "doesn't crash the scheduler" do
      start_on_busy_pool!([])
      scheduler = Process.whereis(Scheduler.scheduler_name(Durable))

      with_busy_pool(fn ->
        Scheduler.check_schedules(Durable)
        Process.sleep(300)
      end)

      assert Process.whereis(Scheduler.scheduler_name(Durable)) == scheduler
      assert Process.alive?(scheduler)
    end
  end

  describe "#3 claim order" do
    test "a retry that's come due goes ahead of runs started after that" do
      start_durable!(%{default: 1})

      {:ok, retried} = Durable.start(RetriedThenDone, %{})
      assert_eventually(fn -> Probe.hits(:attempt) == 1 and get(retried).status == :pending end)

      # Holds the only slot while the retry comes due and a backlog builds.
      {:ok, _} = Durable.start(Held, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)

      assert_eventually(fn -> DateTime.before?(get(retried).scheduled_at, DateTime.utc_now()) end)
      for _ <- 1..20, do: {:ok, _} = Durable.start(Quick, %{})

      :ok = Probe.set(:release)
      await_status(retried, :completed, 10_000)

      assert Enum.take(labels(), 4) == [:attempt, :body, :finished, :attempt]
    end
  end

  describe "#4 a killed compensation" do
    test "with its worker still alive fails the run straight away" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(KilledCompensation, %{})
      assert_eventually(fn -> Probe.hits(:undo) == 1 end)

      Process.exit(:sys.get_state(worker_pid!(id)).task_pid, :kill)

      run = await_status(id, :failed)
      assert run.error["type"] == "task_crash"
      assert run.locked_by == nil
      refute Enum.any?(step_rows(id), &(&1.status == :running))
    end

    test "with its node is failed by the sweep, and its row closed" do
      start_durable!(%{default: 1}, stale_lock_timeout: 1)

      {:ok, id} = Durable.start(KilledCompensation, %{})
      assert_eventually(fn -> Probe.hits(:undo) == 1 end)

      Process.exit(worker_pid!(id), :kill)
      Process.sleep(1_100)
      StaleJobRecovery.recover_now(Durable)

      assert get(id).status == :failed
      refute Enum.any?(step_rows(id), &(&1.status == :running))
    end

    test "fails its parent too, instead of leaving it waiting" do
      start_durable!(%{default: 2}, stale_lock_timeout: 1)

      {:ok, parent} = Durable.start(ChildKilledInCompensation, %{})
      assert_eventually(fn -> Probe.hits(:undo) == 1 end)

      child =
        IntegrationRepo.one!(from(w in WorkflowExecution, where: w.parent_workflow_id == ^parent))

      Process.exit(worker_pid!(child.id), :kill)
      Process.sleep(1_100)
      StaleJobRecovery.recover_now(Durable)

      await_status(parent, :completed)
      assert Probe.hits(:parent) == 2
    end

    test "with its worker alive tells a parent too" do
      start_durable!(%{default: 2})

      {:ok, parent} = Durable.start(ChildKilledInCompensation, %{})
      assert_eventually(fn -> Probe.hits(:undo) == 1 end)

      child =
        IntegrationRepo.one!(from(w in WorkflowExecution, where: w.parent_workflow_id == ^parent))

      Process.exit(:sys.get_state(worker_pid!(child.id)).task_pid, :kill)

      await_status(parent, :completed)
      assert get(child.id).status == :failed
    end

    test "while alive keeps its lock fresh, so the sweep leaves it alone" do
      start_durable!(%{default: 1}, stale_lock_timeout: 1, heartbeat_interval: 100)

      {:ok, id} = Durable.start(KilledCompensation, %{})
      assert_eventually(fn -> Probe.hits(:undo) == 1 end)

      Process.sleep(1_300)
      StaleJobRecovery.recover_now(Durable)

      run = get(id)
      assert run.status == :compensating
      assert DateTime.diff(DateTime.utc_now(), run.locked_at, :millisecond) < 900

      :ok = Probe.set(:release_undo)
      await_status(id, :compensated)
    end
  end

  describe "#5 schedules on two nodes" do
    test "fire once" do
      for name <- [:node_a, :node_b] do
        start_supervised!(
          Supervisor.child_spec(
            {Durable,
             name: name,
             repo: IntegrationRepo,
             queues: %{},
             scheduler_interval: :timer.hours(1),
             shutdown_grace_period: 0},
            id: name
          )
        )
      end

      for n <- 1..20 do
        {:ok, schedule} = API.schedule(Tick, "* * * * *", name: "s#{n}", durable: :node_a)

        {1, _} =
          IntegrationRepo.update_all(from(s in ScheduledWorkflow, where: s.id == ^schedule.id),
            set: [next_run_at: DateTime.add(DateTime.utc_now(), -5, :second)]
          )
      end

      # Far enough apart that the first SELECT has finished, so SKIP LOCKED
      # can't hide the second node's overlap; close enough that the first node
      # hasn't advanced the schedules yet.
      Scheduler.check_schedules(:node_a)
      Process.sleep(8)
      Scheduler.check_schedules(:node_b)

      assert_eventually(fn ->
        IntegrationRepo.aggregate(WorkflowExecution, :count) >= 20 and
          IntegrationRepo.aggregate(
            from(s in ScheduledWorkflow, where: s.next_run_at <= ^DateTime.utc_now()),
            :count
          ) == 0
      end)

      Process.sleep(200)

      fires =
        IntegrationRepo.all(
          from(w in WorkflowExecution, group_by: w.trigger_ref, select: {w.trigger_ref, count()})
        )

      assert length(fires) == 20
      assert Enum.all?(fires, fn {_name, count} -> count == 1 end), inspect(fires)
    end
  end

  describe "#6 key locks" do
    test "two start_many calls with the same keys in opposite orders both finish" do
      idle_durable!()

      items = for n <- 1..200, do: {Keyed, %{"n" => n}, key: "k#{n}"}

      [forward, backward] =
        [items, Enum.reverse(items)]
        |> Enum.map(fn batch ->
          Task.async(fn ->
            try do
              {batch, Durable.start_many(batch)}
            rescue
              error -> {batch, {:raised, error}}
            end
          end)
        end)
        |> Task.await_many(30_000)

      for {batch, results} <- [forward, backward] do
        assert is_list(results), inspect(results)
        assert length(results) == 200

        for {{_, _, [key: key]}, {:ok, id}} <- Enum.zip(batch, results) do
          assert get(id).key == key
        end
      end

      assert IntegrationRepo.aggregate(WorkflowExecution, :count) == 200
    end

    test "a lock that fails is an error, not a MatchError" do
      idle_durable!()
      parent = self()

      holder =
        Task.async(fn ->
          IntegrationRepo.transaction(fn ->
            {:ok, _} = Durable.start(Keyed, %{}, key: "held")
            send(parent, :holding)
            Process.sleep(600)
          end)
        end)

      assert_receive :holding, 2_000

      {:error, :rollback} =
        IntegrationRepo.transaction(fn ->
          IntegrationRepo.query!("SET LOCAL lock_timeout = '50ms'")
          result = Durable.start(Keyed, %{}, key: "held")
          send(parent, {:started, result})
        end)

      assert_receive {:started, {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}}}

      {:error, :rollback} =
        IntegrationRepo.transaction(fn ->
          IntegrationRepo.query!("SET LOCAL lock_timeout = '50ms'")
          result = Durable.start_many([{Keyed, %{}, key: "held"}, {Keyed, %{}, key: "other"}])
          send(parent, {:many, result})
        end)

      assert_receive {:many, [{:error, %Postgrex.Error{}}, {:error, %Postgrex.Error{}}]}

      Task.await(holder)
    end
  end

  describe "#7 a run's data keeps its shape" do
    defp wake_until_done(id) do
      assert_eventually(fn ->
        SleepWaker.wake_now(Durable)
        get(id).status == :completed
      end)
    end

    test "across a sleep" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(ReadsAfterSleep, %{"id" => 42})
      wake_until_done(id)

      assert labels() == [{:first, 42}, {:first, 42}, {:second, 42}]
      assert get(id).context == %{"id" => 42, "seen" => 42}
    end

    test "across an event" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(ReadsAfterEvent, %{"id" => 42})
      await_status(id, :waiting)
      :ok = Durable.send_event(id, "go", %{})
      await_status(id, :completed)

      assert labels() == [{:first, 42}, {:first, 42}, {:second, 42}]
    end

    test "across an input" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(ReadsAfterInput, %{"id" => 42})
      await_status(id, :waiting)
      :ok = Durable.provide_input(id, "ok", %{"yes" => true})
      await_status(id, :completed)

      assert labels() == [{:first, 42}, {:first, 42}, {:second, 42}]
    end

    test "into a parallel branch and out of it" do
      start_durable!(%{default: 2})

      {:ok, id} = Durable.start(ReadsInParallel, %{"id" => 42})
      await_status(id, :completed)

      assert Enum.sort(labels()) == [{:branch, 42}, {:second, 42}]
    end

    test "with atom keys staying atoms, next to string ones" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(KeepsAtomKeys, %{"id" => 42})
      wake_until_done(id)

      assert labels() == [{:second, 7}, {:second, 7}, {:third, 7, 42}]
    end

    test "when a crash puts the run back" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(ReadsAfterCrash, %{"id" => 42})
      await_status(id, :completed)

      assert labels() == [{:second, 1}, {:second, 1}]
    end

    test "and the record of it stays out of what callers read" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(ReadsAfterEvent, %{"id" => 42})
      await_status(id, :waiting)

      assert Map.has_key?(get(id).context, "__string_keys__")
      {:ok, execution} = Durable.get_execution(id)
      assert execution.context == %{"id" => 42}
    end

    test "and a run parked before the upgrade still resumes as it did" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(KeepsAtomKeys, %{"id" => 42})
      assert_eventually(fn -> get(id).status == :waiting end)

      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [context: %{"total" => 7, "id" => 42}]
        )

      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [scheduled_at: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      wake_until_done(id)
      assert {:third, 7, nil} in labels()
    end
  end

  describe "#11 @schedule at boot" do
    test "turns off a schedule the module no longer declares, keeps the rest" do
      insert_schedule!("gone", "code")
      insert_schedule!("made_by_hand", "api")

      start_durable!(%{default: 1}, scheduled_modules: [Declares])

      assert {:ok, %{enabled: false, source: "removed"}} = API.get_schedule("gone")
      assert {:ok, %{enabled: true, source: "api"}} = API.get_schedule("made_by_hand")
      assert {:ok, %{enabled: true, source: "code"}} = API.get_schedule("declared")
    end
  end

  describe "#12 cancel" do
    test "leaves no row running when the step dies before the heartbeat stops it" do
      start_durable!(%{default: 1}, heartbeat_interval: 60_000)

      {:ok, id} = Durable.start(DiesOnSignal, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)

      :ok = Durable.cancel(id)
      :ok = Probe.set(:die)

      assert_eventually(fn ->
        match?([%{status: :failed, error: %{"type" => "task_crash"}}], step_rows(id))
      end)

      assert get(id).status == :cancelled
    end

    test "stops a running step" do
      start_durable!(%{default: 1}, heartbeat_interval: 50)

      {:ok, id} = Durable.start(SlowCancellable, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)
      worker = worker_pid!(id)

      :ok = Durable.cancel(id, "stop it")

      assert_eventually(fn -> not Process.alive?(worker) end, 700, 10)

      Process.sleep(1_600)
      assert Probe.hits(:finished) == 0
      assert Probe.hits(:after) == 0
      assert get(id).status == :cancelled
      assert [%{status: :cancelled}] = step_rows(id)
    end

    test "cancelled?/0 tells a step that wants to stop cleanly" do
      start_durable!(%{default: 1}, heartbeat_interval: :timer.hours(1))

      {:ok, id} = Durable.start(PollsCancelled, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)

      :ok = Durable.cancel(id)
      :ok = Probe.set(:cancelled)

      assert_eventually(fn -> {:saw_cancelled, true} in labels() end)
    end
  end

  describe "#15 claim errors" do
    test "are logged and reported" do
      idle_durable!()

      test_pid = self()
      handler = "claim-failed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:durable, :queue, :claim_failed],
        fn _event, measurements, meta, _ ->
          send(test_pid, {:claim_failed, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      broken = %{Durable.Config.get(Durable) | prefix: "no_such_schema"}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Postgres.fetch_jobs(broken, "default", 1, "node_a") == []
        end)

      assert log =~ "claim"
      assert log =~ "no_such_schema"
      assert_receive {:claim_failed, %{count: 1}, %{queue: "default"}}
    end
  end

  describe "audit 1 a step whose lock goes stale" do
    test "with one attempt runs again instead of failing the run" do
      start_durable!(%{default: 2}, stale_lock_timeout: 1, heartbeat_interval: 60_000)

      {:ok, id} = Durable.start(StaleOnce, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)
      lose_lock!()

      await_status(id, :completed)
      assert Probe.hits(:body) == 2

      assert [%{status: :failed, error: %{"type" => "worker_lost"}}, %{status: :completed}] =
               step_rows(id)

      :ok = Probe.set(:release)
    end

    for ending <- [:ok, :error, :sleep] do
      @ending ending

      test "can't end an attempt that was already closed (#{ending})" do
        start_durable!(%{default: 2}, stale_lock_timeout: 1, heartbeat_interval: 60_000)
        :ok = Probe.put(:ending, @ending)

        {:ok, id} = Durable.start(EndsLate, %{})
        assert_eventually(fn -> Probe.hits(:body) == 1 end)
        old_worker = Process.monitor(worker_pid!(id))
        lose_lock!()
        await_status(id, :completed)

        :ok = Probe.set(:release)
        assert_receive {:DOWN, ^old_worker, :process, _pid, _reason}, 5_000

        assert [%{status: :failed, error: %{"type" => "worker_lost"}}, %{status: :completed}] =
                 step_rows(id)

        assert get(id).status == :completed
      end
    end

    test "with its node each time fails the run after three, so it can't loop forever" do
      start_durable!(%{default: 1}, stale_lock_timeout: 1)

      {:ok, id} = Durable.start(Held, %{})

      for lost <- 1..3 do
        assert_eventually(fn -> Probe.hits(:body) == lost end)
        Process.exit(worker_pid!(id), :kill)
        lose_lock!()
      end

      run = await_status(id, :failed)

      assert Probe.hits(:body) == 3
      assert run.error["type"] == "worker_lost"
      assert length(step_rows(id)) == 3
    end

    test "warns at boot when the heartbeat is too close to the stale timeout" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_durable!(%{default: 1}, stale_lock_timeout: 3, heartbeat_interval: 1_001)
        end)

      assert log =~ "heartbeat_interval"
    end

    test "says nothing at boot when the heartbeat is well under it" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_durable!(%{default: 1}, stale_lock_timeout: 3, heartbeat_interval: 1_000)
        end)

      refute log =~ "heartbeat_interval"
    end
  end

  describe "audit 2 a schedule that can't start" do
    setup do
      start_durable!(%{default: 1}, scheduler_interval: :timer.hours(1))
      :ok
    end

    test "doesn't stop the ones after it" do
      due_schedule!("bad_zone", timezone: "Nowhere/Land")
      for n <- 1..3, do: due_schedule!("ok#{n}")

      run_check!()

      fired = IntegrationRepo.all(from(w in WorkflowExecution, select: w.trigger_ref))
      assert Enum.sort(fired) == ["ok1", "ok2", "ok3"]

      bad = schedule_row("bad_zone")
      assert bad.consecutive_failures == 1
      assert bad.last_error =~ "Nowhere/Land"
      assert DateTime.after?(bad.next_run_at, DateTime.utc_now())
    end

    test "is turned off after five failures in a row" do
      bad = due_schedule!("bad_zone", timezone: "Nowhere/Land")

      for _ <- 1..5 do
        run_check!()
        make_due!(bad)
      end

      run_check!()

      assert %{enabled: false, auto_disabled_at: %DateTime{}, consecutive_failures: 5} =
               schedule_row("bad_zone")
    end

    test "that returns an error counts as a failure too" do
      due_schedule!("not_a_workflow", workflow_module: "Elixir.String")

      run_check!()

      row = schedule_row("not_a_workflow")
      assert row.consecutive_failures == 1
      assert is_binary(row.last_error)
      assert DateTime.after?(row.next_run_at, DateTime.utc_now())
    end

    # The database answers again here, which is the case that matters:
    # with the pool still full, recording a failure would be refused as well.
    test "because a connection was refused counts against nothing" do
      due_schedule!("refused", workflow_module: inspect(RefusedOnStart))

      run_check!()

      row = schedule_row("refused")
      assert row.consecutive_failures == 0
      assert row.last_error == nil
      assert DateTime.before?(row.next_run_at, DateTime.utc_now())
    end

    test "is forgiven by a fire that starts" do
      schedule = due_schedule!("recovers", timezone: "Nowhere/Land")
      run_check!()
      assert schedule_row("recovers").consecutive_failures == 1

      make_due!(schedule, timezone: "Etc/UTC")
      run_check!()

      assert %{consecutive_failures: 0, last_error: nil, last_error_at: nil} =
               schedule_row("recovers")
    end
  end
end
