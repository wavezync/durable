defmodule Durable.Integration.FailurePathsTest do
  @moduledoc """
  What happens when something goes wrong underneath a run: its step's process
  dies, the pool is busy, the node stops heartbeating, or two callers race.
  Each `#n` in a describe is that item of GitHub issue #32, and each `audit n`
  that item of the re-audit posted on it.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.LogCapture.Handler
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

  # One zone, five hours behind UTC, so a test doesn't need a real tz database.
  defmodule FixedZone do
    @behaviour Calendar.TimeZoneDatabase
    @period %{utc_offset: -18_000, std_offset: 0, zone_abbr: "TST"}

    @utc %{utc_offset: 0, std_offset: 0, zone_abbr: "UTC"}

    @impl true
    def time_zone_period_from_utc_iso_days(_, "Test/NewYork"), do: {:ok, @period}
    def time_zone_period_from_utc_iso_days(_, "Etc/UTC"), do: {:ok, @utc}
    def time_zone_period_from_utc_iso_days(_, _), do: {:error, :time_zone_not_found}

    @impl true
    def time_zone_periods_from_wall_datetime(_, "Test/NewYork"), do: {:ok, @period}
    def time_zone_periods_from_wall_datetime(_, "Etc/UTC"), do: {:ok, @utc}
    def time_zone_periods_from_wall_datetime(_, _), do: {:error, :time_zone_not_found}
  end

  defmodule ParallelThenReads do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_parallel_then_reads" do
      parallel do
        step(:a, fn d -> {:ok, Map.put(d, "a", String.duplicate("x", 50))} end)
        step(:b, fn d -> {:ok, Map.put(d, "b", 1)} end)
      end

      step(:next, fn d ->
        Probe.put(:next_keys, Map.keys(d))
        {:ok, d}
      end)
    end
  end

  defmodule SleepsThenReads do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_sleeps_then_reads" do
      step(:nap, fn d ->
        Probe.note({:keys, Map.keys(d)})
        sleep(20)
        {:ok, d}
      end)
    end
  end

  defmodule LogsEverything do
    use Durable
    require Logger

    workflow "fp_logs_everything", log_metadata: fn d -> [account_id: d["account_id"]] end do
      step(:work, fn d ->
        # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
        Logger.info("plain", order_id: 7)
        # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
        Logger.warning("odd", blob: <<255>>, nul: "a" <> <<0>> <> "b", pair: {1, 2})
        Logger.info("nul in the" <> <<0>> <> "message")
        {:ok, d}
      end)
    end
  end

  defmodule PrintsAndLogs do
    use Durable

    workflow "fp_prints_and_logs" do
      step(:work, fn d ->
        IO.puts("printed")
        {:ok, d}
      end)
    end
  end

  defmodule SlowCompensation do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "fp_slow_compensation" do
      step(:book, [compensate: :unbook], fn d -> {:ok, d} end)
      step(:charge, fn _d -> {:fail, "declined"} end)

      compensate(:unbook, fn d ->
        Probe.note(:undo)
        Probe.wait_for(:release)

        case Probe.fetch(:compensation_ending) do
          :ok -> {:ok, d}
          :fail -> {:fail, "too late"}
        end
      end)
    end
  end

  defmodule LogsFromTasks do
    use Durable
    use Durable.Context
    require Logger

    workflow "fp_logs_from_tasks" do
      step(:work, fn d ->
        Logger.info("before")

        Task.await(
          Task.async(
            bind(fn ->
              # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
              Logger.info("bound", in_task: true)
              workflow_id()
            end)
          )
        )
        |> then(&Durable.IntegrationProbe.put(:task_saw_run, &1))

        Task.await(Task.async(fn -> Logger.info("unbound") end))
        Logger.info("after")
        {:ok, d}
      end)
    end
  end

  defmodule LogsWithinTimeLimit do
    use Durable
    use Durable.Context
    require Logger

    workflow "fp_logs_within_time_limit" do
      step(:work, [timeout: 5_000], fn d ->
        Logger.info("in the limit")
        Task.await(Task.async(bind(fn -> Logger.info("bound under a limit") end)))
        {:ok, d}
      end)
    end
  end

  defmodule LogsInBranch do
    use Durable
    require Logger

    workflow "fp_logs_in_branch" do
      parallel do
        step(:branch, fn d ->
          Logger.info("from a branch")
          {:ok, d}
        end)
      end
    end
  end

  defmodule GrandChild do
    use Durable

    workflow "fp_grand_child" do
      step(:work, fn d -> {:ok, d} end)
    end
  end

  defmodule MiddleChild do
    use Durable
    use Durable.Orchestration

    workflow "fp_middle_child" do
      step(:call, fn d ->
        {:ok, _} = call_workflow(GrandChild, %{}, ref: :child)
        {:ok, d}
      end)
    end
  end

  defmodule TopParent do
    use Durable
    use Durable.Orchestration

    workflow "fp_top_parent" do
      step(:call, fn d ->
        {:ok, _} = call_workflow(MiddleChild, %{}, ref: :child)
        {:ok, d}
      end)
    end
  end

  defmodule ChecksConsole do
    use Durable
    alias Durable.IntegrationProbe, as: Probe
    alias Durable.LogCapture.Handler

    workflow "fp_checks_console" do
      step(:work, fn d ->
        Probe.put(:saved_line, Handler.console_filter(%{level: :info, meta: %{}}, []))

        Probe.put(
          :internal_line,
          Handler.console_filter(%{level: :info, meta: %{durable_internal: true}}, [])
        )

        Probe.put(:uncaptured_level, Handler.console_filter(%{level: :debug, meta: %{}}, []))
        {:ok, d}
      end)
    end
  end

  # Looking it up fails the way a refused connection does.
  defmodule RefusedOnStart do
    def __workflow_definition__(_name) do
      raise DBConnection.ConnectionError, "connection not available"
    end
  end

  defmodule CancelsManyBranches do
    use Durable
    use Durable.Wait

    workflow "fp_cancels_many_branches" do
      parallel do
        step(:stops, fn _data ->
          # Long enough for the other branches to be under way.
          Process.sleep(150)
          {:cancel, "stop them all"}
        end)

        step(:w1, fn data -> {:ok, Map.put(data, "e", wait_for_event("never"))} end)
        step(:w2, fn data -> {:ok, Map.put(data, "e", wait_for_event("never"))} end)
        step(:w3, fn data -> {:ok, Map.put(data, "e", wait_for_event("never"))} end)
        step(:w4, fn data -> {:ok, Map.put(data, "e", wait_for_event("never"))} end)
        step(:w5, fn data -> {:ok, Map.put(data, "e", wait_for_event("never"))} end)
        step(:w6, fn data -> {:ok, Map.put(data, "e", wait_for_event("never"))} end)
        step(:w7, fn data -> {:ok, Map.put(data, "e", wait_for_event("never"))} end)
        step(:w8, fn data -> {:ok, Map.put(data, "e", wait_for_event("never"))} end)
        step(:w9, fn data -> {:ok, Map.put(data, "e", wait_for_event("never"))} end)
        step(:w10, fn data -> {:ok, Map.put(data, "e", wait_for_event("never"))} end)
      end
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

  defp capture_span_events do
    test = self()
    handler = "spans-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      Durable.Telemetry.events(),
      fn name, measurements, meta, _ -> send(test, {:span, name, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # Waits for stragglers: the events come from whichever process ended the span.
  defp span_events do
    Process.sleep(150)
    drain_span_events()
  end

  defp drain_span_events do
    receive do
      {:span, name, measurements, meta} -> [{name, measurements, meta} | drain_span_events()]
    after
      0 -> []
    end
  end

  defp metas(events, name), do: for({^name, _, meta} <- events, do: meta)

  defp segments(events),
    do: events |> metas([:durable, :workflow, :stop]) |> Enum.map(& &1.status) |> Enum.sort()

  defp attempt_results(events) do
    events |> metas([:durable, :step, :stop]) |> Enum.map(&{&1.attempt, &1.result}) |> Enum.sort()
  end

  defp assert_every_attempt_ended_once(events) do
    starts = events |> metas([:durable, :step, :start]) |> Enum.map(& &1.step_execution_id)

    ends =
      for {[:durable, :step, phase], _, meta} <- events,
          phase in [:stop, :exception],
          do: meta.step_execution_id

    assert Enum.sort(starts) == Enum.sort(ends)
    assert starts == Enum.uniq(starts)
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
    test "closes the row of a step whose node is gone" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Held, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)
      Process.exit(worker_pid!(id), :kill)

      :ok = Durable.cancel(id)

      assert [%{status: :cancelled, error: %{"type" => "cancelled"}, completed_at: %DateTime{}}] =
               step_rows(id)
    end

    # A cancel can land after the step passed its run check and before its row
    # exists. after_cancel/2 then finds nothing, so the row outlives the cancel.
    test "leaves no row running when the step dies after a cancel that missed its row" do
      start_durable!(%{default: 1}, heartbeat_interval: 60_000)

      {:ok, id} = Durable.start(DiesOnSignal, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)

      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [status: :cancelled, locked_by: nil, locked_at: nil, lock_token: nil]
        )

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

    test "keeps to the schedule's own time zone" do
      previous = Calendar.get_time_zone_database()
      Calendar.put_time_zone_database(FixedZone)
      on_exit(fn -> Calendar.put_time_zone_database(previous) end)

      {:ok, schedule} = API.schedule(Tick, "0 9 * * *", name: "ny", timezone: "Test/NewYork")
      make_due!(schedule, workflow_module: "Elixir.String")

      run_check!()

      assert %{hour: 14, minute: 0} = schedule_row("ny").next_run_at
    end

    test "in a zone that can't be resolved tries again in five minutes" do
      due_schedule!("bad_zone", timezone: "Nowhere/Land")

      run_check!()

      wait_s = DateTime.diff(schedule_row("bad_zone").next_run_at, DateTime.utc_now())
      assert wait_s in 295..300
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

  describe "a branch that cancels its workflow" do
    # A heartbeat at every chance is what kills the step's process mid-cascade.
    test "still reaches every other branch" do
      start_durable!(%{default: 12}, heartbeat_interval: 1)

      {:ok, id} = Durable.start(CancelsManyBranches, %{})

      await_status(id, :cancelled)

      assert_eventually(fn ->
        children =
          IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^id))

        length(children) == 11 and Enum.all?(children, &(&1.status == :cancelled))
      end)
    end
  end

  describe "audit 5 internal keys" do
    defp internal(keys),
      do:
        Enum.filter(keys, &String.starts_with?(to_string(&1), "__")) --
          [:__results__, "__results__"]

    test "stay out of the data after a parallel block" do
      start_durable!(%{default: 3})

      {:ok, id} = Durable.start(ParallelThenReads, %{"id" => 1})
      run = await_status(id, :completed)

      assert internal(Probe.fetch(:next_keys)) == []
      assert internal(Map.keys(run.context)) == []
    end

    test "stay out of a step run again after its sleep" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(SleepsThenReads, %{"id" => 1})
      wake_until_done(id)

      assert [{:keys, first}, {:keys, second}] = labels()
      assert internal(first) == []
      assert internal(second) == []
    end
  end

  describe "audit 3 an attempt that dies" do
    setup do
      capture_span_events()
      :ok
    end

    test "and is retried ends with an error, then a retry event" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(LinkedCrashRetried, %{})
      await_status(id, :completed)
      events = span_events()

      assert attempt_results(events) == [{1, :error}, {2, :error}, {3, :ok}]
      assert_every_attempt_ended_once(events)

      assert [%{error: %{type: "task_crash"}}, %{error: %{type: "task_crash"}}] =
               metas(events, [:durable, :step, :retry])

      assert segments(events) == [:completed, :superseded, :superseded]

      for {[:durable, :step, :stop], measurements, meta} <- events do
        assert meta.workflow == "fp_linked_crash_retried"
        assert meta.step == :work
        assert meta.max_attempts == 3
        assert measurements.duration >= 0
      end
    end

    test "on its only attempt ends with no retry, and the run fails" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(LinkedCrash, %{})
      await_status(id, :failed)
      events = span_events()

      assert attempt_results(events) == [{1, :error}]
      assert metas(events, [:durable, :step, :retry]) == []
      assert_every_attempt_ended_once(events)
      assert segments(events) == [:failed, :superseded]
    end

    test "with its node ends when recovery finds it, and the retry is reported" do
      start_durable!(%{default: 1}, stale_lock_timeout: 1)

      {:ok, id} = Durable.start(Held, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)
      Process.exit(worker_pid!(id), :kill)
      lose_lock!()

      assert_eventually(fn -> Probe.hits(:body) == 2 end)
      :ok = Probe.set(:release)
      await_status(id, :completed)
      events = span_events()

      assert attempt_results(events) == [{1, :error}, {1, :ok}]
      assert_every_attempt_ended_once(events)

      assert [%{error: %{type: "worker_lost"}}] = metas(events, [:durable, :step, :retry])

      assert [{_, %{backoff_ms: 0}, _}] =
               for({[:durable, :step, :retry], _, _} = e <- events, do: e)

      assert segments(events) == [:completed, :superseded]
    end

    test "for the last time reports no retry" do
      start_durable!(%{default: 1}, stale_lock_timeout: 1)

      {:ok, id} = Durable.start(Held, %{})

      for lost <- 1..3 do
        assert_eventually(fn -> Probe.hits(:body) == lost end)
        Process.exit(worker_pid!(id), :kill)
        lose_lock!()
      end

      await_status(id, :failed)
      events = span_events()

      assert length(metas(events, [:durable, :step, :retry])) == 2
      assert_every_attempt_ended_once(events)
    end

    test "that was still running ends once, however late it finishes" do
      start_durable!(%{default: 2}, stale_lock_timeout: 1, heartbeat_interval: 60_000)
      :ok = Probe.put(:ending, :ok)

      {:ok, id} = Durable.start(EndsLate, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)
      old_worker = Process.monitor(worker_pid!(id))
      lose_lock!()
      await_status(id, :completed)

      :ok = Probe.set(:release)
      assert_receive {:DOWN, ^old_worker, :process, _pid, _reason}, 5_000
      events = span_events()

      assert attempt_results(events) == [{1, :error}, {1, :ok}]
      assert_every_attempt_ended_once(events)
      assert segments(events) == [:completed, :superseded]

      # The old worker reports being superseded, not a crash.
      assert Enum.any?(
               metas(events, [:durable, :queue, :job_completed]),
               &(&1.status == :superseded)
             )
    end

    for ending <- [:ok, :fail] do
      @comp_ending ending

      test "in a compensation that ends (#{ending}) after the sweep closed it stays closed" do
        start_durable!(%{default: 1}, stale_lock_timeout: 1, heartbeat_interval: 60_000)

        :ok = Probe.put(:compensation_ending, @comp_ending)

        {:ok, id} = Durable.start(SlowCompensation, %{})
        assert_eventually(fn -> Probe.hits(:undo) == 1 end)
        old_worker = Process.monitor(worker_pid!(id))
        Process.sleep(1_100)
        config = Durable.Config.get(Durable)

        {1, _} =
          IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
            set: [updated_at: DateTime.add(DateTime.utc_now(), -5, :second)]
          )

        {:ok, 1} = Postgres.recover_zombie_workflows(config, 1)

        :ok = Probe.set(:release)
        assert_receive {:DOWN, ^old_worker, :process, _pid, _reason}, 5_000
        events = span_events()

        assert [%{result: :error}] = metas(events, [:durable, :compensation, :stop])
        assert get(id).status == :failed

        assert %{status: :failed, error: %{"type" => "zombie_detected"}} =
                 Enum.find(step_rows(id), & &1.is_compensation)
      end
    end

    test "when its run is cancelled ends as cancelled, once" do
      start_durable!(%{default: 1}, heartbeat_interval: 50)

      {:ok, id} = Durable.start(SlowCancellable, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)
      worker = Process.monitor(worker_pid!(id))
      :ok = Durable.cancel(id)
      assert_receive {:DOWN, ^worker, :process, _pid, _reason}, 5_000
      events = span_events()

      assert attempt_results(events) == [{1, :cancelled}]
      assert_every_attempt_ended_once(events)
      assert segments(events) == [:superseded]
    end

    test "when its node is gone and the run is cancelled ends as cancelled" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Held, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)
      Process.exit(worker_pid!(id), :kill)
      :ok = Durable.cancel(id)
      events = span_events()

      assert attempt_results(events) == [{1, :cancelled}]
      assert_every_attempt_ended_once(events)
    end

    test "in a compensation ends that compensation" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(KilledCompensation, %{})
      assert_eventually(fn -> Probe.hits(:undo) == 1 end)
      Process.exit(:sys.get_state(worker_pid!(id)).task_pid, :kill)
      await_status(id, :failed)
      events = span_events()

      starts = metas(events, [:durable, :compensation, :start])

      assert [%{result: :error, compensation: compensation}] =
               metas(events, [:durable, :compensation, :stop])

      assert [%{compensation: ^compensation}] = starts
      assert [%{telemetry_span_context: ref}] = starts
      assert [%{telemetry_span_context: ^ref}] = metas(events, [:durable, :compensation, :stop])
    end

    test "when a stopping node hands it back ends as snoozed, with no retry" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Held, %{})
      assert_eventually(fn -> Probe.hits(:body) == 1 end)
      config = Durable.Config.get(Durable)
      {:ok, 1} = Postgres.release_node_jobs(config, config.node_id)
      events = span_events()

      assert [%{result: :snoozed}] = metas(events, [:durable, :step, :stop])
      assert metas(events, [:durable, :step, :retry]) == []
      assert get(id).status in [:pending, :running]
      :ok = Probe.set(:release)
    end
  end

  describe "audit 4 saved log lines" do
    defp hex(id), do: String.replace(id, "-", "")
    defp messages(row), do: Enum.map(row.logs, & &1["message"])

    defp put_log_capture(changes) do
      previous = Application.get_env(:durable, :log_capture, [])
      Application.put_env(:durable, :log_capture, Keyword.merge(previous, changes))
      on_exit(fn -> Application.put_env(:durable, :log_capture, previous) end)
    end

    test "keep their metadata, the run's details and OpenTelemetry's ids" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(LogsEverything, %{"account_id" => 42})
      await_status(id, :completed)

      [row] = step_rows(id)
      [plain, odd, nul] = row.logs

      assert %{
               "order_id" => 7,
               "workflow" => "fp_logs_everything",
               "workflow_id" => ^id,
               "step" => "work",
               "attempt" => 1,
               "account_id" => 42
             } = plain["metadata"]

      assert plain["severity_number"] == 9
      assert plain["trace_id"] == hex(id)
      assert plain["span_id"] == row.id |> hex() |> String.slice(16, 16)

      for key <- ~w(gl pid time mfa file domain erl_level source durable_internal) do
        refute Map.has_key?(plain["metadata"], key), key
      end

      assert odd["severity_number"] == 13
      assert is_binary(odd["metadata"]["pair"])
      assert String.valid?(odd["metadata"]["blob"])
      refute String.contains?(odd["metadata"]["nul"], <<0>>)
      refute String.contains?(nul["message"], <<0>>)
    end

    test "that were printed carry the run's details too" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(PrintsAndLogs, %{})
      await_status(id, :completed)

      assert [%{logs: [line]}] = step_rows(id)
      assert line["source"] == "io"
      assert line["metadata"]["workflow_id"] == id
      assert line["trace_id"] == hex(id)
    end

    test "can be narrowed with metadata_filter" do
      put_log_capture(metadata_filter: [:order_id])
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(LogsEverything, %{"account_id" => 42})
      await_status(id, :completed)

      [row] = step_rows(id)
      assert hd(row.logs)["metadata"] == %{"order_id" => 7}
    end

    test "from a bound Task are saved in order, with the run's details" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(LogsFromTasks, %{})
      await_status(id, :completed)

      [row] = step_rows(id)
      assert messages(row) == ["before", "bound", "after"]
      assert Probe.fetch(:task_saw_run) == id

      bound = Enum.at(row.logs, 1)
      assert bound["metadata"]["in_task"] == true
      assert bound["metadata"]["workflow_id"] == id
      assert bound["trace_id"] == hex(id)
    end

    test "from a bound Task reach the row under a step's time limit too" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(LogsWithinTimeLimit, %{})
      await_status(id, :completed)

      assert [row] = step_rows(id)
      assert messages(row) == ["in the limit", "bound under a limit"]
    end

    test "of a child run carry its top run's trace id" do
      start_durable!(%{default: 2})

      {:ok, id} = Durable.start(LogsInBranch, %{})
      await_status(id, :completed)

      [branch] =
        IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^id))

      assert branch.root_workflow_id == id
      assert [%{logs: [line]}] = step_rows(branch.id)
      assert line["trace_id"] == hex(id)
    end

    test "name the top of a tree from any depth" do
      start_durable!(%{default: 3})

      {:ok, id} = Durable.start(TopParent, %{})

      assert_eventually(
        fn ->
          IntegrationRepo.aggregate(
            from(w in WorkflowExecution, where: w.status == :completed),
            :count
          ) == 3
        end,
        10_000
      )

      runs = IntegrationRepo.all(WorkflowExecution)
      assert Enum.find(runs, &(&1.id == id)).root_workflow_id == nil
      assert [^id, ^id] = runs |> Enum.reject(&(&1.id == id)) |> Enum.map(& &1.root_workflow_id)
    end

    # :capture_log takes the console handler away for the length of a test.
    @tag capture_log: false
    test "stay on the console by default" do
      Handler.attach()

      {:ok, %{filters: filters}} = :logger.get_handler_config(:default)
      refute List.keymember?(filters, :durable_step_lines, 0)
    end

    # :capture_log takes the console handler away for the length of a test.
    @tag capture_log: false
    test "can be kept off the console, and only the ones that get saved" do
      put_log_capture(console: false, levels: [:info, :warning, :error])
      on_exit(fn -> :logger.remove_handler_filter(:default, :durable_step_lines) end)

      start_durable!(%{default: 1})

      {:ok, %{filters: filters}} = :logger.get_handler_config(:default)
      assert List.keymember?(filters, :durable_step_lines, 0)

      {:ok, id} = Durable.start(ChecksConsole, %{})
      await_status(id, :completed)

      assert Probe.fetch(:saved_line) == :stop
      assert Probe.fetch(:internal_line) == :ignore
      assert Probe.fetch(:uncaptured_level) == :ignore

      # Outside a step, nothing is held back.
      assert Handler.console_filter(%{level: :info, meta: %{}}, []) == :ignore
    end
  end
end
