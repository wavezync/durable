defmodule Durable.TestingTest do
  use Durable.DataCase, async: false

  import Durable.Testing

  defmodule Order do
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "order" do
      step(:reserve, fn data -> {:ok, assign(data, :reserved, true)} end)

      parallel do
        step(:email, fn data -> {:ok, assign(data, :emailed, true)} end)
        step(:invoice, fn data -> {:ok, assign(data, :invoiced, true)} end)
      end

      step(:cool_off, fn data ->
        sleep(hours(24))
        {:ok, data}
      end)

      step(:approve, fn data ->
        %{"approved" => approved} = wait_for_input("approval")
        {:ok, assign(data, :approved, approved)}
      end)
    end
  end

  defmodule Flaky do
    use Durable
    use Durable.Helpers

    workflow "flaky" do
      step(:charge, [retry: [max_attempts: 3]], fn data ->
        calls = Process.get(:charge_calls, 0) + 1
        Process.put(:charge_calls, calls)
        if calls < 3, do: {:error, "card declined"}, else: {:ok, assign(data, :charged, true)}
      end)
    end
  end

  defmodule Payment do
    use Durable
    use Durable.Helpers

    workflow "payment" do
      step(:authorize, fn _data -> {:ok, %{payment_id: "pay_1"}} end)
    end
  end

  defmodule Trip do
    use Durable
    use Durable.Helpers
    use Durable.Orchestration

    workflow "trip" do
      step(:pay, [compensate: :refund], fn data ->
        {:ok, child} = call_workflow(Payment, %{})
        {:ok, assign(data, :payment_id, child["payment_id"])}
      end)

      step(:book, fn _data -> {:error, "sold out"} end)

      compensate(:refund, fn data -> {:ok, data} end)
    end
  end

  defmodule Declined do
    use Durable

    workflow "declined" do
      step(:charge, fn _data -> {:error, "card declined"} end)
    end
  end

  test "string errors are stored as a map" do
    run = run_workflow(Declined, %{})

    assert_status(run, :failed)
    assert run.error == %{"type" => "error", "message" => "card declined"}
  end

  test "runs child workflows and compensations" do
    run = run_workflow(Trip, %{})

    assert_status(run, :compensated)
    assert run.error == %{"type" => "error", "message" => "sold out"}
    assert assert_step(run, :pay).status == :completed
    assert_step(run, :book, :failed)
    assert_step(run, :compensate_refund)
  end

  test "drives parallel branches and sleeps, then stops at an input" do
    run = run_workflow(Order, %{})

    assert_status(run, :waiting)
    assert_step(run, :email)
    assert_step(run, :cool_off)
    assert_waiting_for_input(run, "approval")

    :ok = Durable.provide_input(run.id, "approval", %{"approved" => true})
    run = run |> drain() |> assert_status(:completed)

    assert %{"approved" => true, "__results__" => %{"email" => ["ok", _]}} = run.context
  end

  test "retries skip their backoff" do
    {micros, run} = :timer.tc(fn -> run_workflow(Flaky, %{}) end)

    assert_status(run, :completed)
    assert assert_step(run, :charge).attempt == 3
    # The default exponential backoff would wait 2s + 4s.
    assert micros < 1_000_000
  end

  test "failures explain the mismatch" do
    run = run_workflow(Order, %{})

    error = assert_raise ExUnit.AssertionError, fn -> assert_status(run, :completed) end
    assert error.message =~ "got :waiting"
    assert error.message =~ ~s(current step: "approve")

    error = assert_raise ExUnit.AssertionError, fn -> assert_step(run, :ship) end
    assert error.message =~ ~s(Step :ship never ran)

    error = assert_raise ExUnit.AssertionError, fn -> assert_step(run, :approve, :completed) end
    assert error.message =~ "got :waiting"

    error = assert_raise ExUnit.AssertionError, fn -> assert_waiting_for_event(run, "paid") end
    assert error.message =~ ~s(wait for "paid")
  end
end
