defmodule Durable.Integration.Audit4ExecRollbackTest do
  @moduledoc "Audit 4: a rollback that loses its worker part-way, asked for again."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  defmodule Audit4ExecShipment do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    # A parcel is labelled and a van reserved before customs turns it away.
    workflow "audit4_shipment" do
      step(:reserve_van, [compensate: :release_van], fn parcel -> {:ok, parcel} end)
      step(:print_label, [compensate: :void_label], fn parcel -> {:ok, parcel} end)
      step(:clear_customs, fn _parcel -> {:fail, "customs refused the parcel"} end)

      compensate(:void_label, fn parcel ->
        Probe.note({:void_label, Durable.Context.workflow_id()})
        {:ok, parcel}
      end)

      # The first release takes its process down with it, as a node going would.
      compensate(:release_van, fn parcel ->
        if Probe.note({:release_van, Durable.Context.workflow_id()}) == 1,
          do: Process.exit(self(), :kill)

        {:ok, parcel}
      end)
    end
  end

  # A worker that dies in an undo leaves the run :failed, and Durable.rollback/1
  # takes it again. executor.ex:3168 (build_compensation_stack/3) lists every
  # completed step and doesn't leave out the ones whose undo already completed
  # (a `step_executions` row with is_compensation and compensation_for), so
  # those are undone a second time.
  @tag :skip
  test "a rollback asked for again after its worker died doesn't repeat the undo that had finished" do
    start_durable!(%{default: 2})

    {:ok, id} = Durable.start(Audit4ExecShipment, %{})
    await_status(id, :failed)

    {:ok, ^id} = Durable.rollback(id)
    assert_eventually(fn -> Probe.hits({:release_van, id}) == 1 end)
    await_status(id, :failed)
    assert Probe.hits({:void_label, id}) == 1

    {:ok, ^id} = Durable.rollback(id)
    await_status(id, :compensated)

    assert Probe.hits({:release_van, id}) == 2
    assert Probe.hits({:void_label, id}) == 1, "the label was voided twice"
  end
end
