defmodule Durable.OnFailureTest do
  @moduledoc "What a failed run does with its completed steps: nothing, unless asked."
  use Durable.DataCase, async: false

  import Durable.Testing

  @moduletag :capture_log

  defmodule Seen do
    def note(event), do: :persistent_term.put(__MODULE__, [event | all()])
    def all, do: :persistent_term.get(__MODULE__, [])
    def clear, do: :persistent_term.erase(__MODULE__)
  end

  defmodule Steps do
    use Durable.Helpers

    def book_flight(trip) do
      Seen.note(:book_flight)
      {:ok, assign(trip, :flight, "FL-123")}
    end

    # The card is charged only once the seat is held.
    def charge_card(trip) do
      Seen.note(:charge_card)

      case trip["payments"] do
        "down" -> {:error, "payments timed out"}
        "declined" -> {:rollback, "card declined"}
        _up -> {:ok, assign(trip, :receipt, "R-1")}
      end
    end

    def cancel_flight(trip) do
      Seen.note(:cancel_flight)
      {:ok, trip}
    end
  end

  defmodule BookTrip do
    use Durable
    use Durable.Wait

    workflow "book_trip" do
      step(:book_flight, [compensate: :cancel_flight], fn trip -> Steps.book_flight(trip) end)
      step(:charge_card, fn trip -> Steps.charge_card(trip) end)
      compensate(:cancel_flight, fn trip -> Steps.cancel_flight(trip) end)
    end

    workflow "book_trip_rolls_back", on_failure: :rollback do
      step(:book_flight, [compensate: :cancel_flight], fn trip -> Steps.book_flight(trip) end)
      step(:charge_card, fn trip -> Steps.charge_card(trip) end)
      compensate(:cancel_flight, fn trip -> Steps.cancel_flight(trip) end)
    end

    workflow "nothing_to_undo" do
      step(:charge_card, fn trip -> Steps.charge_card(trip) end)
    end

    # The seat is held while the traveller confirms.
    workflow "awaits_traveller" do
      step(:book_flight, [compensate: :cancel_flight], fn trip -> Steps.book_flight(trip) end)

      step(:confirm, fn trip ->
        wait_for_input("confirmation")
        {:ok, trip}
      end)

      compensate(:cancel_flight, fn trip -> Steps.cancel_flight(trip) end)
    end

    workflow "awaits_nothing_booked" do
      step(:confirm, fn trip ->
        wait_for_input("confirmation")
        {:ok, trip}
      end)
    end

    workflow "by_fare" do
      step(:book_flight, [compensate: :cancel_flight], fn trip -> Steps.book_flight(trip) end)

      branch :fare, fn _trip -> {:rollback, "the fare is no longer sold"} end do
        :flexible -> step(:add_changes, fn trip -> {:ok, trip} end)
      end

      compensate(:cancel_flight, fn trip -> Steps.cancel_flight(trip) end)
    end

    workflow "quotes" do
      step(:book_flight, [compensate: :cancel_flight], fn trip -> Steps.book_flight(trip) end)

      parallel :insurers do
        step(:north, fn _trip -> {:rollback, "no insurer will cover this trip"} end)
        step(:south, fn trip -> {:ok, trip} end)
      end

      compensate(:cancel_flight, fn trip -> Steps.cancel_flight(trip) end)
    end
  end

  setup do
    Seen.clear()
    on_exit(&Seen.clear/0)
  end

  defp book(payments, workflow \\ "book_trip"),
    do: run_workflow(BookTrip, %{"payments" => payments}, workflow: workflow)

  defp reload(run), do: Durable.TestRepo.get!(Durable.Storage.Schemas.WorkflowExecution, run.id)

  # A retried run reads its input again; payments are back.
  defp payments_back(run) do
    run
    |> reload()
    |> Ecto.Changeset.change(context: Map.put(reload(run).context, "payments", "up"))
    |> Durable.TestRepo.update!()
  end

  describe "a run that fails, by default" do
    test "is left failed with nothing undone" do
      run = book("down")

      assert run.status == :failed
      assert run.error["message"] == "payments timed out"
      assert :cancel_flight not in Seen.all()
    end

    test "can be retried once the cause is fixed, and keeps the flight it booked" do
      run = book("down")
      payments_back(run)

      assert {:ok, _} = Durable.retry(run.id)
      run = drain(run)

      assert run.status == :completed
      assert run.context["flight"] == "FL-123"
      assert Enum.count(Seen.all(), &(&1 == :book_flight)) == 1
      assert :cancel_flight not in Seen.all()
    end
  end

  describe "Durable.rollback/1" do
    test "undoes a failed run on a worker, keeping the error it failed with" do
      run = book("down")

      assert {:ok, id} = Durable.rollback(run.id)
      assert id == run.id
      assert reload(run).status == :pending
      assert :cancel_flight not in Seen.all()

      run = drain(run)
      assert run.status == :compensated
      assert run.error["message"] == "payments timed out"
      assert Enum.count(Seen.all(), &(&1 == :cancel_flight)) == 1
      # It undid; it didn't run the failed step again.
      assert Enum.count(Seen.all(), &(&1 == :charge_card)) == 1
      refute Map.has_key?(run.context, "__rollback__")
    end

    test "a run rolled back can't be retried or rolled back again" do
      run = book("down")
      {:ok, _} = Durable.rollback(run.id)
      drain(run)

      assert Durable.retry(run.id) == {:error, :rolled_back}
      assert Durable.rollback(run.id) == {:error, :rolled_back}
    end

    test "is for a failed run" do
      run = book("up")
      assert run.status == :completed
      assert Durable.rollback(run.id) == {:error, :not_failed}
    end

    test "rollback_plan names what it would run, and is empty with nothing to undo" do
      assert Durable.rollback_plan(book("down").id) == [book_flight: :cancel_flight]
      assert Durable.rollback_plan(book("down", "nothing_to_undo").id) == []
      assert Durable.rollback_plan(Ecto.UUID.generate()) == []
    end

    test "a run with nothing to undo stays failed, and can still be retried" do
      run = book("down", "nothing_to_undo")
      {:ok, _} = Durable.rollback(run.id)
      run = drain(run)

      assert run.status == :failed
      assert run.error["message"] == "payments timed out"
      assert {:ok, _} = Durable.retry(run.id)
    end
  end

  describe "Durable.cancel/3" do
    test "leaves what the run did, without rollback: true" do
      run = book("up", "awaits_traveller")
      assert run.status == :waiting

      assert :ok = Durable.cancel(run.id, "traveller walked away")
      run = drain(run)

      assert run.status == :cancelled
      assert :cancel_flight not in Seen.all()
      assert Durable.rollback(run.id) == {:error, :not_failed}
    end

    test "with rollback: true undoes the run on a worker, and it ends compensated" do
      run = book("up", "awaits_traveller")

      assert :ok = Durable.cancel(run.id, "traveller walked away", rollback: true)
      assert reload(run).status == :pending
      assert :cancel_flight not in Seen.all()

      run = drain(run)
      assert run.status == :compensated
      assert run.error == %{"type" => "cancelled", "message" => "traveller walked away"}
      assert Enum.count(Seen.all(), &(&1 == :cancel_flight)) == 1
      refute Map.has_key?(run.context, "__rollback__")
      assert Durable.retry(run.id) == {:error, :rolled_back}
    end

    test "with rollback: true and nothing to undo, the run stays cancelled" do
      run = book("up", "awaits_nothing_booked")

      assert :ok = Durable.cancel(run.id, nil, rollback: true)
      assert drain(run).status == :cancelled
    end

    test "with rollback: true closes the input the run was waiting for" do
      run = book("up", "awaits_traveller")
      :ok = Durable.cancel(run.id, nil, rollback: true)
      drain(run)

      assert Durable.provide_input(run.id, "confirmation", %{}) != :ok
      assert drain(run).status == :compensated
    end
  end

  describe "{:rollback, reason} from a step" do
    test "undoes the run at once, whatever the workflow does on failure" do
      run = book("declined")

      assert run.status == :compensated
      assert run.error == %{"type" => "rollback", "message" => "card declined"}
      assert Seen.all() == [:cancel_flight, :charge_card, :book_flight]
    end

    test "from a branch's decider undoes the steps before it" do
      run = run_workflow(BookTrip, %{}, workflow: "by_fare")

      assert run.status == :compensated
      assert run.error["message"] == "the fare is no longer sold"
      assert :cancel_flight in Seen.all()
    end

    test "from a lane undoes the steps before the block" do
      run = run_workflow(BookTrip, %{}, workflow: "quotes")

      assert run.status == :compensated
      assert run.error["message"] == "no insurer will cover this trip"
      assert :cancel_flight in Seen.all()
    end
  end

  describe "on_failure: :rollback" do
    test "undoes the run on any failure" do
      run = book("down", "book_trip_rolls_back")

      assert run.status == :compensated
      assert run.error["message"] == "payments timed out"
      assert :cancel_flight in Seen.all()
    end

    test "is :halt or :rollback" do
      assert_raise ArgumentError, ~r/invalid on_failure: :undo/, fn ->
        Code.compile_string("""
        defmodule Durable.OnFailureTest.Bad do
          use Durable
          workflow "bad", on_failure: :undo do
            step(:a, fn d -> {:ok, d} end)
          end
        end
        """)
      end
    end
  end
end
