defmodule Durable.Integration.ChildrenAndSchedulesRegressionsTest do
  @moduledoc "Child runs that time out or get pruned, cancel closing a run's waits, and schedules across a clock change."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 60_000

  alias Durable.Scheduler
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, ScheduledWorkflow}
  alias Durable.Wait.TimeoutWorker

  defmodule SlowChild do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_slow_child" do
      step(:w, fn data ->
        Probe.note(:child)
        Probe.wait_for(:never)
        {:ok, data}
      end)
    end
  end

  defmodule CallsChild do
    use Durable
    use Durable.Orchestration
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_calls_child" do
      step(:w, fn data ->
        Probe.note(:parent)
        result = call_workflow(SlowChild, %{}, timeout: 100, timeout_value: :gave_up)
        Probe.put(:call_result, result)
        {:ok, Map.put(data, "result", inspect(result))}
      end)
    end
  end

  defmodule Branched do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_branched" do
      parallel do
        step(:fast, fn data -> {:ok, Map.put(data, "fast", 1)} end)

        step(:slow, fn data ->
          Probe.note(:slow)
          Probe.wait_for(:finish_slow)
          {:ok, Map.put(data, "slow", 1)}
        end)
      end

      step(:after, fn data ->
        Probe.put(:after_data, Map.keys(data))
        {:ok, data}
      end)
    end
  end

  defmodule AsksInput do
    use Durable
    use Durable.Wait

    workflow "r_c_asks_input" do
      step(:w, fn data ->
        r = wait_for_input("answer")
        {:ok, Map.put(data, "result", inspect(r))}
      end)
    end
  end

  defmodule Collides do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_collides" do
      step(:first, fn data -> {:ok, Map.put(data, :approved, false)} end)

      step(:w, fn data ->
        Probe.note(:body)
        got = wait_for_event("approved")
        Probe.put(:got, got)
        {:ok, data}
      end)
    end
  end

  defmodule AnyOfNothing do
    use Durable
    use Durable.Wait

    workflow "r_any_of_nothing" do
      step(:w, fn data ->
        wait_for_any([])
        {:ok, data}
      end)
    end
  end

  defmodule Tick do
    use Durable

    workflow "r_c_tick" do
      step(:work, fn data -> {:ok, data} end)
    end
  end

  defmodule Fold do
    @moduledoc false
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

  defp expire_waits!(id) do
    for schema <- [PendingEvent, PendingInput] do
      IntegrationRepo.update_all(
        from(p in schema, where: p.workflow_id == ^id and p.status == :pending),
        set: [timeout_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )
    end

    TimeoutWorker.check_timeouts(Durable)
  end

  defp idle_durable! do
    Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)
  end

  test "call_workflow timeout returns {:ok, timeout_value}, as the guide says" do
    start_durable!(%{default: 4})
    {:ok, id} = Durable.start(CallsChild, %{})
    await_status(id, :waiting)
    assert_eventually(fn -> Probe.hits(:child) == 1 end)
    Process.sleep(150)
    expire_waits!(id)
    assert_eventually(fn -> get(id).status in [:completed, :failed] end, 5_000)
    result = Probe.fetch(:call_result)

    assert result == {:ok, :gave_up}
  end

  test "a finished branch pruned while its sibling is still going doesn't fail the fan-in" do
    start_durable!(%{default: 4}, prune: [completed: :timer.hours(1)])
    {:ok, id} = Durable.start(Branched, %{})
    assert_eventually(fn -> Probe.hits(:slow) == 1 end)

    [fast] =
      IntegrationRepo.all(
        from(w in WorkflowExecution,
          where: w.parent_workflow_id == ^id and w.status == :completed
        )
      )

    # An hour on.
    {1, _} =
      IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^fast.id),
        set: [completed_at: DateTime.add(DateTime.utc_now(), -2 * 3600, :second)]
      )

    deleted = Durable.prune()
    assert deleted.completed == 0
    :ok = Probe.set(:finish_slow)
    assert_eventually(fn -> get(id).status in [:completed, :failed] end, 5_000)
    run = get(id)
    assert run.status == :completed
  end

  test "cancel closes the run's pending input" do
    start_durable!(%{default: 2})
    {:ok, id} = Durable.start(AsksInput, %{})
    await_status(id, :waiting)
    :ok = Durable.cancel(id, "changed my mind")

    [input] = IntegrationRepo.all(from(p in PendingInput, where: p.workflow_id == ^id))
    inbox = Durable.Wait.list_pending_inputs() |> Enum.map(& &1.workflow_id)
    answer = Durable.provide_input(id, "answer", %{"late" => true})
    [after_answer] = IntegrationRepo.all(from(p in PendingInput, where: p.workflow_id == ^id))

    refute id in inbox
    assert input.status == :cancelled
    assert answer == {:error, :not_found}
    assert after_answer.status == :cancelled
  end

  test "an event name equal to a data key still waits" do
    start_durable!(%{default: 2})
    {:ok, id} = Durable.start(Collides, %{})
    Process.sleep(600)
    run = get(id)
    assert run.status == :waiting
    assert Probe.hits(:body) == 1
  end

  test "wait_for_any([]) doesn't wait on nothing" do
    start_durable!(%{default: 2})
    {:ok, id} = Durable.start(AnyOfNothing, %{})
    Process.sleep(500)
    refute get(id).status == :waiting
  end

  for {label, input} <- [{"tuple", %{"a" => {1, 2}}}, {"pid", %{"a" => :pid_here}}] do
    @label label
    @input input
    test "schedule/3 takes an input start/3 would take (#{label})" do
      idle_durable!()
      input = if @label == "pid", do: %{"a" => self()}, else: @input

      started =
        try do
          Durable.start(Tick, input)
        rescue
          e -> {:raised, e.__struct__}
        end

      scheduled =
        try do
          API.schedule(Tick, "* * * * *", name: "h_#{@label}", input: input)
        rescue
          e -> {:raised, e.__struct__}
        end

      assert match?({:ok, _}, started)
      assert match?({:ok, _}, scheduled)
    end
  end

  test "a daily schedule made in the repeated hour fires once" do
    previous = Calendar.get_time_zone_database()
    now = DateTime.utc_now()
    Fold.set_transition(DateTime.add(now, -1_800, :second))
    Calendar.put_time_zone_database(Fold)
    on_exit(fn -> Calendar.put_time_zone_database(previous) end)

    start_durable!(%{other: 1})

    # Ten minutes ahead on the local clock, inside the repeated hour.
    local = DateTime.add(now, -5 * 3600 + 600, :second)
    cron = "#{local.minute} #{local.hour} * * *"
    {:ok, s} = API.schedule(Tick, cron, name: "daily", timezone: "Test/Fold")

    for _ <- 1..5 do
      Scheduler.check_schedules(Durable)
      Scheduler.status(Durable)
      Process.sleep(10)
    end

    runs =
      IntegrationRepo.aggregate(
        from(w in WorkflowExecution, where: w.workflow_name == "r_c_tick"),
        :count
      )

    row = IntegrationRepo.get!(ScheduledWorkflow, s.id)

    # Not due for ten minutes, and then once: at the occurrence still to come.
    assert runs == 0
    assert DateTime.diff(row.next_run_at, now) in 1..600
  end
end
