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
end
