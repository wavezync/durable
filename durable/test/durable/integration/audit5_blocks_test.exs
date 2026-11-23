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

defmodule Audit5BlocksFraudReview do
  @moduledoc false
  use Durable
  use Durable.Helpers
  use Durable.Wait

  # A reviewer looks at the payment and says whether it's good.
  workflow "audit5_blocks_fraud_review" do
    step :review, fn payment ->
      verdict = wait_for_input("fraud_verdict")
      {:ok, assign(payment, :verdict, verdict)}
    end
  end
end

defmodule Audit5BlocksCheckout do
  @moduledoc false
  use Durable
  use Durable.Helpers
  use Durable.Orchestration
  use Durable.Wait
  alias Durable.IntegrationProbe, as: Probe

  # Stock, the customer's address and a fraud review are checked at once. The
  # address is confirmed by the customer, and the review is a workflow of its
  # own that waits for a reviewer. Stock answers last: there is none.
  workflow "audit5_blocks_checkout" do
    parallel :checks do
      step :stock, fn _order ->
        Probe.wait_for(:others_waiting)
        {:fail, "out of stock"}
      end

      step :address, fn order ->
        wait_for_input("address_confirmed")
        {:ok, assign(order, :address_ok, true)}
      end

      step :fraud, fn order ->
        case call_workflow(Audit5BlocksFraudReview, %{"order" => order["order"]}, ref: :fraud) do
          {:ok, review} -> {:ok, assign(order, :verdict, review["verdict"])}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  # Price and stock at once, and a shipping quote from a partner's service,
  # which has a queue of its own. The order goes on without the quote if the
  # partner takes too long.
  workflow "audit5_blocks_quote" do
    parallel :quote do
      step :price, fn order -> {:ok, assign(order, :price, 40)} end
      step :stock, fn order -> {:ok, assign(order, :in_stock, true)} end

      lane :shipping, optional: true, timeout: 300 do
        step :ask_partner, [queue: :partner], fn order -> {:ok, assign(order, :cost, 5)} end
      end
    end

    step :confirm, fn order -> {:ok, order} end
  end

  # Two carriers quote at once. Both are down until someone says they're back.
  workflow "audit5_blocks_carriers" do
    parallel :rates do
      step :dhl, fn order ->
        if Probe.set?(:carriers_up),
          do: {:ok, assign(order, :price, 12)},
          else: {:fail, "DHL is down"}
      end

      step :ups, fn order ->
        if Probe.set?(:carriers_up),
          do: {:ok, assign(order, :price, 14)},
          else: {:fail, "UPS is down"}
      end
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
  alias Durable.Queue.StaleJobRecovery
  alias Durable.Storage.Schemas.PendingInput
  alias Durable.Wait.TimeoutWorker

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
    assert [%{status: :completed, id: child_id}] = children(id)
    assert Probe.hits(:label_printed) == 1

    # Which step called the child was only in the process that was killed.
    assert %{^child_id => %{"step_name" => "label", "kind" => "call"}} =
             run.engine_state["__call_children"]
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

    assert %{^child_id => %{"step_name" => "notify", "kind" => "fire"}} =
             run.engine_state["__call_children"]
  end

  # Holds a process that asked for it right after a query of its that
  # `matches?`, until the test says :go. What a slow connection or a long pause
  # does to it, at exactly that point.
  def hold(_event, _measurements, meta, test) do
    with matches? when is_function(matches?) <- Process.get(:audit5_hold),
         true <- matches?.(meta) do
      # Where to hold it next, if anywhere.
      Process.put(:audit5_hold, Process.delete(:audit5_hold_next))
      send(test, {:held, self()})
      receive do: (:go -> :ok)
    end
  end

  defp holding(matches?, next \\ nil, fun) do
    Task.async(fn ->
      Process.put(:audit5_hold, matches?)
      Process.put(:audit5_hold_next, next)
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

  defp lane(id, name),
    do: Enum.find(children(id), &String.ends_with?(&1.engine_state["__parallel_step"], name))

  defp open_inputs(run_id) do
    IntegrationRepo.aggregate(
      from(p in PendingInput, where: p.workflow_id == ^run_id and p.status == :pending),
      :count
    )
  end

  # Kills the process that stopped a block, right after the commit that
  # cancelled the other lanes: before it has closed anything of theirs.
  def kill_after_stopping_block(_event, _measurements, meta, _config) do
    if Enum.any?(meta.params, &match?(%{message: "another branch" <> _}, &1)),
      do: Process.put(:audit5_stopped_block, true)

    if meta.query == "commit" and Process.get(:audit5_stopped_block) do
      Probe.note(:killed_after_stopping)
      Process.exit(self(), :kill)
    end
  end

  # The lane that failed cancelled the others in the transaction that told the
  # block, and closed what they had open afterwards, from its own process.
  # Lost in between, nobody did: the customer was still asked for the address
  # and the fraud review ran on, for an order that had failed.
  test "lanes cancelled by a lane whose worker then dies get their inputs and children closed" do
    handler = "audit5-blocks-kill-#{System.unique_integer([:positive])}"
    event = [:durable, :integration_repo, :query]
    :telemetry.attach(handler, event, &__MODULE__.kill_after_stopping_block/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
    start_durable!(%{default: 4}, stale_lock_timeout: 1)

    {:ok, id} = Durable.start(Audit5BlocksCheckout, %{"order" => "O-9"})

    assert_eventually(fn ->
      fraud = lane(id, "fraud")
      address = lane(id, "address")

      fraud != nil and address.status == :waiting and
        match?([%{status: :waiting}], children(fraud.id))
    end)

    address = lane(id, "address")
    [review] = children(lane(id, "fraud").id)
    assert {open_inputs(address.id), open_inputs(review.id)} == {1, 1}

    Probe.set(:others_waiting)
    assert %{error: %{"message" => "out of stock"}} = await_status(id, :failed)
    assert Probe.hits(:killed_after_stopping) == 1
    assert %{status: :cancelled} = get(address.id)

    # The sweep is what's left to close them.
    Process.sleep(1_100)
    StaleJobRecovery.recover_now(Durable)

    assert open_inputs(address.id) == 0
    assert %{status: :cancelled} = get(review.id)
    assert open_inputs(review.id) == 0
  end

  # The partner's queue has no node. The sweep moves a run past its deadline
  # off such a queue, to be failed where a worker can claim it, but left every
  # lane where it was: the block waited for the quote for ever.
  test "a lane past its own timeout on a queue no node polls is failed, and the block goes on" do
    start_durable!(%{default: 2})

    {:ok, id} = Durable.start(Audit5BlocksCheckout, %{}, workflow: "audit5_blocks_quote")

    assert_eventually(fn ->
      match?(%{status: :pending, queue: "partner"}, lane(id, "shipping"))
    end)

    Process.sleep(350)
    TimeoutWorker.check_timeouts(Durable)

    run = await_status(id, :completed)
    assert %{"price" => %{"price" => 40}, "shipping" => nil} = run.context["quote"]

    assert %{status: :failed, error: %{"type" => "timeout", "message" => message}} =
             lane(id, "shipping")

    assert message =~ "lane shipping passed its 300ms timeout"
  end

  # The lane's notice, as it reads that its block waits for it.
  defp read_block_waits(lane_id),
    do: &(&1.source == "pending_events" and "__parallel_done:#{lane_id}" in &1.params)

  defp statuses(ids), do: Enum.map(ids, &get(&1).status)

  # Both carriers fail at once. DHL's notice ends the block; UPS's has read
  # that the block waits for it and is slow. The block fails, the carriers
  # come back and an operator retries: both lanes run again and the block
  # waits for them, on the same events. UPS's old notice then arrived as its
  # new answer: the block was stopped again, on a failure from before the retry.
  test "a lane's notice from before its block was retried doesn't fail the block again" do
    Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)
    config = Durable.Config.get(Durable)
    handler = "audit5-blocks-hold-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:durable, :integration_repo, :query], &__MODULE__.hold/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, id} = Durable.start(Audit5BlocksCheckout, %{}, workflow: "audit5_blocks_carriers")
    {:waiting, _} = Executor.execute_workflow(id, config)
    [dhl, ups] = [lane(id, "dhl"), lane(id, "ups")]

    notice =
      holding(read_block_waits(ups.id), fn -> Executor.execute_workflow(ups.id, config) end)

    notice_pid = held!()
    assert get(ups.id).status == :failed

    {:error, _} = Executor.execute_workflow(dhl.id, config)
    {:error, _} = Executor.execute_workflow(id, config)
    assert get(id).status == :failed

    Probe.set(:carriers_up)
    {:ok, _} = Durable.retry(id)
    assert statuses([id, dhl.id, ups.id]) == [:waiting, :pending, :pending]

    send(notice_pid, :go)
    Task.await(notice)
    assert statuses([id, dhl.id, ups.id]) == [:waiting, :pending, :pending]

    {:ok, _} = Executor.execute_workflow(dhl.id, config)
    {:ok, _} = Executor.execute_workflow(ups.id, config)
    {:ok, _} = Executor.execute_workflow(id, config)

    assert %{status: :completed, context: %{"rates" => rates}} = get(id)
    assert %{"dhl" => %{"price" => 12}, "ups" => %{"price" => 14}} = rates
  end

  # The notice, once it has taken its block's row.
  defp locked_block(meta),
    do: meta.source == "workflow_executions" and meta.query =~ "FOR UPDATE"

  # The retry wrote the lanes and their events before it took the block's
  # row, and the notice takes the row first: each then waited for the other,
  # and Postgres ended one of them.
  test "a block retried while a lane's notice has its row waits for the notice" do
    Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)
    config = Durable.Config.get(Durable)
    handler = "audit5-blocks-hold-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:durable, :integration_repo, :query], &__MODULE__.hold/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, id} = Durable.start(Audit5BlocksCheckout, %{}, workflow: "audit5_blocks_carriers")
    {:waiting, _} = Executor.execute_workflow(id, config)
    [dhl, ups] = [lane(id, "dhl"), lane(id, "ups")]

    # UPS fails and is slow to say so, twice: before and after it takes the row.
    notice =
      holding(read_block_waits(ups.id), &locked_block/1, fn ->
        Executor.execute_workflow(ups.id, config)
      end)

    notice_pid = held!()
    {:error, _} = Executor.execute_workflow(dhl.id, config)
    {:error, _} = Executor.execute_workflow(id, config)
    send(notice_pid, :go)
    ^notice_pid = held!()

    Probe.set(:carriers_up)
    retry = Task.async(fn -> Durable.retry(id) end)
    # Long enough for the retry to get as far as it can without the row.
    Process.sleep(200)
    send(notice_pid, :go)

    Task.await(notice)
    assert {:ok, _} = Task.await(retry)
    assert statuses([id, dhl.id, ups.id]) == [:waiting, :pending, :pending]

    {:ok, _} = Executor.execute_workflow(dhl.id, config)
    {:ok, _} = Executor.execute_workflow(ups.id, config)
    {:ok, _} = Executor.execute_workflow(id, config)
    assert get(id).status == :completed
  end
end
