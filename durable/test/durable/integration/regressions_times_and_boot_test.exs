defmodule Durable.Integration.TimesAndBootRegressionsTest do
  @moduledoc "Exact-time sleeps, time zone helpers, booting with a broken schedule or database, and very large log metadata."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 120_000

  alias Durable.Scheduler
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.ScheduledWorkflow
  alias Durable.Wait.SleepWaker

  defmodule DownRepo do
    use Ecto.Repo, otp_app: :durable, adapter: Ecto.Adapters.Postgres
  end

  defmodule SleepsUntil do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_sleeps_until" do
      step(:w, fn data ->
        Probe.note(:body)
        schedule_at(~U[2099-12-25 00:00:00Z])
        {:ok, data}
      end)
    end
  end

  defmodule BigMetadata do
    use Durable
    alias Durable.IntegrationProbe, as: Probe
    require Logger

    workflow "r_big_metadata" do
      step(:w, fn data ->
        big = String.duplicate("x", 1_048_576)
        # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
        for i <- 1..300, do: Logger.info("line #{i}", payload: big)
        Probe.note(:finished_body)
        {:ok, data}
      end)
    end
  end

  defmodule Declares do
    use Durable
    use Durable.Scheduler.DSL

    @schedule cron: "0 9 * * *"
    workflow "r_declares" do
      step(:work, fn data -> {:ok, data} end)
    end
  end

  defp step_rows(id) do
    IntegrationRepo.all(
      from(s in StepExecution, where: s.workflow_id == ^id, order_by: s.inserted_at)
    )
  end

  test "schedule_at with the guide's literal datetime sleeps until then" do
    start_durable!(%{default: 1})
    {:ok, id} = Durable.start(SleepsUntil, %{})
    assert_eventually(fn -> Probe.hits(:body) >= 1 end)
    Process.sleep(500)
    run = get(id)

    assert run.status == :waiting
  end

  defmodule Fixed do
    @behaviour Calendar.TimeZoneDatabase
    @minus5 %{utc_offset: -18_000, std_offset: 0, zone_abbr: "TST"}
    @utc %{utc_offset: 0, std_offset: 0, zone_abbr: "UTC"}

    @impl true
    def time_zone_period_from_utc_iso_days(_, "Test/Minus5"), do: {:ok, @minus5}
    def time_zone_period_from_utc_iso_days(_, "Etc/UTC"), do: {:ok, @utc}
    def time_zone_period_from_utc_iso_days(_, _), do: {:error, :time_zone_not_found}

    @impl true
    def time_zone_periods_from_wall_datetime(_, "Test/Minus5"), do: {:ok, @minus5}
    def time_zone_periods_from_wall_datetime(_, "Etc/UTC"), do: {:ok, @utc}
    def time_zone_periods_from_wall_datetime(_, _), do: {:error, :time_zone_not_found}
  end

  test "next_business_day honours its documented :timezone" do
    previous = Calendar.get_time_zone_database()
    Calendar.put_time_zone_database(Fixed)
    on_exit(fn -> Calendar.put_time_zone_database(previous) end)

    assert %{hour: 9, minute: 0} = Durable.Wait.next_business_day(hour: 9)

    assert %{hour: 14, minute: 0} =
             Durable.Wait.next_business_day(hour: 9, timezone: "Test/Minus5")

    assert %{hour: 14} = Durable.Wait.next_weekday(:monday, hour: 9, timezone: "Test/Minus5")
    assert %{hour: 4, minute: 59} = Durable.Wait.end_of_day(timezone: "Test/Minus5")
  end

  describe "registering schedules at boot" do
    # Good on both sides of the bad one, whichever order they're registered in.
    defmodule DeclaresBadThenGood do
      use Durable
      use Durable.Scheduler.DSL

      @schedule cron: "0 8 * * *", workflow: "r_early", name: "early_good"
      workflow "r_early" do
        step(:work, fn data -> {:ok, data} end)
      end

      @schedule cron: "0 0 31 2 *", workflow: "r_never", name: "never"
      workflow "r_never" do
        step(:work, fn data -> {:ok, data} end)
      end

      @schedule cron: "0 9 * * *", workflow: "r_daily", name: "daily_good"
      workflow "r_daily" do
        step(:work, fn data -> {:ok, data} end)
      end
    end

    test "carries on past a schedule that can never fire" do
      start_durable!(%{default: 1}, scheduled_modules: [DeclaresBadThenGood])

      assert {:ok, _} = API.get_schedule("early_good")
      assert {:ok, _} = API.get_schedule("daily_good")
    end

    test "tries again on a later check if the database wasn't there" do
      start_durable!(%{default: 1})
      scheduler = Process.whereis(Scheduler.scheduler_name(Durable))

      :sys.replace_state(scheduler, fn state ->
        %{state | registered: false, scheduled_modules: [Declares]}
      end)

      send(scheduler, :check)
      assert %{registered: true} = :sys.get_state(scheduler)
      assert [_ | _] = API.list_schedules()
    end
  end

  test "a database that's down at boot doesn't stop the app starting" do
    config =
      :durable
      |> Application.fetch_env!(IntegrationRepo)
      |> Keyword.merge(port: 1, pool_size: 1, queue_target: 10, queue_interval: 100)

    Application.put_env(:durable, DownRepo, config)
    start_supervised!(DownRepo)

    result =
      start_supervised(
        {Durable,
         name: Durable,
         repo: DownRepo,
         queues: %{default: [concurrency: 1]},
         scheduled_modules: [Declares]}
      )

    assert match?({:ok, _}, result)
  end

  test "huge metadata can't cost a step its result" do
    start_durable!(%{default: 1})
    {:ok, id} = Durable.start(BigMetadata, %{})
    assert_eventually(fn -> Probe.hits(:finished_body) == 1 end, 30_000)
    assert_eventually(fn -> get(id).status != :running end, 60_000)
    run = get(id)

    assert run.status == :completed
  end

  test "one failure after a re-enable isn't reported as a disable" do
    start_durable!(%{other: 1})
    {:ok, s} = API.schedule(Declares, "* * * * *", name: "ad")

    {1, _} =
      IntegrationRepo.update_all(from(x in ScheduledWorkflow, where: x.id == ^s.id),
        set: [
          enabled: false,
          consecutive_failures: 5,
          auto_disabled_at: DateTime.utc_now(),
          last_error: "boom"
        ]
      )

    {:ok, _} = API.enable_schedule("ad")
    make_due = DateTime.add(DateTime.utc_now(), -5, :second)

    {1, _} =
      IntegrationRepo.update_all(from(x in ScheduledWorkflow, where: x.id == ^s.id),
        set: [next_run_at: make_due]
      )

    Scheduler.check_schedules(Durable)
    Scheduler.status(Durable)

    {1, _} =
      IntegrationRepo.update_all(from(x in ScheduledWorkflow, where: x.id == ^s.id),
        set: [next_run_at: make_due, workflow_module: "Elixir.Does.Not.Exist.Anywhere"]
      )

    Scheduler.check_schedules(Durable)
    Scheduler.status(Durable)
    row = IntegrationRepo.get!(ScheduledWorkflow, s.id)

    disabled =
      Enum.filter(
        Durable.Activity.list(kinds: ["schedule_disabled"]),
        &(&1.details["schedule"] == "ad")
      )

    assert disabled == []
  end
end
