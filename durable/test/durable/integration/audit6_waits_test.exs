defmodule Durable.Integration.Audit6WaitsTest do
  @moduledoc """
  Waits, events and their sweeps against each other and against an operator,
  on live pollers.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 60_000

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
end
