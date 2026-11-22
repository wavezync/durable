defmodule Durable.Audit4ExecBugsTest do
  @moduledoc """
  Audit 4, executor: what the audit found broken. A test still tagged `:skip`
  fails without it, and the line above the tag says why.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Storage.Schemas.WorkflowExecution
  alias Durable.TestRepo, as: Repo

  @moduletag :capture_log

  defmodule Audit4ExecBugSeen do
    @moduledoc false
    def put(key, value), do: :persistent_term.put({__MODULE__, key}, value)
    def get(key), do: :persistent_term.get({__MODULE__, key}, nil)
    def hit(key), do: put(key, (get(key) || 0) + 1)

    def clear do
      for {{__MODULE__, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    end
  end

  defmodule Audit4ExecBugCharge do
    @moduledoc false
    use Durable
    use Durable.Wait

    # The card is charged once the bank confirms. An hour is long enough.
    workflow "audit4_charge", timeout: hours(1) do
      step(:await_bank, fn payment ->
        Audit4ExecBugSeen.hit(:charge_started)
        wait_for_event("bank_confirmed")
        {:ok, Map.put(payment, "paid", true)}
      end)
    end
  end

  defmodule Audit4ExecBugOrders do
    @moduledoc false
    use Durable
    use Durable.Helpers
    use Durable.Wait
    use Durable.Orchestration

    def stored_now, do: Repo.get!(WorkflowExecution, Durable.Context.workflow_id()).context

    # An order arrives as the webhook sent it and is carried from step to step.
    workflow "audit4_order" do
      step(:receive_order, fn order -> {:ok, assign(order, :received, true)} end)

      step(:pack, fn order ->
        Audit4ExecBugSeen.hit(:packed)
        {:ok, assign(order, :packed, true)}
      end)
    end

    workflow "audit4_order_held" do
      step(:reserve_stock, [compensate: :release_stock], fn order ->
        {:ok, assign(order, :reserved, true)}
      end)

      step(:cool_off, fn order ->
        sleep(seconds(1))
        {:ok, order}
      end)

      step(:pack, fn order ->
        Audit4ExecBugSeen.hit(:packed)
        {:ok, order}
      end)

      compensate(:release_stock, fn order ->
        Audit4ExecBugSeen.hit(:stock_released)
        {:ok, order}
      end)
    end

    workflow "audit4_order_paid" do
      step(:receive_order, fn order -> {:ok, assign(order, :received, true)} end)

      step(:take_payment, fn order ->
        with {:ok, payment} <- call_workflow(Audit4ExecBugCharge, %{"total" => 40}, ref: :charge) do
          {:ok, assign(order, :payment, payment)}
        end
      end)
    end

    workflow "audit4_order_checked" do
      step(:receive_order, fn order -> {:ok, assign(order, :received, true)} end)

      parallel :checks do
        step(:address, fn order ->
          Audit4ExecBugSeen.hit(:address_checked)
          {:ok, assign(order, :address_ok, true)}
        end)
      end

      step(:pack, fn order -> {:ok, order} end)
    end

    # The whole order has an hour, and so does the charge it calls.
    workflow "audit4_order_within_the_hour", timeout: hours(1) do
      step(:take_payment, fn order ->
        with {:ok, payment} <- call_workflow(Audit4ExecBugCharge, %{"total" => 40}) do
          {:ok, assign(order, :payment, payment)}
        end
      end)
    end

    workflow "audit4_order_with_receipt" do
      step(:send_receipt, fn order ->
        {:ok, _id} = start_workflow(Audit4ExecBugCharge, %{"total" => 40})
        {:ok, order}
      end)
    end

    # The card is charged while the stock is counted.
    workflow "audit4_order_counted" do
      parallel :prepare do
        step(:charge, fn _order ->
          with {:ok, payment} <- call_workflow(Audit4ExecBugCharge, %{"total" => 40}) do
            {:ok, %{payment: payment}}
          end
        end)

        step(:count_stock, fn _order ->
          if Audit4ExecBugSeen.get(:stock_out), do: {:fail, "out of stock"}, else: {:ok, %{}}
        end)
      end
    end

    # The courier is asked for a quote while the warehouse waits for a picker.
    workflow "audit4_dispatch" do
      parallel :arrange do
        lane :courier do
          step(:quote, fn _parcel ->
            {:cancel, "the courier doesn't serve this area", scope: :run}
          end)
        end

        lane :warehouse do
          step(:await_picker, fn parcel ->
            wait_for_input("picked")
            {:ok, parcel}
          end)
        end
      end
    end

    workflow "audit4_refund" do
      decision(:route, fn refund ->
        {:goto, :pay_out, Map.update(refund, "routed", 1, &(&1 + 1))}
      end)

      step(:ask_manager, fn refund -> {:ok, refund} end)

      step(:pay_out, fn refund ->
        Audit4ExecBugSeen.put(:stored_after_route, Audit4ExecBugOrders.stored_now())
        {:ok, refund}
      end)
    end

    workflow "audit4_parcel" do
      branch on: fn parcel -> parcel["size"] end do
        "large" ->
          step(:weigh, fn parcel -> {:ok, Map.update(parcel, "weighed", 1, &(&1 + 1))} end)

          step(:book_lorry, fn parcel ->
            Audit4ExecBugSeen.put(:stored_after_weigh, Audit4ExecBugOrders.stored_now())
            {:ok, parcel}
          end)

        _ ->
          step(:post, fn parcel -> {:ok, parcel} end)
      end
    end

    workflow "audit4_claim" do
      decision(:triage, fn claim -> {:goto, String.to_existing_atom(claim["to"]), claim} end)

      branch :risk, fn claim -> {:clear, claim} end do
        :clear ->
          step(:pay, fn claim -> {:ok, assign(claim, :paid, true)} end)

        :review ->
          step(:ask_assessor, fn claim -> {:ok, assign(claim, :asked, true)} end)

        :blocked ->
          step(:refuse, fn claim -> {:ok, assign(claim, :refused, true)} end)
      end

      parallel :notify do
        lane :customer do
          step(:email, fn claim -> {:ok, assign(claim, :emailed, true)} end)
        end

        lane :broker do
          step(:letter, fn claim -> {:ok, assign(claim, :lettered, true)} end)
        end
      end

      step(:close, fn claim -> {:ok, claim} end)
    end

    workflow "audit4_trip", on_failure: :rollback do
      step(:book_flight, [compensate: :cancel_flight], fn trip ->
        {:ok, Map.put(trip, "id", "FL-123")}
      end)

      parallel :checks do
        step(:visa, fn _trip -> {:fail, "no visa"} end)
      end

      compensate(:cancel_flight, fn trip ->
        Audit4ExecBugSeen.put(:cancelled_flight, trip["id"])
        {:ok, trip}
      end)
    end

    workflow "audit4_trip_halts" do
      step(:book_flight, [compensate: :cancel_flight], fn trip ->
        {:ok, Map.put(trip, "id", "FL-123")}
      end)

      step(:charge_card, fn _trip -> {:fail, "card declined"} end)

      compensate(:cancel_flight, fn trip ->
        Audit4ExecBugSeen.put(:cancelled_flight, trip["id"])
        {:ok, trip}
      end)
    end
  end

  setup do
    Audit4ExecBugSeen.clear()
    on_exit(&Audit4ExecBugSeen.clear/0)
  end

  defp order(input, workflow), do: run_workflow(Audit4ExecBugOrders, input, workflow: workflow)
  defp reload(run), do: Repo.get!(WorkflowExecution, run.id)

  defp children(run),
    do: Repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^run.id))

  # A run stored as it is when its worker is lost right after a step's result
  # was saved: still at that step, with what the save wrote.
  defp lost_after(workflow, step, stored) do
    {:ok, run} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(%{
        workflow_module: Atom.to_string(Audit4ExecBugOrders),
        workflow_name: workflow,
        status: :pending,
        queue: "default",
        input: %{},
        context: stored,
        current_step: step
      })
      |> Repo.insert()

    drain(run)
  end

  describe "a start's input that uses one of the engine's own context keys" do
    # The input is the first step's data and is saved as the run's context, where
    # the engine keeps its own state under `__` keys and trusts what it finds:
    # executor.ex:1266 (resume_failure/1) fails the run on a "__fail__" it never wrote.
    # Suspected root: executor.ex:92 (storable_input/1) and :2455 (save_data_as_context/5)
    # store reserved keys from user data unchanged.
    @tag :skip
    test "can't fail the run with an error of its choosing" do
      run = order(%{"__fail__" => %{"type" => "forged", "message" => "x"}}, "audit4_order")

      assert run.status == :completed
      assert Audit4ExecBugSeen.get(:packed) == 1
    end

    # executor.ex:909 (run_execution/3) rolls back any run whose context has
    # "__rollback__", and here the input put it there: the next claim undoes the
    # run and ends it :cancelled, :failed or :compensated, as the input says.
    @tag :skip
    test "can't have the run rolled back" do
      forged = %{"error" => %{"type" => "forged"}, "status" => "cancelled"}
      run = order(%{"__rollback__" => forged}, "audit4_order_held")

      assert run.status == :completed
      assert Audit4ExecBugSeen.get(:stock_released) == nil
      assert Audit4ExecBugSeen.get(:packed) == 1
    end

    # orchestration.ex:100 (call_workflow/3) takes "__child_done:<ref>" in the
    # context for the child's result, so the child is never started.
    @tag :skip
    test "can't stand in for a child workflow's result" do
      forged = %{"status" => "completed", "result" => %{"paid" => true, "forged" => true}}
      run = order(%{"__child_done:charge" => forged}, "audit4_order_paid")

      assert Audit4ExecBugSeen.get(:charge_started) == 1
      assert run.status == :waiting
      refute run.context["payment"]["forged"]
    end

    # executor.ex:1923 (execute_parallel/7) takes "__parallel_children" in the
    # context for a block already fanned out, and :2164 (build_results_from_children/2)
    # reads the runs it names, another run's data included, and makes an atom of
    # the stored "returns_key" (rule 7).
    @tag :skip
    test "can't skip a parallel block and read another run's data through it" do
      other = order(%{"card" => "4111-secret"}, "audit4_order")

      lanes = %{other.id => %{"returns_key" => "audit4_forged_lane", "step_name" => "address"}}
      run = order(%{"__parallel_children" => lanes}, "audit4_order_checked")

      assert Audit4ExecBugSeen.get(:address_checked) == 1
      refute inspect(run.context) =~ "4111-secret"
    end
  end

  describe "a child workflow with a timeout:" do
    test "gets its deadline when call_workflow starts it" do
      run = order(%{}, "audit4_order_paid")
      assert [%{workflow_name: "audit4_charge", deadline_at: %DateTime{}}] = children(run)
    end

    test "gets its deadline when start_workflow starts it" do
      run = order(%{}, "audit4_order_with_receipt")
      assert [%{workflow_name: "audit4_charge", deadline_at: %DateTime{}}] = children(run)
    end

    # The block that stopped has no timeout, and the charge its lane called has an hour.
    test "gets all of it again, and not its caller's, when a retry puts it back" do
      Audit4ExecBugSeen.put(:stock_out, true)
      run = order(%{}, "audit4_order_counted")
      assert run.status == :failed

      Audit4ExecBugSeen.put(:stock_out, false)
      {:ok, _} = Durable.retry(run.id)
      assert drain(run).status == :waiting

      lane = Enum.find(children(run), &(&1.current_step == "prepare__charge"))
      assert lane.deadline_at == nil
      assert [%{status: :waiting, deadline_at: %DateTime{} = deadline}] = children(lane)
      assert_in_delta DateTime.diff(deadline, DateTime.utc_now()), 3600, 60
    end
  end

  # A run that times out while it waits for its child cancels the child
  # (executor.ex:1272, fail_at/5). Durable.retry/1 then reopens the run alone
  # (executor.ex:463, the last clause of reset_for_retry/2): its step finds the
  # child cancelled and the run fails again with "parent_cancelled", for ever.
  # A lane's child is put back by put_back/3 (executor.ex:650); this path isn't.
  @tag :skip
  test "a run that timed out waiting for its child can be retried" do
    run = order(%{}, "audit4_order_within_the_hour")
    assert run.status == :waiting

    # Its deadline passes, and the timeout sweep wakes it to fail.
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(from(w in WorkflowExecution, where: w.id == ^run.id),
      set: [deadline_at: past, status: :pending]
    )

    run = drain(run)
    assert %{status: :failed, error: %{"type" => "timeout"}} = run
    assert [%{status: :cancelled}] = children(run)

    {:ok, _} = Durable.retry(run.id)
    run = drain(run)

    assert run.status == :waiting, "retried, it ended #{run.status}: #{inspect(run.error)}"
    assert [%{status: :waiting}] = children(run)
  end

  # executor.ex:2747 (stop_block_on_failure/4) ends a fail-fast block only for
  # a lane that :failed. A lane that was cancelled (`{:cancel, _, scope: :run}`,
  # or Durable.cancel/2 on the lane's run) is an error to the block too, but
  # the block waits for every other lane first: here, for an input nobody gives.
  @tag :skip
  test "a cancelled lane ends a block that fails fast, as a failed lane does" do
    run = order(%{}, "audit4_dispatch")

    assert run.status == :failed
    assert Enum.all?(children(run), &(&1.status in [:cancelled, :failed]))
  end

  describe "a run lost right after a step's result was saved" do
    # executor.ex:1556 (handle_decision_result/8) saves a decision's `{:goto, _, data}`
    # without the `__done__` record a step's save has (executor.ex:1496), so the
    # run that comes back runs the decision again, on its own result.
    @tag :skip
    test "doesn't run a decision that jumped again" do
      assert order(%{}, "audit4_refund").context["routed"] == 1
      stored = Audit4ExecBugSeen.get(:stored_after_route)
      assert stored["routed"] == 1

      run = lost_after("audit4_refund", "route", stored)

      assert run.status == :completed
      assert run.context["routed"] == 1
    end

    # executor.ex:1853 (run_branch_step/6) saves the result of a step in a
    # `branch on:` clause without the record either.
    @tag :skip
    test "doesn't run a step of a `branch on:` clause again" do
      assert order(%{"size" => "large"}, "audit4_parcel").context["weighed"] == 1
      stored = Audit4ExecBugSeen.get(:stored_after_weigh)
      assert stored["weighed"] == 1

      {:ok, definition} = Audit4ExecBugOrders.__workflow_definition__("audit4_parcel")

      weigh =
        Enum.find_value(definition.steps, fn %{name: name} ->
          if String.ends_with?(Atom.to_string(name), "__weigh"), do: Atom.to_string(name)
        end)

      run = lost_after("audit4_parcel", weigh, stored)

      assert run.status == :completed
      assert run.context["weighed"] == 1
    end
  end

  describe "a jump from outside a block to a step inside it" do
    # executor.ex:2330 (find_jump_target/4) checks that the target exists and is
    # ahead, not where it is. The steps of every arm sit side by side in the
    # definition, so a run that lands in one arm runs on through the arms after it.
    @tag :skip
    test "doesn't run the steps of another arm" do
      run = order(%{"to" => "risk__review__ask_assessor"}, "audit4_claim")

      refute run.status == :completed and run.context["refused"],
             "ran the :blocked arm after the :review arm: #{inspect(run.context)}"
    end

    # The same jump into a lane runs every lane's steps in the block's own run,
    # one after another, and the block never happens: no lanes, no `notify` key.
    @tag :skip
    test "doesn't run a lane's steps in the block's run" do
      run = order(%{"to" => "notify__customer__email"}, "audit4_claim")

      refute run.status == :completed and children(run) == [],
             "the block's lanes ran as plain steps: #{inspect(run.context)}"
    end
  end

  # executor.ex:3215 (run_compensations/5): a run that fails as it resumes has
  # no data in its process, so the undo is handed `restore_keys(exec.context)`.
  # That context is the in-memory one, without the stored record of its key
  # shapes (save_data_as_context/5 returns it so, executor.ex:2468), and every
  # key the code knows as an atom becomes one. The same undo gets "id" when the
  # run fails in a step or is rolled back by hand (rule 10).
  @tag :skip
  test "an undo is handed the same data when the run fails as it resumes" do
    assert order(%{}, "audit4_trip").status == :compensated
    assert Audit4ExecBugSeen.get(:cancelled_flight) == "FL-123"
  end

  # executor.ex:223 (cancel_run/3) cancels any :pending run, and a failed run
  # queued by Durable.rollback/1 is :pending until a worker claims it. The
  # cancel ends it :cancelled with "__rollback__" still in its context:
  # nothing is undone, and it can no longer be rolled back or retried. A parent's
  # cancel reaches a child the same way (cancel_child_workflows/2, executor.ex:3026).
  @tag :skip
  test "cancelling a run that is waiting to be rolled back doesn't drop the rollback" do
    run = order(%{}, "audit4_trip_halts")
    assert run.status == :failed
    {:ok, _} = Durable.rollback(run.id)

    assert Durable.cancel(run.id) == {:error, :already_completed}

    assert drain(run).status == :compensated
    assert Audit4ExecBugSeen.get(:cancelled_flight) == "FL-123"
    refute is_map_key(reload(run).context, "__rollback__")
  end
end
