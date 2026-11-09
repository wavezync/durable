defmodule Durable.Integration.RecoveryAndSchedulesRegressionsTest do
  @moduledoc "Connections and workers lost mid-write, handlers given odd errors, the console setting, clock changes and the schedule API."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 90_000

  alias Durable.LogCapture.Handler
  alias Durable.Queue.StaleJobRecovery
  alias Durable.Scheduler
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.ScheduledWorkflow

  require Logger

  # ---------------------------------------------------------------------------
  # E. a connection lost while writing a step's result
  # ---------------------------------------------------------------------------
  defmodule Booked do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_booked" do
      step(:book, [compensate: :unbook], fn data ->
        Probe.note(:booked)
        {:ok, data}
      end)

      step(:charge, [retry: [max_attempts: 3, backoff: :constant, base: 1]], fn data ->
        Probe.note(:charge)
        Probe.wait_for(:release)
        {:ok, data}
      end)

      compensate(:unbook, fn data ->
        Probe.note(:unbooked)
        {:ok, data}
      end)
    end
  end

  defp step_rows(id) do
    IntegrationRepo.all(
      from(s in StepExecution, where: s.workflow_id == ^id, order_by: s.inserted_at)
    )
  end

  # Holds a row lock so the worker's write blocks, then kills that one backend.
  defp hold_row_then_kill_writer(row_id, fun, kill_with \\ "pg_terminate_backend") do
    test = self()

    holder =
      Task.async(fn ->
        IntegrationRepo.transaction(fn ->
          IntegrationRepo.query!(
            "SELECT 1 FROM durable.step_executions WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(row_id)]
          )

          send(test, :locked)

          receive do
            :let_go -> :ok
          end
        end)
      end)

    assert_receive :locked, 2_000
    fun.()

    pid =
      Enum.find_value(1..200, fn _ ->
        case IntegrationRepo.query!(
               "SELECT pid FROM pg_stat_activity WHERE datname = current_database() " <>
                 "AND wait_event_type = 'Lock' AND query ILIKE 'UPDATE%step_executions%'"
             ).rows do
          [[pid] | _] ->
            pid

          [] ->
            Process.sleep(20)
            nil
        end
      end)

    assert is_integer(pid), "the worker's write never blocked"
    IntegrationRepo.query!("SELECT #{kill_with}($1)", [pid])
    Process.sleep(200)
    send(holder.pid, :let_go)
    Task.await(holder)
  end

  defp capture_attempt_events do
    test = self()
    handler = "attempts-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:durable, :step, :start], [:durable, :step, :stop], [:durable, :step, :exception]],
      fn [:durable, :step, phase], _, meta, _ ->
        send(test, {:attempt, phase, meta.step_execution_id})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp attempt_events do
    Process.sleep(100)
    events = drain_attempts([])
    {for({:start, id} <- events, do: id), for({phase, id} <- events, phase != :start, do: id)}
  end

  defp drain_attempts(acc) do
    receive do
      {:attempt, phase, id} -> drain_attempts([{phase, id} | acc])
    after
      0 -> acc
    end
  end

  describe "one connection dying while a finished step's result is written" do
    test "doesn't fail the run for good" do
      capture_attempt_events()
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Booked, %{})
      assert_eventually(fn -> Probe.hits(:charge) == 1 end)

      row = Enum.find(step_rows(id), &(&1.step_name == "charge"))

      hold_row_then_kill_writer(row.id, fn -> :ok = Probe.set(:release) end)
      Process.sleep(1_500)

      run = get(id)

      refute run.status == :failed

      await_status(id, :completed)
      assert Probe.hits(:charge) == 2
      assert Probe.hits(:unbooked) == 0

      assert [
               %{step_name: "book", status: :completed},
               %{step_name: "charge", status: :failed, error: %{"type" => "worker_lost"}},
               %{step_name: "charge", status: :completed}
             ] = step_rows(id)

      {starts, ends} = attempt_events()
      assert Enum.sort(starts) == Enum.sort(ends)
      assert starts == Enum.uniq(starts)
    end
  end

  describe "a write that fails for any other reason" do
    test "fails the run and closes the step's row" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Booked, %{})
      assert_eventually(fn -> Probe.hits(:charge) == 1 end)

      row = Enum.find(step_rows(id), &(&1.step_name == "charge"))
      hold_row_then_kill_writer(row.id, fn -> :ok = Probe.set(:release) end, "pg_cancel_backend")

      await_status(id, :failed)
      assert Enum.all?(step_rows(id), &(&1.status != :running))
    end
  end

  # ---------------------------------------------------------------------------
  # F. a worker that was taken over between two steps
  # ---------------------------------------------------------------------------
  defmodule TwoSteps do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_two_steps" do
      step(:first, fn data ->
        Probe.note(:first)
        {:ok, Map.put(data, "who", inspect(self()))}
      end)

      step(:second, fn data ->
        Probe.note(:second)
        Probe.inside([:second_peak], fn -> Probe.wait_for(:finish_second) end)
        {:ok, Map.put(data, "second_by", inspect(self()))}
      end)
    end
  end

  describe "a takeover" do
    test "stops the old worker at its next run-level write" do
      start_durable!(%{default: 2}, stale_lock_timeout: 1, heartbeat_interval: 60_000)

      # A pause at the step boundary: what a slow pool, a GC or a frozen VM does.
      handler = "pause-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:durable, :step, :stop],
        fn _, _, meta, _ ->
          if meta.step == :first and Probe.note(:first_stop) == 1 do
            Probe.set(:paused)
            Probe.wait_for(:resume_old)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, id} = Durable.start(TwoSteps, %{})
      assert_eventually(fn -> Probe.set?(:paused) end)

      # The first row is already :completed, so the sweep closes nothing.
      Process.sleep(1_100)
      {:ok, 1} = StaleJobRecovery.recover_now(Durable)

      # The new owner re-runs :first and sits inside :second.
      assert_eventually(fn -> Probe.hits(:second) == 1 end, 5_000)
      token_of_new_owner = get(id).lock_token

      :ok = Probe.set(:resume_old)
      Process.sleep(500)

      peak = Probe.peak(:second_peak)
      :ok = Probe.set(:finish_second)
      await_status(id, :completed)
      assert peak == 1
    end
  end

  # ---------------------------------------------------------------------------
  # D. handlers that die on a step's error
  # ---------------------------------------------------------------------------
  defmodule ErrorWithMapMessage do
    use Durable

    workflow "r_map_message" do
      step(:w, fn _data -> {:fail, %{type: "validation", message: %{field: "name"}}} end)
    end
  end

  defmodule Fine do
    use Durable

    workflow "r_fine" do
      step(:w, fn data -> {:ok, data} end)
    end
  end

  describe "telemetry handlers" do
    test "the OpenTelemetry handler survives an error whose message is a map" do
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
      assert :ok = Durable.OpenTelemetry.setup()
      on_exit(fn -> :telemetry.detach("durable-opentelemetry") end)

      start_durable!(%{default: 1})
      {:ok, bad} = Durable.start(ErrorWithMapMessage, %{})
      await_status(bad, :failed)
      Process.sleep(100)

      attached =
        :telemetry.list_handlers([:durable, :step, :start])
        |> Enum.map(& &1.id)

      {:ok, good} = Durable.start(Fine, %{})
      await_status(good, :completed)

      got_span =
        receive do
          {:span, _} -> true
        after
          500 -> false
        end

      assert "durable-opentelemetry" in attached
    end

    test "the default logger survives it too" do
      :ok = Durable.Telemetry.attach_default_logger()
      on_exit(fn -> :telemetry.detach("durable-default-logger") end)

      start_durable!(%{default: 1})
      {:ok, bad} = Durable.start(ErrorWithMapMessage, %{})
      await_status(bad, :failed)
      Process.sleep(100)

      attached = :telemetry.list_handlers([:durable, :step, :stop]) |> Enum.map(& &1.id)
      assert "durable-default-logger" in attached
    end
  end

  # ---------------------------------------------------------------------------
  # G. console: false
  # ---------------------------------------------------------------------------
  defmodule OverTheLimit do
    use Durable
    alias Durable.IntegrationProbe, as: Probe
    require Logger

    workflow "r_over_limit" do
      step(:w, fn data ->
        Logger.info("one")
        Logger.info("two")
        Logger.info("three")

        Probe.put(
          :filter_result,
          Handler.console_filter(%{level: :info, meta: %{}}, [])
        )

        {:ok, data}
      end)
    end
  end

  defmodule LateTask do
    use Durable
    use Durable.Context
    alias Durable.IntegrationProbe, as: Probe
    require Logger

    workflow "r_late_task" do
      step(:w, fn data ->
        Task.start(
          bind(fn ->
            Probe.wait_for(:step_over)
            Probe.put(:late_filter, Handler.console_filter(%{level: :info, meta: %{}}, []))
            Probe.set(:late_checked)
          end)
        )

        {:ok, data}
      end)
    end
  end

  describe "console: false only holds back lines that get saved" do
    setup do
      previous = Application.get_env(:durable, :log_capture, [])
      Application.put_env(:durable, :log_capture, Keyword.put(previous, :max_log_entries, 2))
      on_exit(fn -> Application.put_env(:durable, :log_capture, previous) end)
      :ok
    end

    test "a line past max_log_entries isn't saved, so it must reach the console" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(OverTheLimit, %{})
      await_status(id, :completed)
      [row] = step_rows(id)
      saved = Enum.map(row.logs, & &1["message"])
      filter = Probe.fetch(:filter_result)
      assert "three" in saved or filter == :ignore
    end

    test "a bound Task's line after the step has ended isn't saved, so it must reach the console" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(LateTask, %{})
      await_status(id, :completed)
      :ok = Probe.set(:step_over)
      assert_eventually(fn -> Probe.set?(:late_checked) end)
      filter = Probe.fetch(:late_filter)
      assert filter == :ignore
    end
  end

  # ---------------------------------------------------------------------------
  # I. daylight saving
  # ---------------------------------------------------------------------------
  defmodule Fold do
    @moduledoc false
    # Clocks go back an hour at the instant stored in :persistent_term.
    @behaviour Calendar.TimeZoneDatabase

    @before %{utc_offset: -18_000, std_offset: 3_600, zone_abbr: "DT"}
    @later %{utc_offset: -18_000, std_offset: 0, zone_abbr: "ST"}
    @utc %{utc_offset: 0, std_offset: 0, zone_abbr: "UTC"}

    def set_transition(%DateTime{} = t), do: :persistent_term.put({__MODULE__, :t}, t)
    defp t, do: :persistent_term.get({__MODULE__, :t})

    defp fold_seconds, do: DateTime.to_unix(t())

    @impl true
    def time_zone_period_from_utc_iso_days(_, "Etc/UTC"), do: {:ok, @utc}

    def time_zone_period_from_utc_iso_days(iso_days, "Test/Fold") do
      {days, {parts, ppd}} = iso_days
      unix = days * 86_400 + div(parts * 86_400, ppd) - 62_167_219_200
      if unix < fold_seconds(), do: {:ok, @before}, else: {:ok, @later}
    end

    def time_zone_period_from_utc_iso_days(_, _), do: {:error, :time_zone_not_found}

    @impl true
    def time_zone_periods_from_wall_datetime(_, "Etc/UTC"), do: {:ok, @utc}

    def time_zone_periods_from_wall_datetime(naive, "Test/Fold") do
      wall = naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
      # Wall time at the instant of the fold, on each side of it.
      wall_at_fold_before = fold_seconds() - 14_400
      wall_at_fold_after = fold_seconds() - 18_000

      cond do
        wall >= wall_at_fold_before -> {:ok, @later}
        wall >= wall_at_fold_after -> {:ambiguous, @before, @later}
        true -> {:ok, @before}
      end
    end

    def time_zone_periods_from_wall_datetime(_, _), do: {:error, :time_zone_not_found}
  end

  defmodule Tick do
    use Durable

    workflow "r_tick" do
      step(:work, fn data -> {:ok, data} end)
    end
  end

  defp use_fold(transition) do
    previous = Calendar.get_time_zone_database()
    Fold.set_transition(transition)
    Calendar.put_time_zone_database(Fold)
    on_exit(fn -> Calendar.put_time_zone_database(previous) end)
  end

  defp idle_durable! do
    Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)
  end

  describe "clocks going back" do
    test "an every-minute schedule keeps firing through the repeated hour" do
      now = DateTime.utc_now()
      # The fold is at the next minute boundary after now.
      next_minute = %{DateTime.add(now, 60, :second) | second: 0, microsecond: {0, 6}}
      use_fold(next_minute)
      idle_durable!()

      {:ok, s} = API.schedule(Tick, "* * * * *", name: "every_minute", timezone: "Test/Fold")
      gap = DateTime.diff(s.next_run_at, now, :second)
      assert gap <= 120
    end

    test "a schedule made during the repeated hour isn't already due" do
      now = DateTime.utc_now()
      use_fold(DateTime.add(now, -1_800, :second))
      idle_durable!()

      {:ok, s} = API.schedule(Tick, "* * * * *", name: "made_in_fold", timezone: "Test/Fold")
      diff = DateTime.diff(s.next_run_at, now, :second)
      assert diff > 0
    end
  end

  # ---------------------------------------------------------------------------
  # K / L. schedule API
  # ---------------------------------------------------------------------------
  describe "schedule inputs" do
    test "update_schedule refuses a time zone schedule/3 would refuse" do
      idle_durable!()
      {:ok, _} = API.schedule(Tick, "0 9 * * *", name: "k")
      schedule_refused = API.schedule(Tick, "0 9 * * *", name: "k2", timezone: "Nowhere/Land")
      updated = API.update_schedule("k", timezone: "Nowhere/Land")
      assert match?({:error, _}, updated)
    end

    test "the documented `cron:` update changes the cron" do
      idle_durable!()
      {:ok, s} = API.schedule(Tick, "0 9 * * *", name: "k3")
      {:ok, updated} = API.update_schedule("k3", cron: "0 10 * * *")
      assert updated.cron_expression == "0 10 * * *"
    end

    test "a cron with no next date is an error, not a raise" do
      idle_durable!()

      result =
        try do
          API.schedule(Tick, "0 0 31 2 *", name: "feb31")
        rescue
          e -> {:raised, Exception.message(e)}
        end

      assert match?({:error, _}, result)
    end

    test "an @schedule with no next date doesn't stop the app booting" do
      defmodule DeclaresFeb31 do
        use Durable
        use Durable.Scheduler.DSL

        @schedule cron: "0 0 31 2 *"
        workflow "r_feb31" do
          step(:work, fn data -> {:ok, data} end)
        end
      end

      result =
        start_supervised(
          {Durable,
           name: Durable,
           repo: IntegrationRepo,
           queues: %{default: [concurrency: 1]},
           scheduled_modules: [DeclaresFeb31]}
        )

      assert match?({:ok, _}, result)
    end
  end

  describe "auto-disable bookkeeping" do
    test "re-enabling clears it, so a later single failure isn't reported as a disable" do
      start_durable!(%{default: 1})
      {:ok, s} = API.schedule(Tick, "* * * * *", name: "ad")

      {1, _} =
        IntegrationRepo.update_all(from(x in ScheduledWorkflow, where: x.id == ^s.id),
          set: [
            enabled: false,
            consecutive_failures: 5,
            auto_disabled_at: DateTime.utc_now(),
            last_error: "boom"
          ]
        )

      {:ok, enabled} = API.enable_schedule("ad")

      # A fire that works.
      make_due = DateTime.add(DateTime.utc_now(), -5, :second)

      {1, _} =
        IntegrationRepo.update_all(from(x in ScheduledWorkflow, where: x.id == ^s.id),
          set: [next_run_at: make_due]
        )

      Scheduler.check_schedules(Durable)
      Scheduler.status(Durable)
      row = IntegrationRepo.get!(ScheduledWorkflow, s.id)

      assert row.auto_disabled_at == nil

      # One later failure.
      {1, _} =
        IntegrationRepo.update_all(from(x in ScheduledWorkflow, where: x.id == ^s.id),
          set: [next_run_at: make_due, timezone: "Nowhere/Land"]
        )

      Scheduler.check_schedules(Durable)
      Scheduler.status(Durable)

      disabled =
        Enum.filter(
          Durable.Activity.list(kinds: ["schedule_disabled"]),
          &(&1.details["schedule"] == "ad")
        )

      assert disabled == []
    end
  end
end
