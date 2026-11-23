defmodule Durable.Integration.Audit6WaitsTest do
  @moduledoc """
  Waits, events and their sweeps against each other and against an operator,
  on live pollers.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 60_000

  alias Durable.Storage.Schemas.PendingEvent
  alias Durable.Wait.TimeoutWorker

  # A contract goes out once legal and finance have both signed it, within the
  # run's hour.
  defmodule Audit6WaitsSignOff do
    use Durable
    use Durable.Wait

    workflow "audit6_waits_sign_off", timeout: 3_600_000 do
      step :sign_off, fn contract ->
        {:ok, Map.put(contract, "signed", wait_for_all(["legal.signed", "finance.signed"]))}
      end
    end
  end

  describe "a wait_for_all on a run that failed and is retried" do
    test "keeps the events it already got" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Audit6WaitsSignOff, %{"contract" => "C-77"})
      await_status(id, :waiting)

      legal = %{"by" => "L. Ortiz"}
      assert Durable.send_event(id, "legal.signed", legal) == :ok

      # Finance is away, and the run's hour runs out.
      expire!(id)
      TimeoutWorker.check_timeouts(Durable)
      assert await_status(id, :failed).error["type"] == "timeout"

      {:ok, ^id} = Durable.retry(id)
      await_status(id, :waiting)

      finance = %{"by" => "F. Chen"}
      assert Durable.send_event(id, "finance.signed", finance) == :ok

      run = await_status(id, :completed)
      assert run.context["signed"] == %{"legal.signed" => legal, "finance.signed" => finance}
    end
  end

  # A deposit, then the balance, both "payment.succeeded" (waiting.md). The
  # deposit can also fail.
  defmodule Audit6WaitsInstalments do
    use Durable
    use Durable.Wait

    alias Durable.IntegrationProbe, as: Probe

    workflow "audit6_waits_instalments" do
      step :deposit, fn order ->
        {paid, _payment} = wait_for_any(["payment.succeeded", "payment.failed"])
        {:ok, Map.put(order, "deposit", paid)}
      end

      step :book, fn order ->
        Probe.wait_for(:booked)
        {:ok, order}
      end

      step :balance, fn order ->
        {:ok, Map.put(order, "balance", wait_for_event("payment.succeeded"))}
      end
    end
  end

  describe "an event for a wait_for_any that already has its answer" do
    setup do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Audit6WaitsInstalments, %{"order" => "O-311"})
      await_status(id, :waiting)
      assert Durable.send_event(id, "payment.succeeded", %{"amount" => 30}) == :ok
      await_status(id, :running)
      %{id: id}
    end

    test "under another of its names is told :ok", %{id: id} do
      assert Durable.send_event(id, "payment.failed", %{"code" => "declined"}) == :ok
    end

    # Nothing waits for it yet: told so, the sender keeps it or tries again.
    # Told :ok, it was gone, and the run waited for the balance for good.
    test "under the name that answered it is told nothing waits for it", %{id: id} do
      assert Durable.send_event(id, "payment.succeeded", %{"amount" => 70}) ==
               {:error, :not_found}

      Probe.set(:booked)
      await_status(id, :waiting)
      assert Durable.send_event(id, "payment.succeeded", %{"amount" => 70}) == :ok
      assert await_status(id, :completed).context["balance"] == %{"amount" => 70}
    end
  end

  describe "a second event for a later wait of a name a wait_for_any didn't take" do
    test "is told nothing waits for it" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Audit6WaitsInstalments, %{"order" => "O-312"})
      await_status(id, :waiting)
      assert Durable.send_event(id, "payment.failed", %{"code" => "declined"}) == :ok

      Probe.set(:booked)
      await_status(id, :waiting)
      assert Durable.send_event(id, "payment.succeeded", %{"amount" => 100}) == :ok
      await_status(id, :completed)

      assert Durable.send_event(id, "payment.succeeded", %{"amount" => 100}) ==
               {:error, :not_found}
    end
  end

  defmodule Audit6WaitsBothSigned do
    use Durable
    use Durable.Wait

    workflow "audit6_waits_both_signed" do
      step :sign_off, fn contract ->
        {:ok, Map.put(contract, "signed", wait_for_all(["legal.signed", "finance.signed"]))}
      end
    end
  end

  # Stops the process that set `:audit6_hold` once its first transaction has
  # committed, until the test lets it go on.
  def hold_after_commit(_event, _measurements, %{query: "commit"}, test) do
    if Process.get(:audit6_hold) do
      Process.delete(:audit6_hold)
      send(test, {:held, self()})
      Probe.wait_for(:audit6_go_on)
    end
  end

  def hold_after_commit(_event, _measurements, _meta, _test), do: :ok

  defmodule Audit6WaitsDelivery do
    use Durable
    use Durable.Wait

    workflow "audit6_waits_delivery" do
      step :await_delivery, fn order ->
        {:ok, Map.put(order, "delivery", wait_for_event("shipment.delivered"))}
      end
    end
  end

  describe "an event for a cancelled run whose waits aren't closed yet" do
    # A cancel commits and then closes the run's waits. Its process lost in
    # between (a request timing out), they stay open until the stale sweep
    # gets to them, and an event sent meanwhile was told :ok.
    test "is told nothing waits for it" do
      start_durable!(%{default: 1})
      handler = "audit6-hold-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:durable, :integration_repo, :query],
        &__MODULE__.hold_after_commit/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, id} = Durable.start(Audit6WaitsDelivery, %{"order" => "O-12"})
      await_status(id, :waiting)

      cancelling =
        spawn(fn ->
          Process.put(:audit6_hold, true)
          Durable.cancel(id, "customer cancelled")
        end)

      assert_receive {:held, ^cancelling}, 5_000
      Process.exit(cancelling, :kill)
      assert get(id).status == :cancelled

      # The wait is still open: the canceller never got to it.
      assert [:pending] = IntegrationRepo.all(from(p in PendingEvent, select: p.status))

      assert Durable.send_event(id, "shipment.delivered", %{"signed_by" => "R. Diaz"}) ==
               {:error, :not_found}

      assert Durable.send_event(id, "shipment.delivered", %{"late" => true}, buffer: true) ==
               {:error, :finished}
    end
  end

  describe "a second event under a name a finished wait_for_all took" do
    test "is told nothing waits for it, as for any wait" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Audit6WaitsBothSigned, %{"contract" => "C-78"})
      await_status(id, :waiting)

      assert Durable.send_event(id, "legal.signed", %{"by" => "L. Ortiz"}) == :ok
      assert Durable.send_event(id, "finance.signed", %{"by" => "F. Chen"}) == :ok
      await_status(id, :completed)

      assert Durable.send_event(id, "legal.signed", %{"by" => "L. Ortiz"}) ==
               {:error, :not_found}
    end
  end
end
