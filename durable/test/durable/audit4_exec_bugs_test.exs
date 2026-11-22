defmodule Durable.Audit4ExecBugsTest do
  @moduledoc """
  Audit 4, executor: what the audit found broken. A test still tagged `:skip`
  fails without it, and the line above the tag says why.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Storage.Schemas.PendingEvent
  alias Durable.Storage.Schemas.PendingInput
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

    def stored_now, do: Repo.get!(WorkflowExecution, Durable.Context.workflow_id())

    # A clause's step is named after its branch, which has no name of its own.
    def step_named(workflow, suffix) do
      {:ok, definition} = __workflow_definition__(workflow)

      Enum.find_value(definition.steps, fn %{name: name} ->
        if String.ends_with?(Atom.to_string(name), suffix), do: name
      end)
    end

    # A notice is posted, and the block then tries to post it again.
    workflow "audit4_notice" do
      parallel :send, into: fn notice, _sent -> {:goto, :send__post__stamp, notice} end do
        lane :post do
          step(:stamp, fn notice ->
            Audit4ExecBugSeen.hit(:posted)
            {:ok, notice}
          end)
        end
      end
    end

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

    # The surveyor has ten minutes for the whole visit, however long a room may take.
    workflow "audit4_survey" do
      parallel :visit do
        lane :surveyor, timeout: minutes(10) do
          parallel :rooms do
            lane :kitchen, timeout: hours(1) do
              step(:measure, fn _house ->
                if Audit4ExecBugSeen.get(:locked), do: {:fail, "locked"}, else: {:ok, %{}}
              end)
            end
          end
        end
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

    # Two pickers are asked, and the job needs both.
    workflow "audit4_pick" do
      parallel :pickers do
        step(:north, fn job ->
          wait_for_input("north_picked")
          {:ok, job}
        end)

        step(:south, fn job ->
          wait_for_input("south_picked")
          {:ok, job}
        end)
      end
    end

    workflow "audit4_pick_spare" do
      parallel :pickers do
        step(:north, fn job ->
          wait_for_input("north_picked")
          {:ok, job}
        end)

        lane :spare, optional: true do
          step(:stand_by, fn job ->
            wait_for_input("spare_picked")
            {:ok, job}
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

        "tiny" ->
          step(:slip_in, fn parcel ->
            {:goto, Audit4ExecBugOrders.step_named("audit4_parcel", "__queue_at_counter"), parcel}
          end)

        _ ->
          step(:frank, fn parcel ->
            {:goto, :hand_over, Map.update(parcel, "franked", 1, &(&1 + 1))}
          end)

          step(:queue_at_counter, fn parcel -> {:ok, Map.put(parcel, "queued", true)} end)
      end

      step(:hand_over, fn parcel ->
        Audit4ExecBugSeen.put(:stored_after_frank, Audit4ExecBugOrders.stored_now())
        {:ok, parcel}
      end)
    end

    workflow "audit4_refund_routed" do
      decision(:route, fn refund ->
        {:goto, String.to_atom(refund["to"]), Map.update(refund, "routed", 1, &(&1 + 1))}
      end)

      step(:ask_manager, fn refund -> {:ok, refund} end)
      step(:pay_out, fn refund -> {:ok, refund} end)
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

    # The trip is booked on its own, while the planner waits for the traveller.
    workflow "audit4_trip_planned" do
      step(:book, fn plan ->
        {:ok, _id} = start_workflow(__MODULE__, %{}, workflow: "audit4_trip_halts")
        {:ok, plan}
      end)

      step(:await_traveller, fn plan ->
        wait_for_input("approved")
        {:ok, plan}
      end)
    end

    workflow "audit4_trip_approved", on_failure: :rollback, timeout: hours(1) do
      step(:book_flight, [compensate: :cancel_flight], fn trip ->
        {:ok, Map.put(trip, "id", "FL-123")}
      end)

      step(:await_approval, fn trip ->
        wait_for_input("approved", on_timeout: :fail)
        {:ok, trip}
      end)

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

  defp order(input, workflow) when is_binary(workflow), do: order(input, workflow: workflow)
  defp order(input, opts), do: run_workflow(Audit4ExecBugOrders, input, opts)
  defp reload(run), do: Repo.get!(WorkflowExecution, run.id)

  defp clause_step(workflow, suffix),
    do: Atom.to_string(Audit4ExecBugOrders.step_named(workflow, suffix))

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
        context: stored.context,
        engine_state: stored.engine_state,
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
    test "can't fail the run with an error of its choosing" do
      run = order(%{"__fail__" => %{"type" => "forged", "message" => "x"}}, "audit4_order")

      assert run.status == :completed
      assert Audit4ExecBugSeen.get(:packed) == 1
    end

    # executor.ex:909 (run_execution/3) rolls back any run whose context has
    # "__rollback__", and here the input put it there: the next claim undoes the
    # run and ends it :cancelled, :failed or :compensated, as the input says.
    test "can't have the run rolled back" do
      forged = %{"error" => %{"type" => "forged"}, "status" => "cancelled"}
      run = order(%{"__rollback__" => forged}, "audit4_order_held")

      assert run.status == :completed
      assert Audit4ExecBugSeen.get(:stock_released) == nil
      assert Audit4ExecBugSeen.get(:packed) == 1
    end

    # orchestration.ex:100 (call_workflow/3) takes "__child_done:<ref>" in the
    # context for the child's result, so the child is never started.
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

  test "a retried lane inside a lane has no longer than the lane it is in" do
    Audit4ExecBugSeen.put(:locked, true)
    run = order(%{}, "audit4_survey")
    assert run.status == :failed

    Audit4ExecBugSeen.put(:locked, false)
    {:ok, _} = Durable.retry(run.id)

    [surveyor] = children(run)
    [kitchen] = children(surveyor)
    assert_in_delta DateTime.diff(surveyor.deadline_at, DateTime.utc_now()), 600, 60
    assert DateTime.compare(kitchen.deadline_at, surveyor.deadline_at) != :gt
  end

  # Its deadline passes, and the timeout sweep wakes it to fail, closing its waits.
  defp timed_out(run) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(from(w in WorkflowExecution, where: w.id == ^run.id),
      set: [deadline_at: past, status: :pending]
    )

    Repo.update_all(from(e in PendingEvent, where: e.workflow_id == ^run.id),
      set: [status: :timeout]
    )

    drain(run)
  end

  # A run that times out while it waits for its child cancels the child. A
  # retry that reopened the run alone had its step find the child cancelled,
  # and the run failed again with "parent_cancelled", for ever.
  for key <- [nil, "order-7"] do
    test "a run that timed out waiting for its child can be retried (key: #{inspect(key)})" do
      run = order(%{}, workflow: "audit4_order_within_the_hour", key: unquote(key))
      assert run.status == :waiting

      run = timed_out(run)
      assert %{status: :failed, error: %{"type" => "timeout"}} = run
      assert [%{status: :cancelled}] = children(run)

      {:ok, _} = Durable.retry(run.id)
      run = drain(run)

      assert run.status == :waiting, "retried, it ended #{run.status}: #{inspect(run.error)}"
      assert [%{status: :waiting} = charge] = children(run)

      :ok = Durable.send_event(charge.id, "bank_confirmed", %{})
      run = drain(run)
      assert run.status == :completed
      assert run.context["payment"]["paid"]
    end
  end

  test "a retry that is refused leaves the cancelled child as it was" do
    run = timed_out(order(%{}, "audit4_order_within_the_hour"))
    {:ok, _} = Durable.retry(run.id)

    assert Durable.retry(run.id) == {:error, :not_failed}
    assert [%{status: :pending}] = children(run)
  end

  # A lane that was cancelled is an error to its block, which used to wait for
  # every other lane first: here, for an input nobody gives.
  describe "a cancelled lane ends a block that fails fast, as a failed lane does" do
    test "when its step cancels it" do
      run = order(%{}, "audit4_dispatch")

      assert run.status == :failed
      assert run.error["message"] == "the courier doesn't serve this area"
      assert Enum.all?(children(run), &(&1.status == :cancelled))
      assert Repo.all(from(i in PendingInput, where: i.status == :pending)) == []
    end

    test "when an operator cancels its run" do
      run = order(%{}, "audit4_pick")
      assert run.status == :waiting
      north = Enum.find(children(run), &(&1.engine_state["__parallel_step"] == "pickers__north"))

      :ok = Durable.cancel(north.id, "off sick")
      run = drain(run)

      assert %{status: :failed, error: %{"type" => "cancelled", "message" => "off sick"}} = run
      assert Enum.all?(children(run), &(&1.status == :cancelled))
    end

    test "but not when the block can do without the lane" do
      run = order(%{}, "audit4_pick_spare")
      spare = Enum.find(children(run), &(&1.engine_state["__parallel_step"] == "pickers__spare"))

      :ok = Durable.cancel(spare.id, "off sick")
      run = drain(run)

      assert run.status == :waiting
      assert [%{status: :waiting}] = Enum.reject(children(run), &(&1.id == spare.id))
    end
  end

  describe "a run lost right after a step's result was saved" do
    # A decision's `{:goto, _, data}` was saved without the record a step's
    # save has, so the run that came back ran the decision again, on its own result.
    test "doesn't run a decision that jumped again" do
      assert order(%{}, "audit4_refund").context["routed"] == 1
      stored = Audit4ExecBugSeen.get(:stored_after_route)
      assert stored.context["routed"] == 1

      run = lost_after("audit4_refund", "route", stored)

      assert run.status == :completed
      assert run.context["routed"] == 1
    end

    # And so was the result of a step in a `branch on:` clause.
    test "doesn't run a step of a `branch on:` clause again" do
      assert order(%{"size" => "large"}, "audit4_parcel").context["weighed"] == 1
      stored = Audit4ExecBugSeen.get(:stored_after_weigh)
      assert stored.context["weighed"] == 1

      run = lost_after("audit4_parcel", clause_step("audit4_parcel", "__weigh"), stored)

      assert run.status == :completed
      assert run.context["weighed"] == 1
    end

    test "doesn't run a step of a `branch on:` clause that jumped again" do
      assert order(%{"size" => "small"}, "audit4_parcel").context["franked"] == 1
      stored = Audit4ExecBugSeen.get(:stored_after_frank)
      assert stored.context["franked"] == 1

      run = lost_after("audit4_parcel", clause_step("audit4_parcel", "__frank"), stored)

      assert run.status == :completed
      assert run.context["franked"] == 1
      refute run.context["queued"]
    end

    test "runs a decision whose jump was refused again when the run is retried" do
      run = order(%{"to" => "nowhere"}, "audit4_refund_routed")
      assert %{status: :failed, error: %{"type" => "decision_error"}} = run

      Repo.update_all(from(w in WorkflowExecution, where: w.id == ^run.id),
        set: [context: Map.put(run.context, "to", "pay_out")]
      )

      {:ok, _} = Durable.retry(run.id)
      run = drain(run)

      assert run.status == :completed
      assert run.context["routed"] == 2
    end
  end

  describe "a jump from outside a block to a step inside it" do
    # A jump was checked for a target that exists and is ahead, not for where
    # it is. The steps of every arm sit side by side in the definition, so a run
    # that landed in one arm ran on through the arms after it.
    test "is refused, and doesn't run the steps of another arm" do
      run = order(%{"to" => "risk__review__ask_assessor"}, "audit4_claim")

      assert %{status: :failed, error: %{"type" => "decision_error"} = error} = run
      assert error["message"] =~ "a step inside :risk"
      refute run.context["asked"] || run.context["refused"]
    end

    # The same jump into a lane ran every lane's steps in the block's own run,
    # one after another, and the block never happened: no lanes, no `notify` key.
    test "is refused, and doesn't run a lane's steps in the block's run" do
      run = order(%{"to" => "notify__customer__email"}, "audit4_claim")

      assert %{status: :failed, error: %{"type" => "decision_error"} = error} = run
      assert error["message"] =~ "a step inside :notify"
      refute run.context["emailed"] || run.context["lettered"]
    end

    test "is refused from one clause of a `branch on:` to another" do
      run = order(%{"size" => "tiny"}, "audit4_parcel")

      assert %{status: :failed, error: %{"type" => "decision_error"}} = run
      refute run.context["queued"]
    end

    test "is refused from a block's into: to a step of its own lane, and a retry doesn't make it" do
      run = order(%{}, "audit4_notice")
      assert %{status: :failed, error: %{"type" => "parallel_goto_error"} = error} = run
      assert error["message"] =~ "a step inside :send"
      assert Audit4ExecBugSeen.get(:posted) == 1

      {:ok, _} = Durable.retry(run.id)
      assert drain(run).status == :failed
      assert Audit4ExecBugSeen.get(:posted) == 2
      assert length(children(run)) == 2
    end

    test "still reaches the block itself, and a step after it" do
      assert %{status: :completed, context: %{"paid" => true}} =
               order(%{"to" => "risk"}, "audit4_claim")

      assert %{status: :completed, context: %{"notify" => %{}} = context} =
               order(%{"to" => "notify"}, "audit4_claim")

      refute context["paid"]

      run = order(%{"to" => "close"}, "audit4_claim")
      assert run.status == :completed
      assert children(run) == []
    end
  end

  # A run that fails as it resumes has no data in its process, so its undo is
  # handed the run's context. Read from the struct, which is without the stored
  # record of its key shapes, every key the code knows as an atom became one:
  # the undo that gets "id" when the run fails in a step got :id (rule 10).
  describe "an undo is handed the same data when the run fails as it resumes" do
    test "from a parallel block that failed" do
      assert order(%{}, "audit4_trip").status == :compensated
      assert Audit4ExecBugSeen.get(:cancelled_flight) == "FL-123"
    end

    test "past its deadline" do
      run = order(%{}, "audit4_trip_approved")
      assert run.status == :waiting

      assert %{status: :compensated, error: %{"type" => "timeout"}} = timed_out(run)
      assert Audit4ExecBugSeen.get(:cancelled_flight) == "FL-123"
    end

    test "to an input that timed out" do
      run = order(%{}, "audit4_trip_approved")
      nobody_answered = %{"__fail__" => %{"type" => "timeout", "message" => "nobody approved"}}
      {:ok, _} = Durable.Executor.resume_workflow(run.id, %{}, engine: nobody_answered)

      assert %{status: :compensated, error: %{"message" => "nobody approved"}} = drain(run)
      assert Audit4ExecBugSeen.get(:cancelled_flight) == "FL-123"
    end
  end

  # A failed run queued by Durable.rollback/1 is :pending until a worker claims
  # it. A cancel in between ended it :cancelled with "__rollback__" still in its
  # context: nothing was undone, and it could no longer be rolled back or retried.
  describe "a run that is waiting to be rolled back keeps its rollback" do
    setup do
      run = order(%{}, "audit4_trip_halts")
      assert run.status == :failed
      {:ok, _} = Durable.rollback(run.id)
      %{run: run}
    end

    defp undone(run) do
      assert %{status: :pending, engine_state: %{"__rollback__" => _}} = reload(run)
      assert drain(run).status == :compensated
      assert Audit4ExecBugSeen.get(:cancelled_flight) == "FL-123"
      refute is_map_key(reload(run).engine_state, "__rollback__")
    end

    test "when it is cancelled", %{run: run} do
      assert Durable.cancel(run.id) == {:error, :already_completed}
      undone(run)
    end

    test "when it is cancelled with rollback: true", %{run: run} do
      assert Durable.cancel(run.id, "again", rollback: true) == {:error, :already_completed}
      undone(run)
    end

    test "when cancel_all matches it", %{run: run} do
      assert Durable.cancel_all(workflow_name: "audit4_trip_halts") == {:ok, 0}
      undone(run)
    end

    test "when a worker has claimed it and not yet begun to undo it", %{run: run} do
      Repo.update_all(from(w in WorkflowExecution, where: w.id == ^run.id),
        set: [status: :running]
      )

      assert Durable.cancel(run.id) == {:error, :already_completed}

      Repo.update_all(from(w in WorkflowExecution, where: w.id == ^run.id),
        set: [status: :pending]
      )

      undone(run)
    end
  end

  # The same cancel reaches a child from its parent.
  test "cancelling a parent leaves its child that is waiting to be rolled back to it" do
    parent = order(%{}, "audit4_trip_planned")
    assert parent.status == :waiting
    [trip] = children(parent)
    assert trip.status == :failed
    {:ok, _} = Durable.rollback(trip.id)

    :ok = Durable.cancel(parent.id)

    assert drain(trip).status == :compensated
    assert Audit4ExecBugSeen.get(:cancelled_flight) == "FL-123"
  end
end
