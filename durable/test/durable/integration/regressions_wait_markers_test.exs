defmodule Durable.Integration.WaitMarkersRegressionsTest do
  @moduledoc "What a resume leaves behind for a wait must not reach the next step's data."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.Storage.Schemas.PendingEvent
  alias Durable.Wait.TimeoutWorker

  defmodule TimesOut do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_h_times_out" do
      step(:w, fn data ->
        v = wait_for_event("x", timeout: 100, timeout_value: :none)
        {:ok, Map.put(data, "v", inspect(v))}
      end)

      step(:next, fn data ->
        Probe.put(:keys, Map.keys(data))
        {:ok, data}
      end)
    end
  end

  test "a wait's timeout marker stays out of the next step's data" do
    start_durable!(%{default: 1})
    {:ok, id} = Durable.start(TimesOut, %{})
    await_status(id, :waiting)

    IntegrationRepo.update_all(from(p in PendingEvent, where: p.workflow_id == ^id),
      set: [timeout_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    TimeoutWorker.check_timeouts(Durable)
    await_status(id, :completed)
    keys = Probe.fetch(:keys)
    refute :__timeout__ in keys or "__timeout__" in keys
  end
end
