defmodule Durable.Integration.AuditRegressionsTest do
  @moduledoc "Issue #36 and the engine audit that followed it: runs that can't end, code that runs twice or not at all, and blocks that quietly do the wrong thing."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 120_000

  alias Durable.Queue.Adapters.Postgres
  alias Durable.Scheduler.API
  alias Durable.Wait.TimeoutWorker

  defmodule Timed do
    use Durable

    workflow "a_timed", timeout: 3_600_000 do
      step(:w, fn data -> {:ok, data} end)
    end
  end

  defmodule AsksInParallel do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "a_asks_in_parallel" do
      parallel do
        step(:ask, fn data ->
          Probe.note(:ask)
          wait_for_input("ok", timeout: 1, on_timeout: :fail)
          {:ok, data}
        end)

        step(:other, fn data -> {:ok, data} end)
      end
    end
  end

  defmodule UndoesOnce do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "a_undoes_once" do
      step(:a, [compensate: :undo_a], fn data ->
        Probe.note(:a)
        {:ok, data}
      end)

      step(:b, fn _data -> {:error, "no"} end)

      compensate(:undo_a, fn data ->
        Probe.note(:undo_a)
        {:ok, data}
      end)
    end
  end

  defmodule IntoThrows do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "a_into_throws" do
      step(:a, [compensate: :undo_a], fn data -> {:ok, data} end)

      parallel into: fn _ctx, _results -> throw(:nope) end do
        step(:x, fn data -> {:ok, data} end)
      end

      compensate(:undo_a, fn data ->
        Probe.note(:undo_a)
        {:ok, data}
      end)
    end
  end

  defmodule DiesBetweenSteps do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "a_dies_between_steps" do
      step(:a, [compensate: :undo_a], fn data -> {:ok, data} end)

      branch on: fn _data ->
               Probe.note(:on)
               Process.exit(self(), :kill)
             end do
        _ -> step(:never, fn data -> {:ok, data} end)
      end

      compensate(:undo_a, fn data ->
        Probe.note(:undo_a)
        {:ok, data}
      end)
    end
  end

  defmodule WaitsTwiceForOne do
    use Durable
    use Durable.Wait

    workflow "a_waits_twice_for_one" do
      step(:w, fn data ->
        wait_for_all(["go", "go"])
        {:ok, data}
      end)
    end
  end

  defmodule Tick do
    use Durable

    workflow "a_tick" do
      step(:work, fn data -> {:ok, data} end)
    end
  end

  defmodule Fold do
    @moduledoc false
    # Clocks go back an hour, from UTC-4 to UTC-5, at the instant stored.
    @behaviour Calendar.TimeZoneDatabase

    @before %{utc_offset: -18_000, std_offset: 3_600, zone_abbr: "DT"}
    @later %{utc_offset: -18_000, std_offset: 0, zone_abbr: "ST"}
    @utc %{utc_offset: 0, std_offset: 0, zone_abbr: "UTC"}

    def set_transition(%DateTime{} = t), do: :persistent_term.put({__MODULE__, :t}, t)
    defp fold_seconds, do: DateTime.to_unix(:persistent_term.get({__MODULE__, :t}))

    @impl true
    def time_zone_period_from_utc_iso_days(_, "Etc/UTC"), do: {:ok, @utc}

    def time_zone_period_from_utc_iso_days({days, {parts, ppd}}, "Test/Fold") do
      unix = days * 86_400 + div(parts * 86_400, ppd) - 62_167_219_200
      if unix < fold_seconds(), do: {:ok, @before}, else: {:ok, @later}
    end

    def time_zone_period_from_utc_iso_days(_, _), do: {:error, :time_zone_not_found}

    @impl true
    def time_zone_periods_from_wall_datetime(_, "Etc/UTC"), do: {:ok, @utc}

    def time_zone_periods_from_wall_datetime(naive, "Test/Fold") do
      wall = naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

      cond do
        wall >= fold_seconds() - 14_400 -> {:ok, @later}
        wall >= fold_seconds() - 18_000 -> {:ambiguous, @before, @later}
        true -> {:ok, @before}
      end
    end

    def time_zone_periods_from_wall_datetime(_, _), do: {:error, :time_zone_not_found}
  end

  defp count_claims(id) do
    test = self()
    handler = "claims-#{inspect(make_ref())}"

    :telemetry.attach(
      handler,
      [:durable, :queue, :job_claimed],
      fn _event, _measures, meta, _config ->
        if meta.job_id == id, do: send(test, :claimed)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp claims(count \\ 0) do
    receive do
      :claimed -> claims(count + 1)
    after
      0 -> count
    end
  end

  # #36.1
  test "a run past its deadline whose code is on no node fails, instead of being claimed forever" do
    start_durable!(%{default: 1})
    {:ok, id} = Durable.start(Timed, %{}, scheduled_at: DateTime.add(DateTime.utc_now(), 3_600))
    count_claims(id)

    IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
      set: [
        workflow_module: "Elixir.Durable.NotDeployedAnywhere",
        scheduled_at: nil,
        # Longer ago than a deploy takes to bring the code.
        deadline_at: DateTime.add(DateTime.utc_now(), -3_600)
      ]
    )

    run = await_status(id, :failed)
    Process.sleep(300)

    assert run.error["type"] == "timeout"
    assert claims() == 1
    assert get(id).status == :failed
  end

  test "a run just past its deadline still waits for a node that has its code" do
    start_durable!(%{default: 1})
    {:ok, id} = Durable.start(Timed, %{}, scheduled_at: DateTime.add(DateTime.utc_now(), 3_600))

    IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
      set: [
        workflow_module: "Elixir.Durable.NotDeployedAnywhere",
        scheduled_at: nil,
        deadline_at: DateTime.add(DateTime.utc_now(), -1)
      ]
    )

    assert_eventually(fn -> get(id).scheduled_at != nil end)
    run = get(id)

    assert run.status == :pending
    assert DateTime.diff(run.scheduled_at, DateTime.utc_now()) in 20..30
  end

  test "an input wait with on_timeout: :fail fails a parallel branch, instead of asking again" do
    start_durable!(%{default: 2})
    {:ok, id} = Durable.start(AsksInParallel, %{})
    assert_eventually(fn -> Probe.hits(:ask) == 1 end)

    assert_eventually(fn ->
      TimeoutWorker.check_timeouts()
      get(id).status == :failed
    end)

    assert get(id).error["type"] == "timeout"
    assert Probe.hits(:ask) == 1
  end

  test "a step that ran twice after a lost lock is undone once" do
    config = start_durable!(%{default: 1}) && Durable.Config.get(Durable)
    handler = "lose-lock-#{inspect(make_ref())}"

    :telemetry.attach(
      handler,
      [:durable, :step, :stop],
      fn _event, _measures, meta, config ->
        if meta.step == :a and Probe.note(:a_ended) == 1 do
          IntegrationRepo.update_all(
            from(w in WorkflowExecution, where: w.id == ^meta.workflow_id),
            set: [locked_at: DateTime.add(DateTime.utc_now(), -3_600)]
          )

          {:ok, 1} = Postgres.recover_stale_locks(config, 300)
        end
      end,
      config
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, id} = Durable.start(UndoesOnce, %{})
    await_status(id, :compensated)

    assert Probe.hits(:a) == 2
    assert Probe.hits(:undo_a) == 1
  end

  test "a parallel into: that throws fails the run through its compensations" do
    start_durable!(%{default: 2})
    {:ok, id} = Durable.start(IntoThrows, %{})

    run = await_status(id, :compensated)

    assert run.error["type"] == "throw"
    assert run.error["message"] == ":nope"
    assert Probe.hits(:undo_a) == 1
  end

  test "a run whose process dies between steps fails through its compensations" do
    start_durable!(%{default: 1})
    {:ok, id} = Durable.start(DiesBetweenSteps, %{})

    run = await_status(id, :compensated)

    assert run.error["type"] == "task_crash"
    assert Probe.hits(:on) == 1
    assert Probe.hits(:undo_a) == 1
    refute Map.has_key?(run.context, "__fail__")
  end

  test "an event named twice in one wait_for_all can still be sent" do
    start_durable!(%{default: 1})
    {:ok, id} = Durable.start(WaitsTwiceForOne, %{})
    await_status(id, :waiting)

    assert Durable.send_event(id, "go", %{}) == :ok
    await_status(id, :completed)
  end

  # #36.3
  describe "step names" do
    defmodule SharedNames do
      use Durable

      workflow "a_first" do
        step(:work, fn data -> {:ok, Map.put(data, "ran", "first")} end)
        decision(:pick, fn data -> {:ok, Map.put(data, "picked", "first")} end)
        step(:fail, [compensate: :undo], fn _data -> {:error, "first"} end)
        compensate(:undo, fn data -> {:ok, data} end)
      end

      workflow "a_second" do
        step(:work, [compensate: :undo], fn data -> {:ok, Map.put(data, "ran", "second")} end)
        decision(:pick, fn data -> {:ok, Map.put(data, "picked", "second")} end)

        compensate(:undo, fn data ->
          Durable.IntegrationProbe.note(:undo_second)
          {:ok, data}
        end)
      end

      workflow "a_second_fails" do
        step(:work, [compensate: :undo], fn data -> {:ok, data} end)
        step(:fail, fn _data -> {:error, "second"} end)

        compensate(:undo, fn data ->
          Durable.IntegrationProbe.note(:undo_second_fails)
          {:ok, data}
        end)
      end
    end

    test "two workflows in one module that share step names each run their own bodies" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(SharedNames, %{}, workflow: "a_second")

      run = await_status(id, :completed)

      assert run.context["ran"] == "second"
      assert run.context["picked"] == "second"
    end

    test "two workflows in one module that share a compensation name each run their own" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(SharedNames, %{}, workflow: "a_second_fails")

      run = await_status(id, :compensated)

      assert run.error["message"] == "second"
      assert Probe.hits(:undo_second_fails) == 1
    end

    test "a step name used twice in one workflow doesn't compile" do
      code = """
      defmodule Durable.Integration.AuditRegressionsTest.TwiceInOne do
        use Durable

        workflow "a_twice" do
          step(:work, fn data -> {:ok, data} end)
          step(:work, fn data -> {:ok, data} end)
        end
      end
      """

      error = assert_raise CompileError, fn -> Code.compile_string(code) end
      assert error.description =~ "work"
    end
  end

  describe "branch patterns" do
    defmodule Negative do
      use Durable

      workflow "a_negative" do
        branch on: fn data -> data["n"] end do
          -1 -> step(:minus_one, fn data -> {:ok, Map.put(data, "took", "minus_one")} end)
          _ -> step(:other, fn data -> {:ok, Map.put(data, "took", "other")} end)
        end
      end
    end

    test "a negative integer clause matches" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Negative, %{"n" => -1})

      assert await_status(id, :completed).context["took"] == "minus_one"
    end

    test "a clause pattern a branch can't match on doesn't compile" do
      for pattern <- ["1.5", "{:ok, _}", "%{}"] do
        code = """
        defmodule Durable.Integration.AuditRegressionsTest.Pattern#{System.unique_integer([:positive])} do
          use Durable

          workflow "a_pattern" do
            branch on: fn data -> data["n"] end do
              #{pattern} -> step(:this, fn data -> {:ok, data} end)
              _ -> step(:other, fn data -> {:ok, data} end)
            end
          end
        end
        """

        error = assert_raise CompileError, fn -> Code.compile_string(code) end
        assert error.description =~ "branch"
      end
    end
  end

  # #36.2
  describe "an every-hour cron limited to some days" do
    defp use_fold(transition) do
      previous = Calendar.get_time_zone_database()
      Fold.set_transition(transition)
      Calendar.put_time_zone_database(Fold)
      on_exit(fn -> Calendar.put_time_zone_database(previous) end)
    end

    test "fires at local midnight of its day when the clocks change before then" do
      now = DateTime.utc_now()
      use_fold(DateTime.add(now, 86_400))
      Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)

      day = now |> DateTime.shift_zone!("Test/Fold") |> DateTime.to_date() |> Date.add(2)
      cron = "0 * * * #{rem(Date.day_of_week(day), 7)}"

      {:ok, schedule} = API.schedule(Tick, cron, name: "hourly_on_a_day", timezone: "Test/Fold")
      [preview | _] = API.upcoming_runs(schedule, 1)

      # Midnight at UTC-5, the offset in force on that day.
      midnight = DateTime.new!(day, ~T[05:00:00.000000], "Etc/UTC")

      assert schedule.next_run_at == midnight
      assert preview == midnight
    end

    test "still fires through the hour the clocks repeat" do
      now = DateTime.utc_now()
      next_minute = %{DateTime.add(now, 60, :second) | second: 0, microsecond: {0, 6}}
      use_fold(next_minute)
      Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)

      day = now |> DateTime.shift_zone!("Test/Fold") |> DateTime.to_date()
      cron = "* * * * #{rem(Date.day_of_week(day), 7)}"

      {:ok, schedule} = API.schedule(Tick, cron, name: "minutely_on_a_day", timezone: "Test/Fold")

      assert DateTime.diff(schedule.next_run_at, now, :second) in 0..120
    end
  end
end
