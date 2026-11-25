defmodule EndedForGoodRefund do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The refund is issued and the order is called off. Asked again, the
  # gateway refunds again.
  workflow "ended_for_good_refund" do
    step :refund_and_call_off, fn order ->
      if Probe.note(:refund) == 1, do: Probe.fetch(:outcome), else: {:ok, order}
    end
  end
end

defmodule EndedForGoodShip do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "ended_for_good_ship" do
    step :ship, fn parcel ->
      Probe.note(:shipped)
      {:ok, parcel}
    end
  end
end

defmodule EndedForGoodReminder do
  @moduledoc false
  use Durable
  use Durable.Wait
  alias Durable.IntegrationProbe, as: Probe

  # Texts the customer, then waits longer than any timestamp holds: a wait
  # that can't be written, which fails the step for good.
  workflow "ended_for_good_reminder" do
    step :remind, [retry: [max_attempts: 3]], fn data ->
      Probe.note(:texted)
      sleep(10 ** 30)
      {:ok, data}
    end
  end
end

defmodule EndedForGoodPacking do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # Out of stock: the whole order is called off, not just the packing.
  workflow "ended_for_good_packing" do
    step :pack, fn order ->
      if Probe.note(:packed) == 1,
        do: {:cancel, "out of stock", scope: :root},
        else: {:ok, order}
    end
  end
end

defmodule EndedForGoodOrder do
  @moduledoc false
  use Durable
  use Durable.Orchestration

  workflow "ended_for_good_order" do
    step :fulfil, fn order ->
      case call_workflow(EndedForGoodPacking, order, ref: :packing) do
        {:ok, _packed} -> {:ok, order}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

defmodule Durable.Integration.EndedForGoodTest do
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  def hold(_event, _measurements, %{result: result}, result) do
    Probe.note(:held)
    Probe.wait_for(:never)
  end

  def hold(_event, _measurements, _meta, _result), do: :ok

  # Held at the attempt's end event: its row is closed, the run not yet
  # written. The node stops (grace 0), and another takes the run.
  defp stopped_after(outcome, result) do
    Probe.put(:outcome, outcome)
    handler = "ended_for_good-hold-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:durable, :step, :stop], &__MODULE__.hold/4, result)
    start_durable!(%{default: 1}, shutdown_grace_period: 0)

    {:ok, id} = Durable.start(EndedForGoodRefund, %{"order" => 1})
    assert_eventually(fn -> Probe.hits(:held) == 1 end)
    :telemetry.detach(handler)
    stop_supervised!(Durable)

    start_durable!(%{default: 1})
    assert_eventually(fn -> get(id).status in [:completed, :failed, :cancelled] end, 5_000)
    get(id)
  end

  describe "a node that stops after a step cancelled its run, before the cancel" do
    test "doesn't run the step again, and the run ends cancelled" do
      run = stopped_after({:cancel, "customer withdrew"}, :cancelled)

      assert {Probe.hits(:refund), run.status} == {1, :cancelled}
    end
  end

  # An app's handler that records each step start in a table of its own, on
  # the app's repo, and a statement of it the database refuses (here a
  # division by zero; a duplicate key or a missing table does the same).
  def audit_start(_event, _measurements, _meta, :query) do
    Probe.note(:audit)
    IntegrationRepo.query!("SELECT 1 / 0 AS step_audit", [])
    :ok
  end

  def audit_start(_event, _measurements, _meta, :transaction) do
    Probe.note(:audit)
    IntegrationRepo.transaction(fn -> IntegrationRepo.query!("SELECT 1 / 0 AS step_audit") end)
    :ok
  end

  describe "a [:durable, :step, :start] handler whose query fails" do
    test "is detached by :telemetry, and the step still runs" do
      audited(:query)
    end

    test "in a transaction of its own, too" do
      audited(:transaction)
    end
  end

  defp audited(how) do
    handler = "ended_for_good-audit-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:durable, :step, :start], &__MODULE__.audit_start/4, how)
    on_exit(fn -> :telemetry.detach(handler) end)
    start_durable!(%{default: 1})

    {:ok, id} = Durable.start(EndedForGoodShip, %{"parcel" => 1})
    assert_eventually(fn -> get(id).status in [:completed, :failed] end, 5_000)

    run = get(id)
    assert Probe.hits(:audit) == 1
    assert {run.status, run.error, Probe.hits(:shipped)} == {:completed, nil, 1}
  end

  # Held once the wait's row is closed failed (and that is committed), before
  # the run is: the first update of an attempt's row after the step's end
  # event, or the commit after it in a transaction.
  def hold_wait([:durable, :step, :stop], _measurements, %{result: :suspended}, _config),
    do: Process.put(:ended_for_good_suspended, true)

  def hold_wait(_event, _measurements, %{query: "commit"}, _config) do
    if Process.get(:ended_for_good_closed), do: held()
  end

  def hold_wait(_event, _measurements, %{source: "step_executions", query: query}, _config) do
    cond do
      not (Process.get(:ended_for_good_suspended) == true and query =~ ~r/^UPDATE/) -> :ok
      IntegrationRepo.in_transaction?() -> Process.put(:ended_for_good_closed, true)
      true -> held()
    end
  end

  def hold_wait(_event, _measurements, _meta, _config), do: :ok

  defp held do
    Probe.note(:held)
    Probe.wait_for(:never)
  end

  describe "a node that stops after a wait that can't be written failed its step" do
    test "doesn't run the step again" do
      handler = "ended_for_good-wait-#{System.unique_integer([:positive])}"

      events = [[:durable, :integration_repo, :query], [:durable, :step, :stop]]
      :telemetry.attach_many(handler, events, &__MODULE__.hold_wait/4, nil)
      start_durable!(%{default: 1}, shutdown_grace_period: 0)

      {:ok, id} = Durable.start(EndedForGoodReminder, %{})
      assert_eventually(fn -> Probe.hits(:held) == 1 end)
      :telemetry.detach(handler)
      stop_supervised!(Durable)

      start_durable!(%{default: 1})
      assert_eventually(fn -> get(id).status in [:completed, :failed] end, 5_000)

      assert {get(id).status, Probe.hits(:texted)} == {:failed, 1}
    end
  end

  describe "a node that stops after a child's step cancelled its root" do
    test "cancels the root on the next node, without running the step again" do
      handler = "ended_for_good-root-#{System.unique_integer([:positive])}"
      :telemetry.attach(handler, [:durable, :step, :stop], &__MODULE__.hold/4, :cancelled)
      start_durable!(%{default: 2}, shutdown_grace_period: 0)

      {:ok, id} = Durable.start(EndedForGoodOrder, %{"order" => 1})
      assert_eventually(fn -> Probe.hits(:held) == 1 end)
      :telemetry.detach(handler)
      stop_supervised!(Durable)

      start_durable!(%{default: 2})
      ended = [:completed, :failed, :cancelled]
      assert_eventually(fn -> get(id).status in ended end, 5_000)

      [child] =
        IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^id))

      assert_eventually(fn -> get(child.id).status in ended end, 5_000)

      assert {Probe.hits(:packed), get(id).status, get(child.id).status} ==
               {1, :cancelled, :cancelled}
    end
  end
end
