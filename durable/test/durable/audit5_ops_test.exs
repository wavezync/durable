defmodule Durable.Audit5OpsTest do
  @moduledoc "Audit 5: rollback, workflow keys, cancellation and the operator API."
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  @test_process :audit5_ops_test

  defmodule Audit5OpsReindex do
    use Durable
    use Durable.Wait

    # The search alias moves to the new index, then the cache is warmed.
    workflow "a5_reindex", on_duplicate: :run_again do
      step :swap_alias, [compensate: :restore_alias], fn catalog -> {:ok, catalog} end

      step :warm_cache, fn catalog ->
        case wait_for_event("warmed") do
          %{"failed" => true} -> {:fail, "cache cluster down"}
          _ -> {:ok, catalog}
        end
      end

      compensate :restore_alias, fn catalog -> {:ok, catalog} end
    end
  end

  defmodule Audit5OpsOrder do
    use Durable

    workflow "a5_order", on_failure: :rollback do
      step :charge_card, [compensate: :refund], fn order -> {:ok, order} end
      step :ship, fn _order -> {:error, "warehouse closed"} end

      # The operator clicks "run again" while the refund is going.
      compensate :refund, fn order ->
        send(:audit5_ops_test, {:rerun, Durable.rerun(Durable.Context.workflow_id())})
        {:ok, order}
      end
    end

    workflow "a5_refund_hangs", on_failure: :rollback do
      step :charge_card, [compensate: :refund], fn order -> {:ok, order} end
      step :ship, fn _order -> {:error, "warehouse closed"} end

      # The payment provider never answers.
      compensate :refund,
                 [timeout: 200, retry: [max_attempts: 2, backoff: :constant, base: 10]],
                 fn order ->
                   send(:audit5_ops_test, :refunding)
                   Process.sleep(:infinity)
                   {:ok, order}
                 end
    end

    workflow "a5_refund_flaky", on_failure: :rollback do
      step :charge_card, [compensate: :refund], fn order -> {:ok, order} end
      step :ship, fn _order -> {:error, "warehouse closed"} end

      # Under a time limit, a raise is still an attempt that failed.
      compensate :refund,
                 [timeout: 1_000, retry: [max_attempts: 2, backoff: :constant, base: 10]],
                 fn order ->
                   if Agent.get_and_update(:a5_refund_tries, &{&1 + 1, &1 + 1}) == 1,
                     do: raise("gateway reset")

                   send(:audit5_ops_test, {:refunded, order["order"]})
                   {:ok, order}
                 end
    end

    workflow "a5_hold_then_charge" do
      step :hold_seat, [compensate: :release_seat], fn trip -> {:ok, trip} end

      step :charge_card, fn trip ->
        send(:audit5_ops_test, {:charging, self()})
        receive do: (:never -> {:ok, trip})
      end

      compensate :release_seat, fn trip ->
        send(:audit5_ops_test, :released)
        {:ok, trip}
      end
    end
  end

  setup do
    Process.register(self(), @test_process)
    :ok
  end

  defp get(id), do: TestRepo.get!(WorkflowExecution, id)

  defp step_status(id, step) do
    TestRepo.one!(
      from(s in StepExecution,
        where: s.workflow_id == ^id and s.step_name == ^step,
        select: s.status
      )
    )
  end

  test "run_again: a start while the holder is being rolled back gives the waiting run its input" do
    holder = run_workflow(Audit5OpsReindex, %{"rev" => 1}, key: "catalog:shoes")
    {:ok, waiting} = Durable.start(Audit5OpsReindex, %{"rev" => 2}, key: "catalog:shoes")

    :ok = Durable.send_event(holder.id, "warmed", %{"failed" => true})
    assert drain(holder).status == :failed
    # Rolled back, the holder lets the key go before it's undone.
    {:ok, _} = Durable.rollback(holder.id)

    {:ok, third} = Durable.start(Audit5OpsReindex, %{"rev" => 3}, key: "catalog:shoes")

    assert third == waiting, "a new run was started beside the one waiting"
    assert get(waiting).input == %{"rev" => 3}

    # Once the old index is restored, the newest rev is the one built.
    assert drain(holder).status == :compensated
    run = drain(waiting)
    assert {run.status, run.holds_key, run.input} == {:waiting, true, %{"rev" => 3}}
  end

  test "rerun is refused while the run is being rolled back" do
    {:ok, id} = Durable.start(Audit5OpsOrder, %{"order" => "ORD-1043"}, workflow: "a5_order")
    assert drain(id).status == :compensated

    assert_received {:rerun, rerun}
    assert rerun == {:error, :not_finished}
  end

  test "a compensation's timeout: stops an attempt that hangs, and the rollback ends" do
    {:ok, id} =
      Durable.start(Audit5OpsOrder, %{"order" => "ORD-1043"}, workflow: "a5_refund_hangs")

    task = Task.async(fn -> drain(id) end)
    assert {:ok, run} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)

    assert run.status == :compensation_failed
    assert_received :refunding
    assert_received :refunding

    attempts =
      TestRepo.all(
        from(s in StepExecution,
          where: s.workflow_id == ^id and s.is_compensation,
          order_by: s.attempt,
          select: {s.attempt, s.status, s.error["type"]}
        )
      )

    assert attempts == [{1, :failed, "timeout"}, {2, :failed, "timeout"}]
  end

  test "a compensation with a timeout: that raises uses its retries, and sees the run's data" do
    start_supervised!(%{
      id: :tries,
      start: {Agent, :start_link, [fn -> 0 end, [name: :a5_refund_tries]]}
    })

    {:ok, id} =
      Durable.start(Audit5OpsOrder, %{"order" => "ORD-1043"}, workflow: "a5_refund_flaky")

    assert drain(id).status == :compensated
    assert_received {:refunded, "ORD-1043"}

    assert TestRepo.all(
             from(s in StepExecution,
               where: s.workflow_id == ^id and s.is_compensation,
               order_by: s.attempt,
               select: {s.status, s.error["message"]}
             )
           ) == [{:failed, "gateway reset"}, {:completed, nil}]
  end

  test "a rollback of a run with a step only an older deploy had makes no atom of its name" do
    {:ok, id} = Durable.start(Audit5OpsOrder, %{"order" => "ORD-1043"}, workflow: "a5_order")
    # The node that ran the first attempt had a step this code has since dropped.
    old_name = "pick_warehouse_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    TestRepo.insert!(%StepExecution{
      workflow_id: id,
      step_name: old_name,
      step_type: "step",
      attempt: 1,
      status: :completed,
      started_at: now,
      completed_at: now
    })

    assert Durable.rollback_plan(id) == {:ok, []}
    assert drain(id).status == :compensated
    # The refund ran: the step this code has is undone, the one it hasn't is skipped.
    assert_received {:rerun, _}
    assert_raise ArgumentError, fn -> String.to_existing_atom(old_name) end
  end

  test "cancel with rollback: true on a run whose worker is gone closes its step as the undo starts" do
    config = Config.get(Durable)

    {:ok, id} =
      Durable.start(Audit5OpsOrder, %{"flight" => "LH 401"}, workflow: "a5_hold_then_charge")

    worker = spawn(fn -> Executor.execute_workflow(id, config) end)
    assert_receive {:charging, _step}, 5_000

    :ok = Durable.cancel(id, "traveller cancelled", rollback: true)
    # The worker could still finish the step, so it stays open for it...
    assert step_status(id, "charge_card") == :running

    # ...but its node goes down, and the undo runs on another.
    Process.exit(worker, :kill)
    Executor.execute_workflow(id, config)

    assert get(id).status == :compensated
    assert step_status(id, "charge_card") == :cancelled
    assert_received :released
  end
end
