defmodule Durable.Integration.RegressionsRollbackTest do
  @moduledoc "Rollbacks meeting a dead worker, the sweep and workflow keys, with live pollers."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.IntegrationProbe, as: Probe
  alias Durable.Wait.TimeoutWorker

  defmodule Delivery do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    # The depot is asked twice. The second answer is final: the slot is gone.
    workflow "rb_delivery" do
      step(:reserve_van, [compensate: :release_van], fn order -> {:ok, order} end)

      step(:confirm_slot, [retry: [max_attempts: 2, backoff: :constant, base: 30]], fn _order ->
        case Probe.note({:confirm, Durable.Context.workflow_id()}) do
          1 -> {:error, "depot didn't answer"}
          _ -> {:rollback, "the slot is gone"}
        end
      end)

      # The first release takes its process down with it, as a node going would.
      compensate(:release_van, fn order ->
        if Probe.note({:release, Durable.Context.workflow_id()}) == 1,
          do: Process.exit(self(), :kill)

        {:ok, order}
      end)
    end
  end

  defmodule Booking do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    # The seat is held while the traveller confirms, and only then paid for.
    workflow "rb_booking" do
      step(:hold_seat, [compensate: :release_seat], fn trip -> {:ok, trip} end)

      step(:confirm, fn trip ->
        Probe.note({:ask, Durable.Context.workflow_id()})
        wait_for_input("confirmation")
        {:ok, trip}
      end)

      step(:charge_card, fn trip -> {:ok, trip} end)

      compensate(:release_seat, fn trip ->
        Probe.note({:release, Durable.Context.workflow_id()})
        {:ok, trip}
      end)
    end
  end

  defmodule Claim do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    # The assessor is booked while the policy is looked up. Closing the claim
    # stands the assessor down if one was booked, as the parallel guide says to.
    workflow "rb_claim", on_failure: :rollback do
      step(:open_claim, [compensate: :close_claim], fn claim -> {:ok, claim} end)

      parallel :checks do
        step(:policy, fn _claim ->
          Process.sleep(50)
          {:error, "no such policy"}
        end)

        step(:assessor, fn claim ->
          Process.sleep(300)
          Probe.note(:assessor_booked)
          {:ok, claim}
        end)
      end

      compensate(:close_claim, fn claim ->
        Probe.note({:closed_with_assessor_booked, Probe.hits(:assessor_booked)})
        {:ok, claim}
      end)
    end
  end

  defmodule Repair do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    # The garage is booked while the job is open. Closing the job cancels the
    # garage if one was booked.
    workflow "rb_repair" do
      step(:open_job, [compensate: :close_job], fn job -> {:ok, job} end)

      parallel :bookings do
        step(:garage, fn job ->
          Process.sleep(300)
          Probe.note(:garage_booked)
          {:ok, job}
        end)
      end

      compensate(:close_job, fn job ->
        Probe.note({:closed_with_garage_booked, Probe.hits(:garage_booked)})
        {:ok, job}
      end)
    end
  end

  # Kills the worker's task as it reads which steps to undo: after it has
  # been handed the rollback, before it has undone anything.
  def kill_reading_what_to_undo(_event, _measurements, %{query: query}, _config) do
    if query =~ ~s("is_compensation" = FALSE) and not Probe.set?(:killed) do
      Probe.set(:killed)
      Process.exit(self(), :kill)
    end
  end

  defp kill_worker_reading_what_to_undo do
    :telemetry.attach(
      "rb-kill",
      [:durable, :integration_repo, :query],
      &__MODULE__.kill_reading_what_to_undo/4,
      nil
    )

    on_exit(fn -> :telemetry.detach("rb-kill") end)
  end

  defp sweep do
    TimeoutWorker.check_timeouts(Durable)
    :sys.get_state(TimeoutWorker.worker_name(Durable))
  end

  test "a run left failed by a compensation that died isn't rolled back by the sweep" do
    start_durable!(%{default: 2})

    {:ok, id} = Durable.start(Delivery, %{})
    run = await_status(id, :failed)

    assert run.error["type"] == "task_crash"
    assert Probe.hits({:release, id}) == 1

    sweep()
    Process.sleep(200)

    assert get(id).status == :failed
    assert Probe.hits({:release, id}) == 1
    # What the retry's backoff left behind isn't a time to roll back at.
    assert get(id).scheduled_at == nil
  end

  # A lane that fails stops the others at their workers' next heartbeat, and
  # until then a step of theirs can still finish. The undo waits that long, or
  # the step's effect would land after the compensation looked for it.
  test "a run isn't undone while a stopped lane's step can still finish" do
    start_durable!(%{default: 4}, heartbeat_interval: 1_000)

    {:ok, id} = Durable.start(Claim, %{})
    await_status(id, :compensated)
    Process.sleep(500)

    assert Probe.hits(:assessor_booked) == Probe.hits({:closed_with_assessor_booked, 1})
  end

  test "a cancelled run isn't undone while a lane's step can still finish" do
    start_durable!(%{default: 4}, heartbeat_interval: 1_000)

    {:ok, id} = Durable.start(Repair, %{})
    await_status(id, :waiting)
    Process.sleep(100)

    :ok = Durable.cancel(id, "the customer withdrew", rollback: true)
    await_status(id, :compensated)
    Process.sleep(500)

    assert Probe.hits(:garage_booked) == Probe.hits({:closed_with_garage_booked, 1})
  end

  test "a cancelled run whose worker dies as its rollback starts doesn't carry on with its steps" do
    start_durable!(%{default: 2})

    {:ok, id} = Durable.start(Booking, %{})
    await_status(id, :waiting)

    kill_worker_reading_what_to_undo()
    :ok = Durable.cancel(id, "traveller walked away", rollback: true)
    assert_eventually(fn -> Probe.set?(:killed) end)

    # The run is over, whoever finishes undoing it: nobody is asked to confirm
    # a cancelled booking, and no answer could get its card charged.
    assert_eventually(fn -> get(id).status not in [:pending, :running, :compensating] end)
    Process.sleep(200)

    assert Probe.hits({:ask, id}) == 1
    assert Durable.provide_input(id, "confirmation", %{}) != :ok
    run = get(id)
    assert run.status == :failed
    refute Map.has_key?(run.context, "__rollback__")

    # What it held can still be released.
    assert {:ok, ^id} = Durable.rollback(id)
    await_status(id, :compensated)
    assert Probe.hits({:release, id}) == 1
  end
end
