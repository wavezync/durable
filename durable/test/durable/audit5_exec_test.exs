defmodule Durable.Audit5ExecTest do
  @moduledoc """
  Audit 5, executor: a step's data and what a failure leaves behind.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Storage.Schemas.StepExecution
  alias Durable.Storage.Schemas.WorkflowExecution
  alias Durable.TestRepo, as: Repo

  @moduletag :capture_log

  defmodule Audit5ExecSeen do
    @moduledoc false
    def put(key, value), do: :persistent_term.put({__MODULE__, key}, value)
    def get(key), do: :persistent_term.get({__MODULE__, key}, nil)

    def clear do
      for {{__MODULE__, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    end
  end

  defmodule Audit5ExecTrip do
    @moduledoc false
    use Durable
    use Durable.Helpers

    workflow "audit5_trip", timeout: seconds(1), on_failure: :rollback do
      step :book_hotel, [compensate: :cancel_hotel], fn trip ->
        {:ok, assign(trip, :hotel_booking, "H-#{trip["trip_id"]}")}
      end

      step :book_flight, fn trip -> {:ok, assign(trip, :flight_booking, "F-1")} end

      compensate :cancel_hotel, fn trip ->
        Audit5ExecSeen.put(:cancelled_hotel, get(trip, :hotel_booking))
        {:ok, trip}
      end
    end

    # The fare class decides how the flight is booked; a trip without one
    # makes `on:` raise.
    workflow "audit5_trip_by_fare", on_failure: :rollback do
      step :book_hotel, [compensate: :cancel_hotel], fn trip ->
        {:ok, assign(trip, :hotel_booking, "H-#{trip["trip_id"]}")}
      end

      branch on: fn trip -> String.downcase(trip["fare_class"]) end do
        "economy" -> step :book_economy, fn trip -> {:ok, trip} end
        _ -> step :book_business, fn trip -> {:ok, trip} end
      end

      compensate :cancel_hotel, fn trip ->
        Audit5ExecSeen.put(:cancelled_hotel, get(trip, :hotel_booking))
        {:ok, trip}
      end
    end
  end

  defmodule Audit5ExecParcel do
    @moduledoc false
    use Durable
    use Durable.Helpers

    # A key that is an atom made from outside text, with a NUL in it: jsonb
    # can't hold one, and 2.0.0 stored it with the NUL replaced.
    workflow "audit5_parcel_label" do
      step :print_label, fn parcel ->
        {:ok, Map.merge(parcel, %{String.to_atom("handling\0note") => "fragile"})}
      end

      step :ship, fn parcel -> {:ok, assign(parcel, :shipped, true)} end
    end

    # A jump that hands on the ship date in place of the parcel.
    workflow "audit5_parcel_jump" do
      step :route, fn _parcel -> {:goto, :ship, ~D[2026-11-23]} end
      step :hold, fn parcel -> {:ok, parcel} end
      step :ship, fn parcel -> {:ok, parcel} end
    end

    # A named branch's decider that hands its arm the ship date.
    workflow "audit5_parcel_arm" do
      branch :carrier, fn _parcel -> {:courier, ~D[2026-11-23]} end do
        :courier -> step :hand_over, fn parcel -> {:ok, parcel} end
        :post -> step :post, fn parcel -> {:ok, parcel} end
      end
    end

    # Held for a pickup slot worked out in the wrong unit: 300,000 years on,
    # past the last time Postgres can store.
    workflow "audit5_parcel_pickup" do
      step :await_pickup, fn _parcel -> {:snooze, 300_000 * 365 * 86_400_000} end
    end
  end

  defmodule Audit5ExecCheckout do
    @moduledoc false
    use Durable
    use Durable.Helpers

    # The card is charged, then stock and tax are looked up side by side.
    workflow "audit5_checkout" do
      step :charge, fn order ->
        Audit5ExecSeen.put(:charges, (Audit5ExecSeen.get(:charges) || 0) + 1)
        {:ok, assign(order, :charged, true)}
      end

      parallel :lookups do
        step :stock, fn order -> {:ok, assign(order, :in_stock, 3)} end
        step :tax, fn order -> {:ok, assign(order, :tax, 1)} end
      end
    end
  end

  defmodule Audit5ExecReceiptMail do
    @moduledoc false
    use Durable

    workflow "audit5_receipt_mail" do
      step :send, fn mail -> {:ok, mail} end
    end
  end

  defmodule Audit5ExecInvoice do
    @moduledoc false
    use Durable
    use Durable.Helpers
    use Durable.Orchestration

    # The receipt is mailed, then the invoice printed; the printer is offline
    # the first time.
    workflow "audit5_invoice" do
      step :mail_and_print, fn invoice ->
        {:ok, _mail} =
          start_workflow(Audit5ExecReceiptMail, %{"to" => "ada@example.com"}, ref: :receipt)

        if Audit5ExecSeen.get(:printer_online),
          do: {:ok, assign(invoice, :printed, true)},
          else: {:error, "printer offline"}
      end
    end
  end

  defmodule Audit5ExecQuote do
    @moduledoc false
    use Durable

    # A shipping quote is good for a moment. The carrier's rates are asked for
    # twice if need be, and this time the carrier never answers.
    workflow "audit5_quote", timeout: 12 do
      step :fetch_rates, [retry: [max_attempts: 2, base: 1]], fn _quote ->
        Process.sleep(:infinity)
      end
    end
  end

  setup do
    Audit5ExecSeen.clear()
    :ok
  end

  describe "a child started under a ref: in a step that then fails for good" do
    test "is the same child when the run is retried" do
      run = run_workflow(Audit5ExecInvoice, %{"invoice_id" => "inv-1"})
      assert run.status == :failed

      Audit5ExecSeen.put(:printer_online, true)
      {:ok, _} = Durable.retry(run.id)
      assert drain(run).status == :completed

      assert [_one] =
               Repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^run.id))
    end
  end

  describe "rerun/2 of a lane" do
    test "is refused, and charges nothing again" do
      run = run_workflow(Audit5ExecCheckout, %{"order_id" => "ORD-1"})
      assert run.status == :completed

      lane =
        Repo.one!(from(w in WorkflowExecution, where: w.parent_workflow_id == ^run.id, limit: 1))

      assert lane.status == :completed
      assert Durable.rerun(lane.id) == {:error, :lane}

      assert Repo.aggregate(WorkflowExecution, :count) == 3
      assert Audit5ExecSeen.get(:charges) == 1
    end

    test "leaves rerunning the block's run as it was" do
      run = run_workflow(Audit5ExecCheckout, %{"order_id" => "ORD-2"})
      {:ok, again} = Durable.rerun(run.id)

      assert drain(again).status == :completed
      assert Audit5ExecSeen.get(:charges) == 2
    end
  end

  describe "a step's data" do
    test "keeps a key that is an atom with a NUL in it, as a storable string" do
      run = run_workflow(Audit5ExecParcel, %{"id" => 1}, workflow: "audit5_parcel_label")

      assert run.status == :completed, inspect(run.error)
      assert run.context["handling�note"] == "fragile"
      assert run.context["shipped"] == true
    end
  end

  describe "a jump whose data is a date, not a map" do
    for workflow <- ["audit5_parcel_jump", "audit5_parcel_arm"] do
      test "fails the run as an invalid return (#{workflow})" do
        run = run_workflow(Audit5ExecParcel, %{"id" => 1}, workflow: unquote(workflow))

        assert run.status == :failed
        assert run.error["type"] == "invalid_step_return"
      end
    end
  end

  describe "a snooze longer than a timestamp holds" do
    test "fails the run as an invalid return, not left running" do
      run = run_workflow(Audit5ExecParcel, %{"id" => 1}, workflow: "audit5_parcel_pickup")

      assert run.status == :failed
      assert run.error["type"] == "invalid_step_return"
    end
  end

  # Holds the run between a step's end and the next step, as a slow write or
  # a GC pause would, until its deadline has passed.
  def hold_past_deadline(_event, _measurements, %{step: :book_hotel, workflow_id: id}, _config) do
    deadline = Repo.get!(WorkflowExecution, id).deadline_at
    Process.sleep(max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0) + 20)
  end

  def hold_past_deadline(_event, _measurements, _meta, _config), do: :ok

  describe "a run whose deadline passes between two steps" do
    test "hands its undo the data the last step saved" do
      handler = "audit5-hold-#{System.unique_integer([:positive])}"
      :telemetry.attach(handler, [:durable, :step, :stop], &__MODULE__.hold_past_deadline/4, nil)
      on_exit(fn -> :telemetry.detach(handler) end)

      run = run_workflow(Audit5ExecTrip, %{"trip_id" => 7})

      assert run.status == :compensated
      assert run.error["type"] == "timeout"
      assert Audit5ExecSeen.get(:cancelled_hotel) == "H-7"
    end
  end

  test "a branch's on: that raises hands the undo the data the last step saved" do
    run = run_workflow(Audit5ExecTrip, %{"trip_id" => 8}, workflow: "audit5_trip_by_fare")

    assert run.status == :compensated
    assert Audit5ExecSeen.get(:cancelled_hotel) == "H-8"
  end

  describe "a step stopped by its run's deadline" do
    # The step's time limit was the milliseconds left to the deadline, rounded
    # down, so the step could be stopped before the deadline. Not past it yet,
    # the run took the stop for a failure to retry, and failed "before" the
    # step at the next claim. Each run lands somewhere else in its millisecond.
    test "is never stopped before the deadline, to be retried" do
      for n <- 1..60 do
        run = run_workflow(Audit5ExecQuote, %{"quote_id" => n})

        attempts = Repo.all(from(s in StepExecution, where: s.workflow_id == ^run.id))

        assert run.status == :failed

        # A run slow to start can be past its deadline before the step begins,
        # and then has no attempt. One that began is stopped at the deadline.
        assert attempts == [] or
                 run.error["message"] == "the run passed its timeout during fetch_rates",
               "run #{n}: #{run.error["message"]}"

        assert length(attempts) <= 1
      end
    end
  end
end
