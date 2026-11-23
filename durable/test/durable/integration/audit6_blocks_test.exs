defmodule Audit6BlocksClaim do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The assessor is booked while the policy is looked up. Closing the claim
  # stands the assessor down if one was booked, as the parallel guide says to.
  # A failure halts: an operator decides whether to undo.
  workflow "audit6_claim" do
    step :open_claim, [compensate: :close_claim], fn claim -> {:ok, claim} end

    parallel :checks do
      step :policy, fn _claim ->
        Process.sleep(50)
        {:error, "no such policy"}
      end

      step :assessor, fn claim ->
        Process.sleep(300)
        Probe.note(:assessor_booked)
        {:ok, claim}
      end
    end

    compensate :close_claim, fn claim ->
      Probe.note({:closed_with_assessor_booked, Probe.hits(:assessor_booked)})
      {:ok, claim}
    end
  end
end

defmodule Audit6BlocksQuotes do
  @moduledoc false
  use Durable
  use Durable.Helpers
  alias Durable.IntegrationProbe, as: Probe

  # Two carriers quote at once and the step after picks from whatever came
  # back. DHL is down until someone says it's back; UPS is slow.
  workflow "audit6_quotes" do
    parallel :rates, on_error: :collect do
      step :dhl, fn order ->
        if Probe.set?(:dhl_up) do
          Probe.wait_for(:dhl_go)
          Probe.note(:dhl_quoted)
          {:ok, assign(order, :price, 12)}
        else
          {:fail, "DHL is down"}
        end
      end

      step :ups, fn order ->
        Probe.wait_for(:ups_go)
        {:ok, assign(order, :price, 14)}
      end
    end

    step :pick, fn order ->
      Probe.put(:handed, Map.new(order["rates"], fn {lane, {how, _}} -> {lane, how} end))
      {:ok, order}
    end
  end
end

defmodule Audit6BlocksTrip do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # A seat is held, then the flight booked. Cancelling the trip undoes both:
  # each undo needs what its step left, the trip and the flight's number.
  workflow "audit6_trip" do
    step :hold_seat, [compensate: :release_seat], fn trip ->
      Probe.note(:holding)
      if trip["slow"] == "hold", do: Process.sleep(400)
      {:ok, Map.put(trip, "seat", "S-#{trip["trip"]}")}
    end

    step :book_flight, [compensate: :cancel_flight], fn trip ->
      Probe.note(:booking)
      if trip["slow"] == "book", do: Process.sleep(400)
      {:ok, Map.put(trip, "flight", "F-#{trip["trip"]}")}
    end

    step :pay, fn trip -> {:ok, trip} end

    compensate :release_seat, fn trip ->
      Probe.put(:released, {trip["trip"], trip["seat"]})
      {:ok, trip}
    end

    compensate :cancel_flight, fn trip ->
      Probe.put(:cancelled, {trip["trip"], trip["flight"]})
      {:ok, trip}
    end
  end
end

defmodule Durable.Integration.Audit6BlocksTest do
  @moduledoc """
  Audit 6: parallel blocks, children and rollbacks with live pollers, raced
  against operators.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  defp lanes(id),
    do: IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^id))

  defp lane(id, name),
    do: Enum.find(lanes(id), &(&1.engine_state["__parallel_step"] == "rates__#{name}"))

  # A lane that fails stops the others at their workers' next heartbeat, and
  # until then a step of theirs can still finish. `Durable.rollback/2` asked
  # straight after the failure undid the run at once, before the stopped lane's
  # step landed: the compensation looked for an assessor not yet booked.
  test "a rollback asked for as a block fails waits for its stopped lanes" do
    start_durable!(%{default: 4}, heartbeat_interval: 1_000)

    {:ok, id} = Durable.start(Audit6BlocksClaim, %{})
    await_status(id, :failed)

    assert {:ok, ^id} = Durable.rollback(id)
    await_status(id, :compensated, 5_000)
    assert_eventually(fn -> Probe.hits(:assessor_booked) == 1 end)
    Process.sleep(200)

    assert Probe.hits({:closed_with_assessor_booked, 1}) == 1,
           "undone before the stopped lane's step finished: #{inspect(Probe.log())}"
  end

  # A lane that failed in a block that collects has told its block. Retried by
  # its own id while the block still waited on the other lane, its failure
  # stayed the block's answer: the block went on as soon as the other lane
  # finished, handed the retried lane as not finished, and the lane ran on
  # after its run had completed.
  test "a lane retried by its own id while its block waits is waited for" do
    start_durable!(%{default: 4})

    {:ok, id} = Durable.start(Audit6BlocksQuotes, %{})
    assert_eventually(fn -> match?(%{status: :failed}, lane(id, :dhl)) end)
    assert get(id).status == :waiting

    Probe.set(:dhl_up)
    {:ok, _} = Durable.retry(lane(id, :dhl).id)
    assert_eventually(fn -> lane(id, :dhl).status == :running end)

    # UPS answers while DHL's retry is still asking.
    Probe.set(:ups_go)
    assert_eventually(fn -> lane(id, :ups).status == :completed end)
    Process.sleep(300)

    refute get(id).status == :completed,
           "the block went on without its retried lane: #{inspect(Probe.fetch_or(:handed, nil))}"

    Probe.set(:dhl_go)
    await_status(id, :completed)
    assert Probe.fetch(:handed) == %{"dhl" => :ok, "ups" => :ok}
  end

  # A cancel with `rollback: true` leaves the step its worker is running open:
  # finished before the worker hears, it is undone with the rest. Its result
  # was never saved (the cancel fenced the save), so its undo was handed the
  # data from before it: no flight to cancel. And a run cancelled in its first
  # step had saved nothing at all, so that undo was handed nothing, not even
  # the run's input.
  for {slow, undo, wanted} <- [
        {"hold", :released, {7, "S-7"}},
        {"book", :cancelled, {7, "F-7"}}
      ] do
    test "a step that finishes after a cancel with rollback is undone with its result (#{slow})" do
      start_durable!(%{default: 2}, heartbeat_interval: 2_000)
      slow = unquote(slow)

      {:ok, id} = Durable.start(Audit6BlocksTrip, %{"trip" => 7, "slow" => slow})
      started = if slow == "hold", do: :holding, else: :booking
      assert_eventually(fn -> Probe.hits(started) == 1 end)

      :ok = Durable.cancel(id, "the traveller changed plans", rollback: true)
      await_status(id, :compensated, 10_000)

      assert Probe.fetch_or(unquote(undo), nil) == unquote(Macro.escape(wanted))
    end
  end
end
