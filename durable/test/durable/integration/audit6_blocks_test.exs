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
          Probe.note(:dhl_quoting)
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
      Probe.put(:rates, order["rates"])
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

defmodule Audit6BlocksCarriers do
  @moduledoc false
  use Durable
  use Durable.Helpers
  alias Durable.IntegrationProbe, as: Probe

  # Two carriers quote at once. Both are down until someone says they're back.
  workflow "audit6_carriers" do
    parallel :rates do
      step :dhl, fn order ->
        if Probe.set?(:carriers_up) do
          Probe.inside([:dhl_quoting], fn -> Process.sleep(1_000) end)
          {:ok, assign(order, :price, 12)}
        else
          {:fail, "DHL is down"}
        end
      end

      # UPS takes longer to say it's down: DHL's failure stops it.
      step :ups, fn order ->
        if Probe.set?(:carriers_up) do
          {:ok, assign(order, :price, 14)}
        else
          Process.sleep(300)
          {:fail, "UPS is down"}
        end
      end
    end
  end
end

defmodule Audit6BlocksSurvey do
  @moduledoc false
  use Durable
  use Durable.Helpers
  alias Durable.IntegrationProbe, as: Probe

  # Three surveyors visit the site at once. The last finds it can't be built
  # on, which ends the survey.
  workflow "audit6_survey" do
    parallel :visits do
      step :soil, fn site ->
        Probe.note(:soil_out)
        Probe.wait_for(:never)
        {:ok, site}
      end

      step :drainage, fn site ->
        Probe.note(:drainage_out)
        Probe.wait_for(:never)
        {:ok, site}
      end

      step :access, fn _site ->
        Probe.note(:access_out)
        Probe.wait_for(:no_access)
        {:fail, "no road to the site"}
      end
    end
  end
end

defmodule Audit6BlocksCourier do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The courier goes out and collects the parcel.
  workflow "audit6_courier" do
    step :collect, fn job ->
      Probe.set(:courier_out)
      Process.sleep(800)
      Probe.note(:collected)
      {:ok, job}
    end
  end
end

defmodule Audit6BlocksPickup do
  @moduledoc false
  use Durable
  use Durable.Orchestration
  alias Durable.IntegrationProbe, as: Probe

  # A pickup slot is booked, then stock is checked while a courier is sent.
  # No stock undoes the booking: freeing the slot needs to know whether the
  # parcel was collected.
  workflow "audit6_pickup", on_failure: :rollback do
    step :book_slot, [compensate: :free_slot], fn job -> {:ok, job} end

    parallel :prep do
      step :stock, fn _job ->
        Probe.wait_for(:courier_out)
        {:fail, "out of stock"}
      end

      step :courier, fn job ->
        case call_workflow(Audit6BlocksCourier, %{}, ref: :courier) do
          {:ok, _collected} -> {:ok, job}
          {:error, reason} -> {:error, reason}
        end
      end
    end

    compensate :free_slot, fn job ->
      Probe.note({:freed_with_collected, Probe.hits(:collected)})
      {:ok, job}
    end
  end
end

defmodule Audit6BlocksLabel do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # A label is printed, then the parcel weighed.
  workflow "audit6_label" do
    step :print, fn parcel -> {:ok, parcel} end

    step :weigh, fn parcel ->
      Probe.set(:weighing)
      Probe.wait_for(:never)
      {:ok, parcel}
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

  # Cancelled with `rollback: true`, a lane is back on its queue to be undone,
  # and then undone. A block that collects as it is meanwhile hands on the
  # cancel, not "child not finished".
  test "a lane cancelled with rollback: true is handed to its block as cancelled" do
    start_durable!(%{default: 4}, heartbeat_interval: 1_000)
    Probe.set(:dhl_up)

    {:ok, id} = Durable.start(Audit6BlocksQuotes, %{})
    assert_eventually(fn -> Probe.hits(:dhl_quoting) == 1 end)

    :ok = Durable.cancel(lane(id, :dhl).id, "quote took too long", rollback: true)
    Probe.set(:ups_go)
    await_status(id, :completed)

    assert {:error, %{"type" => "cancelled", "message" => "quote took too long"}} =
             Probe.fetch(:rates)["dhl"]
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

  # Holds the block's retry, in its own process, as it reads which lanes to
  # put back: the lane's retry lands in that window.
  def pause_reading_lanes(_event, _measurements, %{query: query}, _config) do
    if Process.get(:audit6_pause) && query =~ "!= 'completed'" && not (query =~ "count(") do
      Process.delete(:audit6_pause)
      Process.sleep(800)
    end
  end

  # The block's retry read a lane as failed and then put it back, whatever it
  # was by then. A retry of that lane by its own id in between had it claimed
  # and running: put back with its claim cleared, it was claimed a second time
  # and its step ran twice at once.
  test "a lane retried by its own id while its block is retried runs once" do
    start_durable!(%{default: 4}, heartbeat_interval: 2_000)

    {:ok, id} = Durable.start(Audit6BlocksCarriers, %{})
    await_status(id, :failed)
    dhl = Enum.find(lanes(id), &(&1.engine_state["__parallel_step"] == "rates__dhl"))
    assert dhl.status == :failed
    Probe.set(:carriers_up)

    :telemetry.attach(
      "audit6-pause",
      [:durable, :integration_repo, :query],
      &__MODULE__.pause_reading_lanes/4,
      nil
    )

    on_exit(fn -> :telemetry.detach("audit6-pause") end)

    block =
      Task.async(fn ->
        Process.put(:audit6_pause, true)
        Durable.retry(id)
      end)

    Process.sleep(200)
    # Taken after the block's retry, the lane is back to work already.
    Durable.retry(dhl.id)
    assert {:ok, ^id} = Task.await(block)

    await_status(id, :completed)

    assert {Probe.peak(:dhl_quoting), Probe.hits(:dhl_quoting)} == {1, 1},
           "DHL quoted #{Probe.hits(:dhl_quoting)} times, #{Probe.peak(:dhl_quoting)} at once"
  end

  # Holds two processes where each has done half of what it does to the
  # block's events: the cancel once it has cancelled the run, before it closes
  # the run's waits, and the failing lane's notice once it has taken its own
  # event, before it takes the others.
  def hold_halfway(_event, _measurements, %{query: query}, _config) do
    cond do
      Process.get(:audit6_cancelling) && query =~ ~s(UPDATE "durable"."step_executions") ->
        Process.delete(:audit6_cancelling)
        Process.sleep(500)

      query =~ "wait_groups" && query =~ "FOR UPDATE" && Probe.note(:notice_held) == 1 ->
        Process.sleep(1_200)

      true ->
        :ok
    end
  end

  # A cancel closed the run's waits without its row (rule 2): one statement
  # over the block's events, in the table's order. A lane's notice holds the
  # run's row and its own event, then cancels the other lanes' events. The two
  # took the events in opposite orders and deadlocked, and Postgres killed one:
  # the operator's cancel raised, its cascade undone, or the lane's notice was
  # lost with its task.
  test "a cancel racing a failing lane's notice doesn't deadlock on the block's events" do
    start_durable!(%{default: 4}, heartbeat_interval: 5_000)

    {:ok, id} = Durable.start(Audit6BlocksSurvey, %{})

    assert_eventually(fn ->
      Enum.all?([:soil_out, :drainage_out, :access_out], &(Probe.hits(&1) == 1))
    end)

    :telemetry.attach(
      "audit6-hold",
      [:durable, :integration_repo, :query],
      &__MODULE__.hold_halfway/4,
      nil
    )

    on_exit(fn -> :telemetry.detach("audit6-hold") end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        cancel =
          Task.async(fn ->
            Process.put(:audit6_cancelling, true)

            try do
              Durable.cancel(id, "the client withdrew")
            rescue
              error -> {:raised, Exception.message(error)}
            end
          end)

        Process.sleep(150)
        Probe.set(:no_access)

        assert Task.await(cancel, 15_000) == :ok
        assert_eventually(fn -> Enum.all?(lanes(id), &(&1.status in [:cancelled, :failed])) end)
        Process.sleep(500)
      end)

    assert Probe.hits(:notice_held) >= 1
    refute log =~ "deadlock", log
    assert get(id).status == :cancelled
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

  # Holds a step's task as it counts the step's attempts: after the run moved
  # to the step, before the attempt's row is written.
  def hold_before_attempt(_event, _measurements, %{query: query, params: params}, _config) do
    if query =~ "FILTER" and "weigh" in params and not Probe.set?(:held) do
      Probe.set(:held)
      Probe.wait_for(:cancelled)
    end
  end

  # Cancelled as its worker began a step, the run's next attempt was written
  # running after the cancel had closed what the run had open. The node then
  # died in the step: nobody closed the row, and no sweep looks at a cancelled
  # run's attempts. It stayed running for good.
  test "an attempt begun as its run was cancelled, on a node that then died, is closed" do
    handler = "audit6-hold-#{System.unique_integer([:positive])}"
    event = [:durable, :integration_repo, :query]
    :telemetry.attach(handler, event, &__MODULE__.hold_before_attempt/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
    start_durable!(%{default: 2}, heartbeat_interval: 5_000)

    {:ok, id} = Durable.start(Audit6BlocksLabel, %{})
    assert_eventually(fn -> Probe.set?(:held) and get(id).current_step == "weigh" end)

    :ok = Durable.cancel(id, "the order was withdrawn")
    Probe.set(:cancelled)
    assert_eventually(fn -> Probe.set?(:weighing) end)

    [{_, worker, _, _}] = DynamicSupervisor.which_children(Durable.Queue.WorkerSupervisor.Default)
    Process.exit(worker, :kill)

    running = from(s in StepExecution, where: s.workflow_id == ^id and s.status == :running)
    assert [%{step_name: "weigh"}] = IntegrationRepo.all(running)

    Process.sleep(1_100)
    Durable.Executor.close_out_lost(Durable.Config.get(Durable), 1)

    assert IntegrationRepo.all(running) == []
    assert get(id).status == :cancelled
  end

  # Kills the failing lane's process as it commits the stop of its block:
  # the other lanes are cancelled, and the runs under them not yet.
  def kill_after_stopping_block(_event, _measurements, meta, _config) do
    if Enum.any?(meta.params, &match?(%{message: "another branch" <> _}, &1)),
      do: Process.put(:audit6_stopped_block, true)

    if meta.query == "commit" and Process.get(:audit6_stopped_block) do
      Probe.note(:killed_after_stopping)
      Process.exit(self(), :kill)
    end
  end

  # The run was undone a heartbeat after its lanes were stopped. A lane's
  # child is stopped by the cascade after that, and lost with the lane that
  # was cascading, it ran on until the sweep: the courier collected the parcel
  # after the slot was freed as if he never had (rule 15).
  test "a run isn't undone while a child of a stopped lane can still finish a step" do
    handler = "audit6-kill-#{System.unique_integer([:positive])}"
    event = [:durable, :integration_repo, :query]
    :telemetry.attach(handler, event, &__MODULE__.kill_after_stopping_block/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
    start_durable!(%{default: 4}, heartbeat_interval: 300)

    {:ok, id} = Durable.start(Audit6BlocksPickup, %{})
    await_status(id, :compensated, 10_000)
    assert Probe.hits(:killed_after_stopping) == 1

    assert_eventually(fn -> Probe.hits(:collected) == 1 end, 5_000)
    Process.sleep(200)

    assert Probe.hits({:freed_with_collected, 1}) == 1,
           "the slot was freed before the courier's step ended: #{inspect(Probe.log())}"
  end
end
