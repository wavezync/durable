defmodule Durable.Audit4ApiWaitsTest do
  @moduledoc """
  Waits at their edges: odd durations, what a timeout hands back, answers for
  runs that are gone, waits inside lanes, and several waits in one step.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WorkflowExecution}
  alias Durable.Wait
  alias Durable.Wait.TimeoutWorker

  @moduletag :capture_log

  defmodule Audit4ApiSleeps do
    use Durable
    use Durable.Wait

    workflow "audit4_api_sleeps" do
      step :nap, fn data ->
        sleep(data["ms"])
        {:ok, Map.put(data, "napped", true)}
      end

      step :ask, fn data ->
        {:ok, Map.put(data, "answer", inspect(wait_for_input("ok")))}
      end
    end
  end

  defmodule Audit4ApiBadWaits do
    use Durable
    use Durable.Wait

    workflow "audit4_api_bad_waits_inline" do
      step :first, fn data -> {:ok, data} end

      step :wait, fn data ->
        case data["kind"] do
          "sleep_too_long" -> sleep(10 ** 30)
          "sleep_before_time" -> sleep(-(10 ** 15))
          "timeout_float" -> wait_for_event("x", timeout: 1.5)
          "timeout_too_long" -> wait_for_input("x", timeout: 10 ** 30)
          "any_too_long" -> wait_for_any(["x", "y"], timeout: 10 ** 30)
          "input_unstorable" -> wait_for_input("x", metadata: %{at: {1, 2}})
        end

        {:ok, data}
      end
    end
  end

  defmodule Audit4ApiBadWaitUndone do
    use Durable
    use Durable.Wait

    workflow "audit4_api_bad_wait_undone", on_failure: :rollback do
      step :hold, [compensate: :release], fn data -> {:ok, data} end
      step :wait, fn _data -> sleep(10 ** 30) end
      compensate :release, fn data -> {:ok, data} end
    end
  end

  defmodule Audit4ApiThreeWaits do
    use Durable
    use Durable.Wait

    workflow "audit4_api_three_waits" do
      step :gather, fn data ->
        a = wait_for_event("a")
        b = wait_for_input("b")
        sleep(5)
        {:ok, Map.merge(data, %{"got_a" => a, "got_b" => b})}
      end

      step :after, fn data ->
        {:ok, Map.put(data, "got_c", inspect(wait_for_event("c")))}
      end
    end
  end

  defmodule Audit4ApiLanes do
    use Durable
    use Durable.Wait

    workflow "audit4_api_lanes" do
      parallel :lookups do
        step :credit, fn data ->
          {:ok, Map.put(data, "credit", inspect(wait_for_event("credit_done")))}
        end

        step :fraud, fn data ->
          {:ok, Map.put(data, "fraud", inspect(wait_for_input("fraud_ok")))}
        end
      end

      step :after, fn data -> {:ok, Map.put(data, "after", true)} end
    end
  end

  # A loan application: the applicant signs in a child workflow, and that
  # workflow looks two things up at once before it asks for the signature.
  defmodule Audit4ApiSigning do
    use Durable
    use Durable.Wait

    workflow "audit4_api_signing" do
      step :sign, fn data ->
        {:ok, Map.put(data, "signature", inspect(wait_for_input("signature")))}
      end
    end

    workflow "audit4_api_checked_signing" do
      parallel :checks do
        step :identity, fn data ->
          {:ok, Map.put(data, "identity", inspect(wait_for_event("identity_checked")))}
        end

        step :address, fn data -> {:ok, Map.put(data, "address", "found")} end
      end
    end
  end

  defmodule Audit4ApiLoan do
    use Durable
    use Durable.Wait
    use Durable.Orchestration

    workflow "audit4_api_loan" do
      step :sign, fn data ->
        {:ok, signed} = call_workflow(Audit4ApiSigning, %{}, workflow: "audit4_api_signing")
        {:ok, Map.put(data, "signature", signed["signature"])}
      end
    end

    workflow "audit4_api_loan_with_lookups" do
      parallel :lookups do
        step :signing, fn data ->
          {:ok, checked} =
            call_workflow(Audit4ApiSigning, %{}, workflow: "audit4_api_checked_signing")

          {:ok, Map.put(data, "identity", checked["checks"]["identity"]["identity"])}
        end

        step :credit, fn data ->
          {:ok, Map.put(data, "credit", inspect(wait_for_event("credit_done")))}
        end
      end
    end
  end

  defmodule Audit4ApiTimesOut do
    use Durable
    use Durable.Wait

    alias Durable.Audit4ApiWaitsTest, as: T

    workflow "audit4_api_times_out" do
      step :wait, fn data ->
        opts = [timeout: 0] ++ T.timeout_opts(data["value"])

        got =
          case data["wait"] do
            "event" -> wait_for_event("go", opts)
            "input" -> wait_for_input("go", opts)
            "any" -> wait_for_any(["go", "stop"], opts)
            "all" -> wait_for_all(["go", "stop"], opts)
          end

        {:ok, Map.put(data, "got", T.describe(got))}
      end
    end
  end

  defmodule Audit4ApiTimesOutWithText do
    use Durable
    use Durable.Wait

    workflow "audit4_api_times_out_with_text" do
      step :wait, fn data ->
        value = %{"__atom__" => Process.get(:audit4_api_atom_name)}
        wait_for_event("go", timeout: 0, timeout_value: value)
        {:ok, data}
      end
    end
  end

  defmodule Audit4ApiKeepsFloats do
    use Durable
    use Durable.Wait

    @numbers [999_999.5, 2_000_000.0, 1.0e16, 1.0e300]

    workflow "audit4_api_keeps_floats" do
      step :make, fn data ->
        {:ok, Map.merge(data, %{"numbers" => @numbers, "big" => 2 ** 200})}
      end

      step :wait, fn data ->
        wait_for_event("go")

        {:ok,
         Map.merge(data, %{
           "floats" => Enum.map(data["numbers"], &is_float/1),
           "values" =>
             data["numbers"] |> Enum.zip(@numbers) |> Enum.map(fn {a, b} -> a / 1 == b end)
         })}
      end
    end
  end

  defmodule Audit4ApiFloatsEverywhere do
    use Durable
    use Durable.Wait

    alias Durable.Audit4ApiWaitsTest, as: T

    workflow "audit4_api_floats_everywhere" do
      step :make, fn data -> {:ok, Map.put(data, "made", T.floats())} end

      step :wait, fn data ->
        event = wait_for_event("go")
        input = wait_for_input("ask")

        {:ok,
         Map.put(data, "seen", %{
           "made" => T.all_floats?(data["made"]),
           "event" => T.all_floats?(event),
           "input" => T.all_floats?(input)
         })}
      end
    end
  end

  defmodule Audit4ApiWaitsAny do
    use Durable
    use Durable.Wait

    workflow "audit4_api_waits_any" do
      step :wait, fn data ->
        {:ok, Map.put(data, "got", inspect(wait_for_any(["a", "b"])))}
      end
    end
  end

  defmodule Audit4ApiWaitsAll do
    use Durable
    use Durable.Wait

    alias Durable.Audit4ApiWaitsTest, as: T

    workflow "audit4_api_waits_all" do
      step :wait, fn data ->
        {:ok, Map.put(data, "got", T.string_keys(wait_for_all(["a", "b"])))}
      end
    end
  end

  # An event's name is an atom key only if that atom happens to exist.
  def string_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  def timeout_opts("none"), do: []
  def timeout_opts(value), do: [timeout_value: timeout_value(value)]

  def timeout_value("atom"), do: :auto_rejected
  def timeout_value("tuple"), do: {:error, :payment_timeout}
  def timeout_value("atom_map"), do: %{"__atom__" => "audit4_api_never_an_atom_before"}
  def timeout_value("value_map"), do: %{"__value__" => 1, "other" => 2}
  def timeout_value("false"), do: false
  def timeout_value("nil"), do: nil
  def timeout_value("zero"), do: 0
  def timeout_value("text"), do: "No reason provided"
  def timeout_value("map"), do: %{"approved" => false, "n" => 1.5}

  # Whole floats, which a JSON encoder writes without a fraction digit.
  def floats do
    %{
      "list" => [1000.0, 2.0e6, 1.0e16, -2_000_000.0, 1.0e300, 3.0, 0.5],
      "nested" => %{"deep" => [%{"total" => 1.0e16}, [-2_000_000.0]]}
    }
  end

  def all_floats?(%{} = map), do: map |> Map.values() |> all_floats?()
  def all_floats?(list) when is_list(list), do: Enum.all?(list, &all_floats?/1)
  def all_floats?(leaf), do: is_float(leaf)

  # What the step got back, in a form that survives the context's trip to JSON.
  def describe(got), do: inspect(got)

  defp run(id), do: TestRepo.get!(WorkflowExecution, id)

  defp execute(id) do
    Executor.execute_workflow(id, Config.get(Durable))
    run(id)
  end

  defp timed_out(wait, value) do
    waiting = run_workflow(Audit4ApiTimesOut, %{"wait" => wait, "value" => value})
    assert waiting.status == :waiting

    TimeoutWorker.check_timeouts()
    :sys.get_state(TimeoutWorker.worker_name(Durable))

    finished = drain(waiting)
    assert finished.status == :completed
    finished.context["got"]
  end

  describe "what a timed-out wait returns" do
    setup do
      start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
      :ok
    end

    for wait <- ["event", "input"], value <- ["false", "nil", "zero", "text", "map"] do
      test "wait_for_#{wait} returns a #{value} timeout_value as it was given" do
        assert timed_out(unquote(wait), unquote(value)) ==
                 describe(timeout_value(unquote(value)))
      end
    end

    for wait <- ["any", "all"],
        value <- ["atom", "tuple", "zero", "text", "map", "atom_map", "false", "nil"] do
      test "wait_for_#{wait} returns a #{value} timeout_value as it was given" do
        assert timed_out(unquote(wait), unquote(value)) ==
                 describe(timeout_value(unquote(value)))
      end
    end

    # The wait returns the call's own option, not the copy stored as JSON.
    for wait <- ["event", "input"], value <- ["atom", "tuple"] do
      test "wait_for_#{wait} returns #{value} timeout_value as it was given" do
        assert timed_out(unquote(wait), unquote(value)) ==
                 describe(timeout_value(unquote(value)))
      end
    end

    test "without a timeout_value, each wait returns its own default" do
      assert timed_out("event", "none") == "nil"
      assert timed_out("input", "none") == "nil"
      assert timed_out("any", "none") == "{:timeout, nil}"
      assert timed_out("all", "none") == "{:timeout, %{}}"
    end

    # A map that happens to have an "__atom__" or "__value__" key isn't taken
    # for the engine's own wrapping of the stored copy.
    for wait <- ["event", "input"], value <- ["atom_map", "value_map"] do
      test "wait_for_#{wait} returns a map with an #{value} key as it was given" do
        assert timed_out(unquote(wait), unquote(value)) ==
                 describe(timeout_value(unquote(value)))
      end
    end

    test "a timeout_value map makes no atom from its text" do
      name = "audit4_api_atom_#{System.unique_integer([:positive])}"
      Process.put(:audit4_api_atom_name, name)
      waiting = run_workflow(Audit4ApiTimesOutWithText, %{})
      TimeoutWorker.check_timeouts()
      :sys.get_state(TimeoutWorker.worker_name(Durable))
      drain(waiting)

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "sleep durations" do
    for ms <- [0, -5, -86_400_000] do
      test "sleep(#{ms}) is due at once" do
        {:ok, id} = Durable.start(Audit4ApiSleeps, %{"ms" => unquote(ms)})
        slept = execute(id)

        assert slept.status == :waiting
        assert DateTime.compare(slept.scheduled_at, DateTime.utc_now()) != :gt
        assert drain(id).current_step == "ask"
      end
    end

    test "a sleep of thousands of years is stored, and the run just waits" do
      {:ok, id} = Durable.start(Audit4ApiSleeps, %{"ms" => 400_000_000_000_000})
      slept = execute(id)

      assert slept.status == :waiting
      assert slept.scheduled_at.year > 10_000
    end

    for ms <- [1.5, nil, "1000"] do
      test "sleep(#{inspect(ms)}) fails the step, not the executor" do
        {:ok, id} = Durable.start(Audit4ApiSleeps, %{"ms" => unquote(ms)})
        failed = execute(id)

        assert failed.status == :failed
        assert failed.error["type"] == "FunctionClauseError"
      end
    end
  end

  describe "a wait the engine can't record, run inline" do
    # The step asked for a wait and its row says :waiting; then the wait can't
    # be written (a time no timestamp holds, a timeout that isn't a number).
    # That is the step's failure: the caller gets a failed run, not a raise and
    # a run left :running with a step still :waiting.
    for kind <- [
          "sleep_too_long",
          "sleep_before_time",
          "timeout_float",
          "timeout_too_long",
          "any_too_long",
          "input_unstorable"
        ] do
      test "#{kind} fails the run and closes the step" do
        run = run_workflow(Audit4ApiBadWaits, %{"kind" => unquote(kind)})

        assert run.status == :failed
        assert is_binary(run.error["type"])
        assert is_binary(run.error["message"])
        assert run.locked_by == nil

        assert Enum.map(steps(run), &{&1.step_name, &1.status}) ==
                 [{"first", :completed}, {"wait", :failed}]

        assert %{error: %{"type" => type}} = assert_step(run, :wait, :failed)
        assert type == run.error["type"]
        assert TestRepo.all(PendingInput) == []
        assert TestRepo.all(PendingEvent) == []
      end
    end

    test "a failed wait is the workflow's failure: its compensations run" do
      run = run_workflow(Audit4ApiBadWaitUndone, %{})

      assert run.status == :compensated
      assert run.context["undone"] == nil

      assert [%{"step" => "hold", "result" => %{"status" => "completed"}}] =
               run.compensation_results
    end
  end

  describe "cancel_wait" do
    test "ends a sleep, and the next step's wait still waits" do
      {:ok, id} = Durable.start(Audit4ApiSleeps, %{"ms" => 3_600_000})
      assert execute(id).status == :waiting

      assert Wait.cancel_wait(id, reason: "wake up") == :ok
      asking = execute(id)

      assert asking.status == :waiting
      assert asking.current_step == "ask"
      assert asking.context["napped"] == true
      refute Map.has_key?(asking.engine_state, "__cancelled__")
      assert_waiting_for_input(asking, "ok")
    end

    test "takes any reason, and hands it to the wait as JSON" do
      waiting = run_workflow(Audit4ApiSleeps, %{"ms" => 0})
      assert Wait.cancel_wait(waiting.id, reason: {:because, self(), "a\0b"}) == :ok

      finished = drain(waiting)
      assert finished.status == :completed
      assert finished.context["answer"] =~ ~s({:cancelled, ["because", "#PID<)
    end

    test "on a run that isn't waiting changes nothing" do
      {:ok, id} = Durable.start(Audit4ApiSleeps, %{"ms" => 0})
      assert Wait.cancel_wait(id) == {:error, :not_waiting}
      assert run(id).status == :pending

      :ok = Durable.cancel(id)
      assert Wait.cancel_wait(id) == {:error, :not_waiting}
      assert run(id).status == :cancelled
    end

    # The block's run is :waiting, on its lanes and not on anything of its own:
    # the call reaches the lanes' waits, and the block finishes by its own rules.
    test "on a run waiting for its parallel block cancels its lanes' waits" do
      blocked = run_workflow(Audit4ApiLanes, %{})
      assert blocked.status == :waiting

      assert Wait.cancel_wait(blocked.id, reason: "stop") == :ok
      # The block's own wait is left alone: it still waits for its lanes.
      assert run(blocked.id).status == :waiting
      refute Map.has_key?(run(blocked.id).engine_state, "__cancelled__")

      finished = drain(blocked)

      assert finished.status == :completed
      assert finished.context["after"] == true
      assert finished.context["lookups"]["credit"]["credit"] == ~s({:cancelled, "stop"})
      assert finished.context["lookups"]["fraud"]["fraud"] == ~s({:cancelled, "stop"})
      assert Enum.map(Durable.list_children!(blocked.id), & &1.status) == [:completed, :completed]
      assert Wait.list_pending_inputs!() == []
      assert [%{status: :completed}] = TestRepo.all(Durable.Storage.Schemas.WaitGroup)
    end

    test "on a block leaves a lane that isn't waiting alone" do
      {:ok, id} = Durable.start(Audit4ApiLanes, %{})
      assert execute(id).status == :waiting

      [credit, fraud] =
        Enum.sort_by(Durable.list_children!(id), &run(&1.id).engine_state["__parallel_step"])

      # Only the credit lane has got to its wait; the other has yet to start.
      assert execute(credit.id).status == :waiting
      assert run(fraud.id).status == :pending

      assert Wait.cancel_wait(id, reason: "stop") == :ok

      assert run(credit.id).engine_state["__cancelled__"] == "stop"
      assert run(fraud.id).status == :pending
      refute Map.has_key?(run(fraud.id).engine_state, "__cancelled__")

      # The untouched lane reaches its own wait, and the block waits for it.
      still_blocked = drain(id)
      assert still_blocked.status == :waiting
      assert run(credit.id).context["credit"] == ~s({:cancelled, "stop"})
      assert [%{input_name: "fraud_ok", status: :pending}] = Wait.list_pending_inputs!()

      assert Durable.provide_input(fraud.id, "fraud_ok", %{"n" => 2}) == :ok
      assert drain(id).status == :completed
    end

    test "on a block whose lanes are all still to start is :ok and changes nothing" do
      {:ok, id} = Durable.start(Audit4ApiLanes, %{})
      assert execute(id).status == :waiting

      assert Wait.cancel_wait(id, reason: "stop") == :ok

      assert run(id).status == :waiting
      assert Enum.map(Durable.list_children!(id), & &1.status) == [:pending, :pending]
    end

    test "on a run waiting for call_workflow cancels the child's wait" do
      calling = run_workflow(Audit4ApiLoan, %{}, workflow: "audit4_api_loan")
      assert calling.status == :waiting
      [child] = Durable.list_children!(calling.id)
      assert_waiting_for_input(child.id, "signature")

      assert Wait.cancel_wait(calling.id, reason: "withdrawn") == :ok
      # The call itself still waits for the child to finish.
      assert run(calling.id).status == :waiting

      finished = drain(calling)
      assert finished.status == :completed
      assert finished.context["signature"] == ~s({:cancelled, "withdrawn"})
      assert run(child.id).status == :completed
      assert Wait.list_pending_inputs!() == []
    end

    test "reaches a wait under a block, a call and another block" do
      top = run_workflow(Audit4ApiLoan, %{}, workflow: "audit4_api_loan_with_lookups")
      assert top.status == :waiting

      assert [%{event_name: "identity_checked"}] =
               Wait.list_pending_events!(event_name: "identity_checked")

      assert Wait.cancel_wait(top.id, reason: "withdrawn") == :ok
      finished = drain(top)

      assert finished.status == :completed
      assert finished.context["lookups"]["signing"]["identity"] == ~s({:cancelled, "withdrawn"})
      assert finished.context["lookups"]["credit"]["credit"] == ~s({:cancelled, "withdrawn"})
      assert Wait.list_pending_events!(event_name: "identity_checked") == []
    end
  end

  describe "a step's data across a wait" do
    # Jason writes a whole float as "2.0e6", jsonb keeps no fraction digits for
    # a number given that way and prints 2000000, and Jason reads that back as
    # an integer. Durable.Storage.JsonMap writes it as 2000000.0.
    test "a float is still a float" do
      waiting = run_workflow(Audit4ApiKeepsFloats, %{})
      assert Durable.send_event(waiting.id, "go", %{}) == :ok
      finished = drain(waiting)

      assert finished.status == :completed
      assert finished.context["floats"] == [true, true, true, true]
    end

    test "a float is a float in step results, events and inputs, read back from the database" do
      waiting = run_workflow(Audit4ApiFloatsEverywhere, %{"start" => floats()})
      assert Durable.send_event(waiting.id, "go", floats()) == :ok
      waiting = drain(waiting)
      assert Durable.provide_input(waiting.id, "ask", floats()) == :ok
      finished = drain(waiting)

      assert finished.status == :completed
      assert finished.context["seen"] == %{"made" => true, "event" => true, "input" => true}

      # Every stored copy, as Postgres gives it back.
      assert TestRepo.get!(WorkflowExecution, finished.id).input["start"] === floats()
      assert finished.context["made"] === floats()
      assert [%{payload: payload}] = TestRepo.all(PendingEvent)
      assert payload === floats()
      assert [%{response: response}] = TestRepo.all(PendingInput)
      assert response === floats()

      outputs =
        for %{output: %{"made" => _} = output} <- Durable.Testing.steps(finished), do: output

      assert outputs != []

      assert Enum.all?(
               outputs,
               &(Map.take(&1, ["made", "start"]) === %{"made" => floats(), "start" => floats()})
             )
    end

    test "numbers keep their value, whatever their size" do
      waiting = run_workflow(Audit4ApiKeepsFloats, %{})
      assert Durable.send_event(waiting.id, "go", %{}) == :ok
      finished = drain(waiting)

      assert finished.context["values"] == [true, true, true, true]
      assert finished.context["big"] == 2 ** 200
    end
  end

  describe "several waits in one step" do
    test "are answered one at a time, and the step sees every answer" do
      waiting = run_workflow(Audit4ApiThreeWaits, %{})
      assert_waiting_for_event(waiting, "a")
      assert Durable.provide_input(waiting.id, "b", "early") == {:error, :not_found}

      assert Durable.send_event(waiting.id, "a", %{"n" => 1}) == :ok
      waiting = drain(waiting)
      assert_waiting_for_input(waiting, "b")

      assert Durable.provide_input(waiting.id, "b", "yes") == :ok
      waiting = drain(waiting)
      assert waiting.current_step == "after"

      assert Durable.send_event(waiting.id, "c", nil) == :ok
      finished = drain(waiting)

      assert finished.status == :completed
      assert %{"got_a" => %{"n" => 1}, "got_b" => "yes", "got_c" => "nil"} = finished.context
    end
  end

  describe "waits inside lanes" do
    test "are the lane's: its id answers them, and the block's id finds nothing" do
      blocked = run_workflow(Audit4ApiLanes, %{})
      lanes = Durable.list_children!(blocked.id)
      assert length(lanes) == 2

      assert Durable.send_event(blocked.id, "credit_done", %{}) == {:error, :not_found}
      assert Durable.provide_input(blocked.id, "fraud_ok", %{}) == {:error, :not_found}

      [input] = Wait.list_pending_inputs!()
      assert input.input_name == "fraud_ok"
      assert input.workflow_id in Enum.map(lanes, & &1.id)

      events = for lane <- lanes, do: Durable.send_event(lane.id, "credit_done", %{"n" => 1})
      inputs = for lane <- lanes, do: Durable.provide_input(lane.id, "fraud_ok", %{"n" => 2})
      assert Enum.sort(events) == [:ok, {:error, :not_found}]
      assert Enum.sort(inputs) == [:ok, {:error, :not_found}]

      finished = drain(blocked)
      assert finished.status == :completed
      assert finished.context["after"] == true
      assert finished.context["lookups"]["credit"]["credit"] == ~s(%{"n" => 1})
      assert finished.context["lookups"]["fraud"]["fraud"] == ~s(%{"n" => 2})
    end

    test "cancel_wait on one lane cancels that lane's wait and no other" do
      blocked = run_workflow(Audit4ApiLanes, %{})
      [credit] = TestRepo.all(from(p in PendingEvent, where: p.event_name == "credit_done"))

      assert Wait.cancel_wait(credit.workflow_id, reason: "skip") == :ok
      still_blocked = drain(blocked)

      assert still_blocked.status == :waiting
      assert run(credit.workflow_id).status == :completed
      assert run(credit.workflow_id).context["credit"] == ~s({:cancelled, "skip"})
      assert [%{input_name: "fraud_ok", status: :pending}] = Wait.list_pending_inputs!()
    end
  end

  describe "an answer for a run that's gone" do
    setup do
      waiting = run_workflow(Audit4ApiSleeps, %{"ms" => 0})
      assert_waiting_for_input(waiting, "ok")
      {:ok, id: waiting.id}
    end

    test "a cancelled run takes no input or event, kept or not", %{id: id} do
      :ok = Durable.cancel(id, "gone")

      assert Durable.provide_input(id, "ok", %{}) == {:error, :not_found}
      assert Durable.send_event(id, "ok", %{}) == {:error, :not_found}
      assert Durable.send_event(id, "ok", %{}, buffer: true) == {:error, :finished}

      assert run(id).status == :cancelled
      assert [%{status: :cancelled, response: nil}] = TestRepo.all(PendingInput)
      assert TestRepo.all(PendingEvent) == []
    end

    test "a completed run takes none either, and its answer isn't replaced", %{id: id} do
      assert Durable.provide_input(id, "ok", "first") == :ok
      assert Durable.provide_input(id, "ok", "second") == {:error, :not_found}

      finished = drain(id)
      assert finished.status == :completed
      assert finished.context["answer"] == ~s("first")

      assert Durable.provide_input(id, "ok", "third") == {:error, :not_found}
      assert Durable.send_event(id, "ok", "x", buffer: true) == {:error, :finished}
      assert [%{status: :completed, response: %{"value" => "first"}}] = TestRepo.all(PendingInput)
    end

    test "an event kept for an id that was never a run isn't kept" do
      assert Durable.send_event(Ecto.UUID.generate(), "x", 1, buffer: true) ==
               {:error, :not_found}

      assert TestRepo.all(from(p in PendingEvent, where: p.status == :buffered)) == []
    end
  end

  describe "events kept for later" do
    test "an event kept before the run reached wait_for_any is delivered" do
      {:ok, id} = Durable.start(Audit4ApiWaitsAny, %{})
      assert Durable.send_event(id, "a", %{"n" => 1}, buffer: true) == :ok

      finished = drain(id)
      assert finished.status == :completed
      assert finished.context["got"] == ~s({"a", %{"n" => 1}})
      assert TestRepo.all(from(p in PendingEvent, where: p.status == :buffered)) == []
    end

    test "wait_for_any takes the first name with a kept event, and the other stays kept" do
      {:ok, id} = Durable.start(Audit4ApiWaitsAny, %{})
      for n <- 1..2, do: :ok = Durable.send_event(id, "b", %{"n" => n}, buffer: true)
      :ok = Durable.send_event(id, "a", %{"n" => 3}, buffer: true)

      finished = drain(id)
      assert finished.status == :completed
      assert finished.context["got"] == ~s({"a", %{"n" => 3}})

      assert [%{event_name: "b"}, %{event_name: "b"}] =
               TestRepo.all(from(p in PendingEvent, where: p.status == :buffered))
    end

    test "wait_for_all takes the kept events and waits for the rest" do
      {:ok, id} = Durable.start(Audit4ApiWaitsAll, %{})
      for n <- 1..2, do: :ok = Durable.send_event(id, "a", %{"n" => n}, buffer: true)

      waiting = drain(id)
      assert waiting.status == :waiting
      assert TestRepo.all(from(p in PendingEvent, where: p.status == :buffered)) == []
      assert Durable.send_event(id, "a", %{"n" => 9}) == {:error, :not_found}

      assert Durable.send_event(id, "b", %{"n" => 3}) == :ok
      finished = drain(id)
      assert finished.status == :completed
      assert finished.context["got"] == %{"a" => %{"n" => 2}, "b" => %{"n" => 3}}
    end

    test "wait_for_all with every event kept doesn't wait" do
      {:ok, id} = Durable.start(Audit4ApiWaitsAll, %{})
      :ok = Durable.send_event(id, "b", %{"n" => 1}, buffer: true)
      :ok = Durable.send_event(id, "a", %{"n" => 2}, buffer: true)

      finished = drain(id)
      assert finished.status == :completed
      assert finished.context["got"] == %{"a" => %{"n" => 2}, "b" => %{"n" => 1}}
    end

    test "of several kept for one name, the run gets the newest and none is left" do
      {:ok, id} = Durable.start(Audit4ApiThreeWaits, %{})
      for n <- 1..3, do: :ok = Durable.send_event(id, "a", %{"n" => n}, buffer: true)
      :ok = Durable.send_event(id, "unrelated", %{}, buffer: true)

      waiting = drain(id)

      assert_waiting_for_input(waiting, "b")
      assert waiting.context["a"] == %{"n" => 3}

      assert [%{event_name: "unrelated"}] =
               TestRepo.all(from(p in PendingEvent, where: p.status == :buffered))
    end
  end
end
