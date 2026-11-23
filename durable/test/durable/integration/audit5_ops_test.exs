defmodule Durable.Integration.Audit5OpsTest do
  @moduledoc "Audit 5: operator actions (cancel, rollback, keys) meeting live workers."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.IntegrationProbe, as: Probe

  defmodule Audit5OpsCheckout do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "a5_slow_payment" do
      step :reserve_stock, [compensate: :release_stock], fn order -> {:ok, order} end

      # The payment provider takes its time to answer.
      step :charge_card, fn order ->
        Probe.set(:charging)
        Process.sleep(1_500)
        Probe.note({:charged, Durable.Context.workflow_id()})
        {:ok, order}
      end

      compensate :release_stock, fn order ->
        Probe.note({:released, Durable.Context.workflow_id()})
        {:ok, order}
      end
    end

    workflow "a5_seat_hold" do
      # The airline answers while the cancel is landing.
      step :hold_seat, [compensate: :release_seat], fn trip ->
        Probe.set(:holding)
        Probe.wait_for(:airline_answered)
        Probe.note({:held, Durable.Context.workflow_id()})
        {:ok, trip}
      end

      step :charge_card, fn trip -> {:ok, trip} end

      compensate :release_seat, fn trip ->
        Probe.note({:released, Durable.Context.workflow_id()})
        {:ok, trip}
      end
    end
  end

  defmodule Audit5OpsTrip do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "a5_trip", on_failure: :rollback do
      step :book_hotel, [compensate: :cancel_hotel], fn trip -> {:ok, trip} end
      step :book_flight, [compensate: :cancel_flight], fn trip -> {:ok, trip} end

      # Declined the first time; the traveller then updates the card.
      step :charge_card, fn trip ->
        case Probe.note({:charge, Durable.Context.workflow_id()}) do
          1 -> {:error, "card declined"}
          _ -> {:ok, trip}
        end
      end

      compensate :cancel_flight, fn trip ->
        Probe.note({:flight_cancelled, Durable.Context.workflow_id()})
        {:ok, trip}
      end

      # The node goes down while the hotel is being cancelled.
      compensate :cancel_hotel, fn trip ->
        if Probe.note({:cancel_hotel, Durable.Context.workflow_id()}) == 1,
          do: Process.exit(self(), :kill)

        {:ok, trip}
      end
    end
  end

  test "a run whose rollback lost its worker part-way can't be retried as if nothing was undone" do
    start_durable!(%{default: 2})

    {:ok, id} = Durable.start(Audit5OpsTrip, %{"traveller" => "ada"})
    run = await_status(id, :failed)
    assert run.error["type"] == "task_crash"
    assert Probe.hits({:flight_cancelled, id}) == 1

    assert Durable.retry(id) == {:error, :rolled_back}

    # The rollback can still be finished, and the flight isn't cancelled twice.
    assert {:ok, ^id} = Durable.rollback(id)
    await_status(id, :compensated)
    assert Probe.hits({:flight_cancelled, id}) == 1
    assert Probe.hits({:charge, id}) == 1
  end

  defmodule Audit5OpsReprice do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    # A catalog's prices are locked while a reprice waits for approval.
    workflow "a5_reprice", on_duplicate: :run_again do
      step :lock_prices, [compensate: :unlock_prices], fn data ->
        Probe.note({:locked, data["rev"]})
        {:ok, data}
      end

      step :approve, fn data ->
        wait_for_input("approval")
        {:ok, data}
      end

      compensate :unlock_prices, fn data ->
        Probe.note({:unlocked, data["rev"]})
        {:ok, data}
      end
    end
  end

  test "a run waiting behind a holder cancelled with rollback: true waits for the undo" do
    start_durable!(%{default: 4})

    for n <- 1..10 do
      key = "catalog:#{n}"
      {:ok, holder} = Durable.start(Audit5OpsReprice, %{"rev" => "#{n}a"}, key: key)
      await_status(holder, :waiting)
      {:ok, next} = Durable.start(Audit5OpsReprice, %{"rev" => "#{n}b"}, key: key)

      :ok = Durable.cancel(holder, "repriced by hand", rollback: true)
      await_status(holder, :compensated)
      await_status(next, :waiting)

      order =
        for {{event, rev}, _queue, _node} <- Probe.log(),
            rev in ["#{n}a", "#{n}b"],
            do: {event, rev}

      assert order == [{:locked, "#{n}a"}, {:unlocked, "#{n}a"}, {:locked, "#{n}b"}],
             "the next run locked the prices before the cancelled one unlocked them: " <>
               inspect(order)
    end
  end

  defp settled?(id) do
    run = get(id)

    run.status in [:compensated, :compensation_failed, :completed, :failed] or
      (run.status == :cancelled and not Map.has_key?(run.engine_state, "__rollback__"))
  end

  describe "cancel with rollback: true on a run a worker has" do
    test "stops the step in flight at the worker's next heartbeat" do
      start_durable!(%{default: 2}, heartbeat_interval: 1_000)

      {:ok, id} = Durable.start(Audit5OpsCheckout, %{}, workflow: "a5_slow_payment")
      Probe.wait_for(:charging)
      Process.sleep(200)

      :ok = Durable.cancel(id, "customer cancelled", rollback: true)
      await_status(id, :compensated)
      # Long enough for the payment step to have finished, had it gone on.
      Process.sleep(1_800)

      assert Probe.hits({:released, id}) == 1
      assert Probe.hits({:charged, id}) == 0, "the cancelled run's step went on and charged"
    end

    test "undoes a step that finished before the worker heard of the cancel" do
      start_durable!(%{default: 2}, heartbeat_interval: 1_000)

      {:ok, id} = Durable.start(Audit5OpsCheckout, %{}, workflow: "a5_seat_hold")
      Probe.wait_for(:holding)

      :ok = Durable.cancel(id, "traveller cancelled", rollback: true)
      Probe.set(:airline_answered)
      assert_eventually(fn -> Probe.hits({:held, id}) == 1 end)

      assert_eventually(fn -> settled?(id) end, 5_000)
      run = get(id)

      assert {run.status, Probe.hits({:released, id})} == {:compensated, 1},
             "the seat was held, and is still held"
    end
  end
end
