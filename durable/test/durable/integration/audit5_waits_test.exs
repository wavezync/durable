defmodule Durable.Integration.Audit5WaitsTest do
  @moduledoc """
  Waits against a process that dies at the worst moment, on live pollers.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 60_000

  alias Durable.Queue.StaleJobRecovery
  alias Durable.Storage.Schemas.{PendingEvent, ScheduledWorkflow}
  alias Durable.Wait.TimeoutWorker

  # The carrier's webhook can arrive before the run has got to its wait.
  defmodule Audit5WaitsDelivery do
    use Durable
    use Durable.Wait

    alias Durable.IntegrationProbe, as: Probe

    workflow "audit5_waits_delivery" do
      step :book_courier, fn data ->
        Probe.wait_for(:booked)
        {:ok, data}
      end

      step :await_delivery, fn data ->
        {:ok, Map.put(data, "delivery", wait_for_event("shipment.delivered"))}
      end
    end
  end

  # A refund needs a manager's approval within the run's hour.
  defmodule Audit5WaitsRefund do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_refund", timeout: 3_600_000 do
      step :approve, fn data ->
        {:ok, Map.put(data, "approval", wait_for_input("refund_approval"))}
      end
    end
  end

  # The process running `id`'s step: the executor's task under its worker.
  defp task_of(id) do
    Enum.filter(Process.list(), fn pid ->
      match?({:dictionary, %{durable_workflow_id: ^id}}, dictionary(pid))
    end)
  end

  defp dictionary(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> {:dictionary, Map.new(dict)}
      nil -> nil
    end
  end

  # The backends of this database waiting on a row lock to write `table`.
  defp blocked(table, select) do
    IntegrationRepo.query!(
      """
      SELECT #{select} FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
      WHERE NOT l.granted AND a.datname = current_database() AND a.query LIKE $1
      """,
      ["%#{table}%"]
    ).rows
  end

  defp blocked_on?(table), do: blocked(table, "a.pid") != []

  # Its connection goes, as in a network blip: what it was doing is undone.
  defp terminate_blocked!(table), do: [[true]] = blocked(table, "pg_terminate_backend(a.pid)")

  # Holds the run's rows of `table` with `status` locked until told to let go.
  defp hold(table, id, status) do
    test = self()

    holder =
      spawn(fn ->
        IntegrationRepo.transaction(fn ->
          IntegrationRepo.query!(
            "SELECT id FROM durable.#{table} WHERE workflow_id = $1 AND status = $2 FOR UPDATE",
            [Ecto.UUID.dump!(id), status]
          )

          send(test, :held)
          receive do: (:let_go -> :ok)
        end)
      end)

    assert_receive :held, 5_000
    holder
  end

  describe "an event kept for a run that dies reaching its wait" do
    test "still reaches the run" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Audit5WaitsDelivery, %{"order" => "A-1001"})
      await_status(id, :running)

      delivered = %{"signed_by" => "R. Diaz"}
      assert Durable.send_event(id, "shipment.delivered", delivered, buffer: true) == :ok

      # The run reaches its wait and hands itself the kept event, which this
      # test holds locked: the worker is caught between the two.
      holder = hold("pending_events", id, "buffered")
      Probe.set(:booked)
      assert_eventually(fn -> blocked_on?("pending_events") end, 5_000, 10)

      [task] = task_of(id)
      Process.exit(task, :kill)
      send(holder, :let_go)

      # Nothing else is coming for it: no timeout, and the sweeps leave a run
      # that has a wait open.
      StaleJobRecovery.recover_now(Durable)
      run = await_status(id, :completed, 15_000)
      assert run.context["delivery"] == delivered

      events = IntegrationRepo.all(from(p in PendingEvent, select: p.status))
      assert events == [:received]
    end
  end

  describe "a waiting run past its deadline, its sweep's connection lost between its writes" do
    test "can be retried and answered" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Audit5WaitsRefund, %{"order" => "A-1002"})
      await_status(id, :waiting)
      expire!(id)

      # The sweep wakes the run and then closes its wait, which this test
      # holds locked: the sweep is caught between the two, and its connection
      # goes there.
      holder = hold("pending_inputs", id, "pending")
      TimeoutWorker.check_timeouts(Durable)
      assert_eventually(fn -> blocked_on?("pending_inputs") end, 5_000, 10)
      terminate_blocked!("pending_inputs")
      send(holder, :let_go)

      TimeoutWorker.check_timeouts(Durable)
      assert await_status(id, :failed).error["type"] == "timeout"

      {:ok, ^id} = Durable.retry(id)
      await_status(id, :waiting)
      assert Durable.provide_input(id, "refund_approval", %{"approved" => true}) == :ok
      assert await_status(id, :completed).context["approval"] == %{"approved" => true}
    end
  end

  defmodule Audit5WaitsNightlyReport do
    use Durable

    workflow "audit5_waits_nightly_report" do
      step :build, fn report -> {:ok, report} end
    end
  end

  # Stops a scheduler between reading the schedules that are due and acting on
  # them, until the test lets it go on.
  def hold_tick(_event, _measurements, %{query: query, result: {:ok, %{num_rows: rows}}}, _)
      when rows > 0 do
    if query =~ ~s(FROM "durable"."scheduled_workflows") and query =~ ~s("next_run_at" <=) do
      Probe.note(:tick_loaded)
      Probe.wait_for(:tick_goes_on)
    end
  end

  def hold_tick(_event, _measurements, _metadata, _config), do: :ok

  describe "a schedule's fire that fails" do
    setup do
      start_durable!(%{default: 1}, scheduler_interval: :timer.hours(1))

      :telemetry.attach(
        "a5-hold-tick",
        [:durable, :integration_repo, :query],
        &__MODULE__.hold_tick/4,
        nil
      )

      on_exit(fn -> :telemetry.detach("a5-hold-tick") end)

      # The report was set to a time zone the server doesn't know, and has
      # failed to fire four times.
      {:ok, schedule} =
        Durable.schedule(Audit5WaitsNightlyReport, "0 2 * * *", name: "nightly_report")

      {1, _} =
        IntegrationRepo.update_all(from(s in ScheduledWorkflow, where: s.id == ^schedule.id),
          set: [
            timezone: "Nowhere/Land",
            consecutive_failures: 4,
            next_run_at: DateTime.add(DateTime.utc_now(), -5, :second)
          ]
        )

      :ok
    end

    defp nightly_report, do: IntegrationRepo.get_by!(ScheduledWorkflow, name: "nightly_report")

    defp let_ticks_finish(schedulers) do
      Probe.set(:tick_goes_on)
      for scheduler <- schedulers, do: Durable.Scheduler.status(scheduler)
    end

    test "doesn't undo what an operator changed while the tick was failing" do
      Durable.Scheduler.check_schedules(Durable)
      assert_eventually(fn -> Probe.hits(:tick_loaded) == 1 end)

      # The operator sees the error and fixes the time zone, before the tick
      # that read the broken schedule has written its failure.
      {:ok, fixed} = Durable.update_schedule("nightly_report", timezone: "Etc/UTC")
      let_ticks_finish([Durable])

      row = nightly_report()
      assert row.enabled, "the schedule the operator just fixed was turned off"
      assert row.next_run_at == fixed.next_run_at
      assert {row.consecutive_failures, row.auto_disabled_at} == {4, nil}
    end

    test "is counted once when two nodes fail it in the same tick" do
      other = %{Durable.Config.get(Durable) | name: Audit5WaitsOtherNode}
      start_supervised!({Durable.Scheduler, config: other, interval: :timer.hours(1)})

      for node <- [Durable, Audit5WaitsOtherNode], do: Durable.Scheduler.check_schedules(node)
      assert_eventually(fn -> Probe.hits(:tick_loaded) == 2 end)
      let_ticks_finish([Durable, Audit5WaitsOtherNode])

      row = nightly_report()
      assert {row.consecutive_failures, row.enabled} == {5, false}
      assert %DateTime{} = row.auto_disabled_at

      # One failure, and one record that it turned the schedule off.
      assert [%{details: %{"failures" => 5}}] =
               Durable.Activity.list!(kinds: ["schedule_disabled"])
    end
  end
end
