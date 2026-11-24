defmodule Audit5BlocksSeen do
  @moduledoc false
  def put(key, value), do: :persistent_term.put({__MODULE__, key}, value)
  def get(key), do: :persistent_term.get({__MODULE__, key}, nil)
  def hit(key), do: put(key, (get(key) || 0) + 1)

  def clear do
    for {{__MODULE__, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
  end
end

defmodule Audit5BlocksFallbackCourier do
  @moduledoc false
  use Durable

  workflow "audit5_blocks_fallback_courier" do
    step :book_van, fn _parcel -> {:fail, "no van free today"} end
  end
end

defmodule Audit5BlocksShipping do
  @moduledoc false
  use Durable
  use Durable.Helpers
  use Durable.Orchestration
  use Durable.Wait

  alias Audit5BlocksSeen, as: Seen

  # The usual courier quotes within the hour. Without a quote, a fallback
  # courier is booked through a workflow of its own.
  workflow "audit5_blocks_book_courier" do
    step :book_courier, fn shipment ->
      case wait_for_event("courier_quote", timeout: hours(1), timeout_value: :no_quote) do
        :no_quote ->
          booked =
            call_workflow(Audit5BlocksFallbackCourier, %{"parcel" => shipment["parcel"]},
              ref: :fallback
            )

          Seen.put(:fallback, booked)

          case booked do
            {:ok, booking} -> {:ok, assign(shipment, :booking, booking)}
            {:error, reason} -> {:fail, reason}
          end

        quote ->
          {:ok, assign(shipment, :booking, quote)}
      end
    end
  end

  # Carriers quote at once; a bad deploy sends every order back to intake
  # from into:, and the fix prices it.
  workflow "audit5_blocks_quotes" do
    step :intake, fn order -> {:ok, assign(order, :received, true)} end

    parallel :quotes,
      into: fn order, quotes ->
        target = if Seen.get(:into_fixed), do: :price, else: :intake
        {:goto, target, assign(order, :carriers, map_size(quotes))}
      end do
      step :dhl, fn order ->
        Seen.hit(:dhl)
        {:ok, assign(order, :dhl, 12)}
      end

      step :ups, fn order ->
        Seen.hit(:ups)
        {:ok, assign(order, :ups, 14)}
      end
    end

    step :review, fn order -> {:ok, assign(order, :reviewed, true)} end
    step :price, fn order -> {:ok, assign(order, :priced, true)} end
  end

  # Express parcels handed in before the cut-off skip the overnight hold.
  workflow "audit5_blocks_parcel" do
    branch on: fn parcel -> parcel["service"] end do
      "express" ->
        step :check_cutoff, fn parcel ->
          if parcel["before_cutoff"],
            do: {:goto, Audit5BlocksShipping.clause_step("__book_courier"), parcel},
            else: {:ok, parcel}
        end

        step :hold_overnight, fn parcel -> {:ok, assign(parcel, :held, true)} end
        step :book_courier, fn parcel -> {:ok, assign(parcel, :courier, "same_day")} end

      _ ->
        step :post, fn parcel -> {:ok, assign(parcel, :posted, true)} end
    end

    step :label, fn parcel -> {:ok, assign(parcel, :labelled, true)} end
  end

  # Two carriers quote at once; DHL's API is down until someone says it's back.
  workflow "audit5_blocks_rates" do
    parallel :rates do
      step :dhl, fn order ->
        if Seen.get(:dhl_up), do: {:ok, assign(order, :price, 12)}, else: {:fail, "DHL is down"}
      end

      step :ups, fn order -> {:ok, assign(order, :price, 14)} end
    end

    step :pick, fn order ->
      Seen.put(:rates, order["rates"])
      {:ok, order}
    end
  end

  # into: hands back the earliest delivery date where the order belongs: a
  # slip, and the run's data can't be a date.
  workflow "audit5_blocks_delivery", on_failure: :rollback do
    step :hold_stock, [compensate: :release_stock], fn order ->
      {:ok, assign(order, :held, true)}
    end

    parallel :delivery,
      into: fn order, quotes ->
        earliest =
          quotes
          |> Enum.map(fn {_carrier, {:ok, quote}} -> Date.from_iso8601!(quote["by"]) end)
          |> Enum.min(Date)

        if order["jump"], do: {:goto, :confirm, earliest}, else: {:ok, earliest}
      end do
      step :dhl, fn order -> {:ok, assign(order, :by, "2026-12-01")} end
      step :ups, fn order -> {:ok, assign(order, :by, "2026-11-30")} end
    end

    step :confirm, fn order -> {:ok, order} end

    compensate :release_stock, fn order ->
      Seen.put(:released, true)
      {:ok, order}
    end
  end

  # The customer's record is looked up from two sources, either of which may
  # be down, while stock is checked.
  workflow "audit5_blocks_enrich" do
    parallel :enrich do
      lane :customer do
        parallel :sources, on_error: :collect do
          step :crm, fn order -> {:ok, assign(order, :tier, "gold")} end
          step :billing, fn _order -> {:fail, "billing is down"} end
        end

        step :summarise, fn order ->
          Seen.put(:in_lane, order["sources"])
          {:ok, order}
        end
      end

      step :stock, fn order -> {:ok, assign(order, :in_stock, true)} end
    end

    step :decide, fn order ->
      Seen.put(:after_block, order["enrich"]["customer"]["sources"])
      {:ok, order}
    end
  end

  # A clause's step is named after its branch, which has no name of its own.
  def clause_step(suffix) do
    {:ok, definition} = __workflow_definition__("audit5_blocks_parcel")

    Enum.find_value(definition.steps, fn %{name: name} ->
      if String.ends_with?(Atom.to_string(name), suffix), do: name
    end)
  end
end

defmodule Audit5BlocksLoan do
  @moduledoc false
  use Durable
  use Durable.Helpers
  use Durable.Wait

  # The applicant's credit score and a reference from the employer are asked
  # for at once. The employer has ten minutes; the whole application has less.
  workflow "audit5_blocks_application", timeout: 300 do
    parallel :checks do
      step :credit, fn application -> {:ok, assign(application, :score, 700)} end

      lane :employer, timeout: minutes(10) do
        step :ask_employer, fn application ->
          wait_for_input("reference")
          {:ok, application}
        end
      end
    end
  end

  workflow "audit5_blocks_slow_employer", timeout: 200 do
    parallel :checks do
      step :credit, fn application -> {:ok, assign(application, :score, 700)} end

      lane :employer, timeout: minutes(10) do
        step :call_employer, fn application ->
          Process.sleep(2_000)
          {:ok, application}
        end
      end
    end
  end

  # The application has no deadline; the employer has 50ms, and the decision
  # is made without the reference if that's too short.
  workflow "audit5_blocks_reference" do
    parallel :checks do
      step :credit, fn application -> {:ok, assign(application, :score, 700)} end

      lane :employer, optional: true, timeout: 50 do
        step :ask_employer, fn application -> {:ok, assign(application, :employed, true)} end
      end
    end

    step :decide, fn application -> {:ok, application} end
  end
end

defmodule Durable.Audit5BlocksTest do
  @moduledoc "Audit 5: parallel blocks, branches and child workflows."
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Audit5BlocksSeen, as: Seen
  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{Node, PendingEvent, WorkflowExecution}
  alias Durable.TestRepo, as: Repo
  alias Durable.Wait.TimeoutWorker

  @moduletag :capture_log

  setup do
    Seen.clear()
    on_exit(&Seen.clear/0)
  end

  defp children(run),
    do: Repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^run.id))

  defp time_out_waits!(run) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(from(e in PendingEvent, where: e.workflow_id == ^run.id),
      set: [timeout_at: past]
    )

    start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
    TimeoutWorker.check_timeouts(Durable)
    :sys.get_state(TimeoutWorker.worker_name(Durable))
  end

  # The step's wait for a quote timed out, and the fallback it then called
  # failed. The timeout was taken for the child's: call_workflow said
  # {:ok, :child_timeout}, and the step went on as if a van was booked.
  test "a child that fails after an earlier wait in its step timed out is a failure, not a timeout" do
    run =
      run_workflow(Audit5BlocksShipping, %{"parcel" => "P-1"},
        workflow: "audit5_blocks_book_courier"
      )

    assert run.status == :waiting

    time_out_waits!(run)
    run = drain(run)

    assert {:error, %{"message" => "no van free today"}} = Seen.get(:fallback)
    assert %{status: :failed, error: %{"message" => "no van free today"}} = run
  end

  # The refused jump was saved with the block's record of its lanes taken
  # out, so the retry found no lanes and started them all again.
  test "a retry after into: jumped where it can't doesn't start the lanes again" do
    run = run_workflow(Audit5BlocksShipping, %{}, workflow: "audit5_blocks_quotes")
    assert %{status: :failed, error: %{"type" => "parallel_goto_error"}} = run
    assert {Seen.get(:dhl), Seen.get(:ups)} == {1, 1}

    Seen.put(:into_fixed, true)
    {:ok, _} = Durable.retry(run.id)
    run = drain(run)

    assert %{status: :completed, context: %{"priced" => true, "carriers" => 2}} = run
    refute run.context["reviewed"]
    assert {Seen.get(:dhl), Seen.get(:ups)} == {1, 1}
    assert length(children(run)) == 2
  end

  # The lane retried by its own id was running again, but its failure was still
  # counted as its answer: the block's retry woke on the other lane alone, and
  # failed on a lane that hadn't finished.
  test "a block retried while a lane retried by its own id still runs waits for that lane" do
    config = Config.get(Durable)
    run = run_workflow(Audit5BlocksShipping, %{}, workflow: "audit5_blocks_rates")
    assert %{status: :failed, error: %{"message" => "DHL is down"}} = run

    lane = fn name ->
      Enum.find(children(run), &(&1.engine_state["__parallel_step"] == "rates__#{name}"))
    end

    Seen.put(:dhl_up, true)
    {:ok, _} = Durable.retry(lane.(:dhl).id)
    {:ok, _} = Durable.retry(run.id)

    # UPS, stopped when DHL failed, finishes first.
    Durable.Executor.execute_workflow(lane.(:ups).id, config)
    Durable.Executor.execute_workflow(run.id, config)
    after_ups = Repo.get!(WorkflowExecution, run.id)
    assert after_ups.status == :waiting, inspect(after_ups.error)

    run = drain(run)
    assert run.status == :completed
    assert %{"dhl" => %{"price" => 12}, "ups" => %{"price" => 14}} = Seen.get(:rates)
  end

  # A date passed `is_map/1`, and the save then merged the stored date, a
  # string, into a map: BadMapError, the run left :running, nothing undone.
  for jump <- [false, true] do
    test "an into: that returns a date in place of the data fails the run (jump: #{jump})" do
      run =
        run_workflow(Audit5BlocksShipping, %{"jump" => unquote(jump)},
          workflow: "audit5_blocks_delivery"
        )

      assert %{status: :compensated, error: %{"type" => "parallel_into_error"} = error} = run
      assert error["message"] =~ "~D[2026-11-30]"
      assert Seen.get(:released)
    end
  end

  # The pairs were put back at the top of the data only: a step after the
  # outer block got the inner block's lanes as two-item lists.
  test "a block that collects, in a lane, is pairs to the step after the outer block too" do
    run = run_workflow(Audit5BlocksShipping, %{}, workflow: "audit5_blocks_enrich")
    assert run.status == :completed

    assert %{"crm" => {:ok, %{"tier" => "gold"}}, "billing" => {:error, _}} = Seen.get(:in_lane)

    assert %{"crm" => {:ok, %{"tier" => "gold"}}, "billing" => {:error, _}} =
             Seen.get(:after_block)
  end

  defp lane(run, name) do
    Enum.find(children(run), &String.ends_with?(&1.engine_state["__parallel_step"], name))
  end

  defp sweep do
    start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
    TimeoutWorker.check_timeouts(Durable)
    :sys.get_state(TimeoutWorker.worker_name(Durable))
  end

  defp a_node_polls!(queues) do
    now = DateTime.utc_now()

    Repo.insert!(%Node{
      id: "elsewhere",
      queues: queues,
      version: "1",
      started_at: now,
      heartbeat_at: now
    })
  end

  # A lane with a `timeout:` has the earlier of that and the run's deadline.
  # Whichever it was, the error named the lane and its ten minutes.
  test "a lane ended by the run's deadline, earlier than its own, is told so: before a step" do
    run = run_workflow(Audit5BlocksLoan, %{}, workflow: "audit5_blocks_application")
    employer = lane(run, "employer")
    assert employer.deadline_at == run.deadline_at

    Process.sleep(310)
    sweep()
    Executor.execute_workflow(employer.id, Config.get(Durable))

    assert %{status: :failed, error: %{"type" => "timeout", "message" => message}} =
             lane(run, "employer")

    assert message == "the run passed its 300ms timeout before checks__employer__ask_employer"
    assert %{status: :failed, error: %{"type" => "timeout"}} = drain(run)
  end

  test "a lane ended by the run's deadline, earlier than its own, is told so: during a step" do
    run = run_workflow(Audit5BlocksLoan, %{}, workflow: "audit5_blocks_slow_employer")

    assert %{status: :failed, error: %{"type" => "timeout", "message" => message}} =
             lane(run, "employer")

    assert message =~ "the run passed its"
    assert run.status == :failed
  end

  # The sweep moves a run past its deadline off a queue no node polls, to be
  # failed where one does, but left every lane: one with a `timeout:` of its
  # own stayed, and its block, which has no deadline, waited for it for ever.
  test "a lane past its own timeout on a queue no node polls is moved to one that is, and failed" do
    config = Config.get(Durable)

    {:ok, id} =
      Durable.start(Audit5BlocksLoan, %{}, workflow: "audit5_blocks_reference", queue: "branch")

    {:waiting, run} = Executor.execute_workflow(id, config)
    a_node_polls!(["default"])
    Process.sleep(60)
    sweep()

    assert %{status: :pending, queue: "default", home_queue: "branch"} = lane(run, "employer")
    assert %{status: :pending, queue: "branch"} = lane(run, "credit")

    run = drain(run)
    assert %{status: :failed, error: %{"message" => message}} = lane(run, "employer")
    assert message =~ "lane employer passed its 50ms timeout"
    assert %{status: :completed, context: %{"checks" => %{"employer" => nil}}} = run
  end

  # Retried by its own id, a lane was given the workflow's timeout, from now,
  # as if it were the run: here none, so the employer had for ever.
  test "a lane retried by its own id has its own timeout again" do
    {:ok, id} = Durable.start(Audit5BlocksLoan, %{}, workflow: "audit5_blocks_reference")
    {:waiting, run} = Executor.execute_workflow(id, Config.get(Durable))
    Process.sleep(60)
    drain(run)
    assert %{status: :failed, error: %{"type" => "timeout"}} = lane(run, "employer")

    {:ok, _} = Durable.retry(lane(run, "employer").id)

    assert %{status: :pending, deadline_at: %DateTime{} = deadline} = lane(run, "employer")
    assert DateTime.diff(deadline, Durable.Clock.utc_now(), :millisecond) in 0..50
  end

  # Its deadline is the run's: the run is the one moved, and it ends the lane.
  test "a lane past the run's deadline on a queue no node polls is left to the run" do
    config = Config.get(Durable)

    {:ok, id} =
      Durable.start(Audit5BlocksLoan, %{}, workflow: "audit5_blocks_application", queue: "branch")

    {:waiting, run} = Executor.execute_workflow(id, config)
    a_node_polls!(["default"])
    Process.sleep(310)
    sweep()

    assert %{status: :pending, queue: "branch"} = lane(run, "employer")
    assert %{status: :pending, queue: "default"} = Repo.get!(WorkflowExecution, id)

    Executor.execute_workflow(id, config)
    assert %{status: :failed, error: %{"type" => "timeout"}} = Repo.get!(WorkflowExecution, id)
    assert %{status: :cancelled} = lane(run, "employer")
  end

  # A clause's steps were registered last to first, so the jump was refused
  # as one backwards; and it was looked for in every step after the branch,
  # the other clauses' included, so the run went on through the clause
  # written after it.
  test "a `branch on:` step that jumps ahead in its own clause runs no other clause" do
    run =
      run_workflow(Audit5BlocksShipping, %{"service" => "express", "before_cutoff" => true},
        workflow: "audit5_blocks_parcel"
      )

    assert run.status == :completed, inspect(run.error)
    assert %{"courier" => "same_day", "labelled" => true} = run.context
    refute run.context["held"]
    refute run.context["posted"]
  end
end
