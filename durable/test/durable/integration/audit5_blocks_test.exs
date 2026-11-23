defmodule Audit5BlocksRates do
  @moduledoc false
  use Durable
  use Durable.Helpers
  alias Durable.IntegrationProbe, as: Probe

  # Shipping rates from two carriers at once, then the cheaper is picked.
  workflow "audit5_blocks_rates" do
    parallel :rates do
      step :dhl, fn order ->
        Probe.note(:dhl)
        {:ok, assign(order, :price, 12)}
      end

      step :ups, fn order ->
        Probe.note(:ups)
        {:ok, assign(order, :price, 14)}
      end
    end

    step :pick, fn order ->
      cheapest =
        order["rates"] |> Enum.min_by(fn {_carrier, rate} -> rate["price"] end) |> elem(0)

      {:ok, assign(order, :carrier, cheapest)}
    end
  end
end

defmodule Audit5BlocksLabel do
  @moduledoc false
  use Durable
  use Durable.Helpers
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit5_blocks_label" do
    step :print, fn parcel ->
      Probe.note(:label_printed)
      {:ok, assign(parcel, :label, "L-#{parcel["parcel"]}")}
    end
  end
end

defmodule Audit5BlocksDispatch do
  @moduledoc false
  use Durable
  use Durable.Helpers
  use Durable.Orchestration
  alias Durable.IntegrationProbe, as: Probe

  # The label is printed by a workflow of its own, and the dispatch waits for it.
  workflow "audit5_blocks_dispatch" do
    step :label, fn parcel ->
      Probe.note(:label_step)

      case call_workflow(Audit5BlocksLabel, %{"parcel" => parcel["parcel"]}, ref: :label) do
        {:ok, printed} -> {:ok, assign(parcel, :label, printed["label"])}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The customer's receipt is sent on its own; the dispatch doesn't wait. The
  # node goes down once, just after the receipt was started.
  workflow "audit5_blocks_dispatch_notify" do
    step :notify, [retry: [max_attempts: 2, base: 1]], fn parcel ->
      {:ok, id} =
        start_workflow(Audit5BlocksLabel, %{"parcel" => parcel["parcel"]}, ref: :receipt)

      if Probe.note(:notified) == 1, do: Process.exit(self(), :kill)
      {:ok, assign(parcel, :receipt, id)}
    end
  end
end

defmodule Audit5BlocksPickup do
  @moduledoc false
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "audit5_blocks_pickup" do
    step :await_courier, fn parcel ->
      wait_for_input("picked_up")
      {:ok, assign(parcel, :picked_up, true)}
    end
  end
end

defmodule Audit5BlocksFulfil do
  @moduledoc false
  use Durable
  use Durable.Helpers
  use Durable.Orchestration

  # A label is printed, then the courier is waited for, each by a workflow of its own.
  workflow "audit5_blocks_fulfil" do
    step :label, fn order ->
      {:ok, printed} =
        call_workflow(Audit5BlocksLabel, %{"parcel" => order["parcel"]}, ref: :label)

      {:ok, assign(order, :label, printed["label"])}
    end

    step :pickup, fn order ->
      {:ok, picked} =
        call_workflow(Audit5BlocksPickup, %{"parcel" => order["parcel"]}, ref: :pickup)

      {:ok, assign(order, :picked_up, picked["picked_up"])}
    end
  end
end

defmodule Durable.Integration.Audit5BlocksTest do
  @moduledoc """
  Audit 5: parallel blocks and child workflows with live pollers, killed at
  the worst moment and raced against each other.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Executor

  @moduletag :capture_log

  # Kills the process running `step` at one of its telemetry events, once.
  def kill_once(_event, _measurements, %{step: step}, step) do
    if Probe.note(:killed) == 1, do: Process.exit(self(), :kill)
  end

  def kill_once(_event, _measurements, _meta, _step), do: :ok

  defp kill_at!(event, step) do
    handler = "audit5-blocks-kill-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, event, &__MODULE__.kill_once/4, step)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp children(id),
    do: IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^id))

  # A lane of one step starts at its own name, which is also its step's. Read
  # as a lane that hadn't started, it ran its step again, though the step's
  # row said it had finished.
  test "a one-step lane killed after its step's row was written doesn't run the step again" do
    kill_at!([:durable, :step, :stop], :rates__dhl)
    start_durable!(%{default: 2})

    {:ok, id} = Durable.start(Audit5BlocksRates, %{"order" => "O-1"})
    run = await_status(id, :completed)

    # The step's end event fires each time it runs: once, killed there.
    assert Probe.hits(:killed) == 1
    assert {Probe.hits(:dhl), Probe.hits(:ups)} == {1, 1}
    assert run.context["carrier"] == "dhl"
  end

  # The child was inserted before the parent recorded it, so a parent lost in
  # between started a second child when its step ran again.
  test "a parent killed right after call_workflow started its child doesn't start another" do
    kill_at!([:durable, :step, :stop], :label)
    start_durable!(%{default: 2})

    {:ok, id} = Durable.start(Audit5BlocksDispatch, %{"parcel" => "P-7"})
    run = await_status(id, :completed)

    assert Probe.hits(:killed) >= 1
    assert run.context["label"] == "L-P-7"
    assert [%{status: :completed}] = children(id)
    assert Probe.hits(:label_printed) == 1
  end

  test "a parent killed right after start_workflow started its child doesn't start another" do
    start_durable!(%{default: 2})

    {:ok, id} =
      Durable.start(Audit5BlocksDispatch, %{"parcel" => "P-8"},
        workflow: "audit5_blocks_dispatch_notify"
      )

    run = await_status(id, :completed)
    assert Probe.hits(:notified) == 2
    assert [%{id: child_id}] = children(id)
    assert run.context["receipt"] == child_id
  end

  # Holds a process that asked for it right after a query of its that
  # `matches?`, until the test says :go. What a slow connection or a long pause
  # does to it, at exactly that point.
  def hold(_event, _measurements, meta, test) do
    with matches? when is_function(matches?) <- Process.get(:audit5_hold),
         true <- matches?.(meta) do
      Process.delete(:audit5_hold)
      send(test, {:held, self()})
      receive do: (:go -> :ok)
    end
  end

  defp holding(matches?, fun) do
    Task.async(fn ->
      Process.put(:audit5_hold, matches?)
      fun.()
    end)
  end

  defp held! do
    assert_receive {:held, pid}, 5_000
    pid
  end

  # After its wait is written: an insert into pending_events, then a commit.
  defp after_wait_committed(meta) do
    if meta.source == "pending_events" and meta.query =~ "INSERT",
      do: Process.put(:audit5_wrote_wait, true)

    meta.query == "commit" and Process.get(:audit5_wrote_wait) == true
  end

  # The child's notice, as it reads that its parent waits for it.
  defp read_parent_waits(child_id),
    do: &(&1.source == "pending_events" and "__child_done:#{child_id}" in &1.params)

  # The child finishes as the parent writes its wait, so both the child and the
  # parent tell the parent. The child's notice read that the parent waited and
  # was then slow, and by the time it took the parent's row the parent had its
  # first child's result and waited on its second. The late notice resumed it
  # anyway, from a wait it wasn't in: its second child's wait was still open,
  # so the parent's step couldn't wait on it again and its worker crashed.
  test "a child's late notice doesn't resume a parent that has moved on to another wait" do
    Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)
    config = Durable.Config.get(Durable)
    handler = "audit5-blocks-hold-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:durable, :integration_repo, :query], &__MODULE__.hold/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, id} = Durable.start(Audit5BlocksFulfil, %{"parcel" => "P-3"})
    parent = holding(&after_wait_committed/1, fn -> Executor.execute_workflow(id, config) end)
    parent_pid = held!()
    [label] = children(id)

    child =
      holding(read_parent_waits(label.id), fn -> Executor.execute_workflow(label.id, config) end)

    child_pid = held!()

    # The parent reads that its child finished, and goes on to its second.
    send(parent_pid, :go)
    Task.await(parent)
    assert get(id).status == :pending
    {:waiting, _} = Executor.execute_workflow(id, config)
    assert %{status: :waiting, current_step: "pickup"} = get(id)

    send(child_pid, :go)
    Task.await(child)
    assert get(id).status == :waiting

    [pickup] = Enum.reject(children(id), &(&1.id == label.id))
    {:waiting, _} = Executor.execute_workflow(pickup.id, config)
    :ok = Durable.provide_input(pickup.id, "picked_up", %{})
    {:ok, _} = Executor.execute_workflow(pickup.id, config)
    {:ok, _} = Executor.execute_workflow(id, config)
    assert %{status: :completed, context: %{"label" => "L-P-3", "picked_up" => true}} = get(id)
  end

  def hold_parent(_event, _measurements, %{step: :label}, ms), do: Process.sleep(ms)
  def hold_parent(_event, _measurements, _meta, _ms), do: :ok

  # The child is on the queue as soon as it's inserted, and finishes before
  # the parent has written its wait. Whichever of the two goes second must see
  # the other, at every gap between them.
  test "a child that finishes before its parent waits for it still wakes the parent" do
    start_durable!(%{default: 4}, poll_interval: 5)

    for ms <- [0, 1, 2, 4, 8, 15, 30, 60] do
      handler = "audit5-blocks-hold-#{ms}"
      :telemetry.attach(handler, [:durable, :step, :stop], &__MODULE__.hold_parent/4, ms)
      on_exit(fn -> :telemetry.detach(handler) end)

      ids =
        for n <- 1..4 do
          {:ok, id} = Durable.start(Audit5BlocksDispatch, %{"parcel" => "#{ms}-#{n}"})
          id
        end

      for id <- ids, do: assert(await_status(id, :completed, 15_000).context["label"] =~ "L-")
      :telemetry.detach(handler)
    end
  end
end
