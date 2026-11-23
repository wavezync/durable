defmodule Durable.Integration.Audit5OpsTest do
  @moduledoc "Audit 5: operator actions (cancel, rollback, keys) meeting live workers."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.IntegrationProbe, as: Probe
  alias Durable.Queue.StaleJobRecovery

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
    # The run failed because the card was declined, and still says so. That
    # its rollback was cut short is on the undo's own row and in the activity.
    assert run.error["message"] =~ "card declined"
    assert [%{status: :failed, error: %{"type" => "task_crash"}}] = undo_rows(id, "book_hotel")
    assert [%{details: %{"reason" => "task_crash"}}] = rollback_interrupted(id)
    assert Probe.hits({:flight_cancelled, id}) == 1

    assert Durable.retry(id) == {:error, :rolled_back}

    # The rollback can still be finished, and the flight isn't cancelled twice.
    assert {:ok, ^id} = Durable.rollback(id)
    assert await_status(id, :compensated).error == run.error
    assert Probe.hits({:flight_cancelled, id}) == 1
    assert Probe.hits({:charge, id}) == 1
  end

  defmodule Audit5OpsConference do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "a5_conference", on_failure: :rollback do
      step :book_venue, [compensate: :release_venue], fn event -> {:ok, event} end
      step :order_catering, [compensate: :cancel_catering], fn event -> {:ok, event} end
      step :charge_deposit, fn _event -> {:error, "payments timed out"} end

      compensate :cancel_catering, fn event ->
        Probe.note({:catering_cancelled, Durable.Context.workflow_id()})
        {:ok, event}
      end

      # The venue's booking system hangs the first time, and the node is lost
      # while it does.
      compensate :release_venue, fn event ->
        if Probe.note({:release_venue, Durable.Context.workflow_id()}) == 1 do
          Probe.set(:releasing_venue)
          Process.sleep(:infinity)
        end

        {:ok, event}
      end
    end
  end

  # The attempts to undo `id`'s step `name`, oldest first.
  defp undo_rows(id, name) do
    IntegrationRepo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^id and s.is_compensation and s.compensation_for == ^name,
        order_by: s.inserted_at
      )
    )
  end

  defp rollback_interrupted(id),
    do: Durable.Activity.list!(workflow_id: id, kinds: ["rollback_interrupted"])

  # The process running `id`: the executor's task under its worker.
  defp task_of(id) do
    Enum.filter(Process.list(), fn pid ->
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> dict[:durable_workflow_id] == id
        nil -> false
      end
    end)
  end

  test "a rollback whose node died ends with the error that started it" do
    start_durable!(%{default: 2}, stale_lock_timeout: 1)

    {:ok, id} = Durable.start(Audit5OpsConference, %{"event" => "elixirconf"})
    assert_eventually(fn -> Probe.set?(:releasing_venue) end)
    why = get(id).error
    assert why["message"] =~ "payments timed out"

    # The node goes: nothing is left to close the undo or fail the run.
    worker = Durable.DataCase.get_worker_pid(Durable, "default", id)
    for pid <- [worker | task_of(id)], do: Process.exit(pid, :kill)
    Process.sleep(1_100)
    StaleJobRecovery.recover_now(Durable)

    failed = await_status(id, :failed)
    assert failed.error == why

    assert [%{status: :failed, error: %{"type" => "zombie_detected"}}] =
             undo_rows(id, "book_venue")

    assert [%{details: %{"reason" => "zombie_detected"}}] = rollback_interrupted(id)

    assert {:ok, ^id} = Durable.rollback(id)
    assert await_status(id, :compensated).error == why
    assert Probe.hits({:release_venue, id}) == 2
    assert Probe.hits({:catering_cancelled, id}) == 1
  end

  defmodule Audit5OpsInvoice do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "a5_invoice" do
      # The mail server is down for the first invoice of the day.
      step :email_invoice, fn invoice ->
        case Probe.note(:email_invoice) do
          1 -> {:error, "mail server down"}
          _ -> {:ok, invoice}
        end
      end
    end
  end

  # Takes the lock every change to who holds `run`'s key takes first, and keeps
  # it until told to let go: whoever comes for the key waits here.
  defp hold_key(run) do
    test = self()
    name = Durable.Keys.lock_name(run.workflow_module, run.workflow_name, run.key)

    holder =
      spawn(fn ->
        IntegrationRepo.transaction(fn ->
          IntegrationRepo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [name])
          send(test, :held)
          receive do: (:let_go -> :ok)
        end)
      end)

    assert_receive :held, 5_000
    holder
  end

  defp waiting_for_a_key do
    %{rows: [[count]]} =
      IntegrationRepo.query!("""
      SELECT count(*) FROM pg_locks l JOIN pg_database d ON d.oid = l.database
      WHERE l.locktype = 'advisory' AND NOT l.granted AND d.datname = current_database()
      """)

    count
  end

  test "two operators retrying a run that lost its key: the second is told it's no longer failed" do
    start_durable!(%{default: 2})
    key = "invoice:2026-0042"

    {:ok, first} = Durable.start(Audit5OpsInvoice, %{"to" => "ada@example.com"}, key: key)
    await_status(first, :failed)
    # Sent again by hand, which takes the key from the failed run.
    {:ok, second} = Durable.start(Audit5OpsInvoice, %{"to" => "ada@example.com"}, key: key)
    assert second != first
    await_status(second, :completed)
    refute get(first).holds_key

    # Both operators have read the run as failed before either retry lands.
    lock = hold_key(get(first))
    retries = for _operator <- 1..2, do: Task.async(fn -> Durable.retry(first) end)
    assert_eventually(fn -> waiting_for_a_key() == 2 end, 5_000, 10)
    send(lock, :let_go)

    assert Enum.sort(Task.await_many(retries)) == [{:error, :not_failed}, {:ok, first}]
    assert await_status(first, :completed).holds_key
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

  test "a run cancelled as it comes for its key doesn't end up holding it" do
    start_durable!(%{default: 2})
    key = "catalog:boots"

    {:ok, holder} = Durable.start(Audit5OpsReprice, %{"rev" => "a"}, key: key)
    await_status(holder, :waiting)
    {:ok, next} = Durable.start(Audit5OpsReprice, %{"rev" => "b"}, key: key)

    # The holder ends, and the run behind it is claimed and comes for the key.
    # An operator cancels it right then.
    lock = hold_key(get(next))
    :ok = Durable.provide_input(holder, "approval", %{"by" => "dana"})
    await_status(holder, :completed)
    assert_eventually(fn -> waiting_for_a_key() == 1 end, 5_000, 10)
    assert get(next).status == :running

    :ok = Durable.cancel(next, "catalog retired")
    send(lock, :let_go)
    assert_eventually(fn -> waiting_for_a_key() == 0 end, 5_000, 10)
    Process.sleep(200)

    run = get(next)
    assert {run.status, run.holds_key} == {:cancelled, false}
    assert Probe.hits({:locked, "b"}) == 0

    # The key is free for the next reprice, which is a run of its own.
    {:ok, third} = Durable.start(Audit5OpsReprice, %{"rev" => "c"}, key: key)
    assert third not in [holder, next]
    assert await_status(third, :waiting).holds_key
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
