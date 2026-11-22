defmodule Durable.Audit4ApiReservedKeysTest do
  @moduledoc """
  A run's input comes from outside: a webhook body, a form. A first step that
  hands it on (`{:ok, data}`, `Map.put(data, ...)`) puts it in the run's data,
  where the engine keeps its own markers under `__names__`. None of them may
  be read from what a caller sent.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.WorkflowExecution

  @moduletag :capture_log

  defmodule Audit4ApiPassThenSleep do
    use Durable
    use Durable.Wait

    workflow "audit4_api_pass_then_sleep" do
      step(:first, fn data -> {:ok, data} end)

      step(:second, fn data ->
        sleep(10)
        {:ok, Map.put(data, "second", true)}
      end)

      step(:third, fn data -> {:ok, Map.put(data, "third", true)} end)
    end
  end

  defmodule Audit4ApiBooks do
    use Durable

    workflow "audit4_api_books" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
      step(:confirm, fn data -> {:ok, Map.put(data, "confirmed", true)} end)
      compensate(:unbook, fn data -> {:ok, data} end)
    end
  end

  defmodule Audit4ApiAsksFirst do
    use Durable
    use Durable.Wait

    workflow "audit4_api_asks_first" do
      step(:ask, fn data ->
        {:ok, Map.put(data, "answer", inspect(wait_for_approval("ok")))}
      end)
    end
  end

  defmodule Audit4ApiSleepsFirst do
    use Durable
    use Durable.Wait

    workflow "audit4_api_sleeps_first" do
      step(:nap, fn data ->
        sleep(3_600_000)
        {:ok, Map.put(data, "napped", true)}
      end)
    end
  end

  defp step_names(run), do: run |> steps() |> Enum.map(& &1.step_name)

  # A step's data handed on with "__fail__" in it fails the run at the next step
  # with the caller's error: executor.ex:1266 (resume_failure/1) reads the key
  # from whatever the context holds, and nothing strips it from a step's result.
  @tag :skip
  test "input carrying __fail__ doesn't fail the run" do
    run =
      run_workflow(Audit4ApiPassThenSleep, %{"__fail__" => %{"type" => "x", "message" => "y"}})

    assert run.status == :completed
    assert run.error == nil
  end

  # The same key with type "rollback" runs the workflow's compensations, as if a
  # step had returned {:rollback, _}: executor.ex:1448 -> fail_at/5 ->
  # handle_step_failure/4 -> asks_rollback?/1 (executor.ex:3065).
  @tag :skip
  test "input carrying __fail__ of type rollback doesn't undo the run" do
    input = %{"__fail__" => %{"type" => "rollback", "message" => "from outside"}}
    run = run_workflow(Audit4ApiBooks, input)

    assert run.status == :completed
    assert step_names(run) == ["book", "confirm"]
  end

  # A stored "__done__" naming a step makes the run skip it when it comes back
  # there: executor.ex:904 pops the key from the context and after_done/2
  # (executor.ex:1326) drops the step. The save before a wait (:keep, no done
  # record, executor.ex:1528) leaves a caller's "__done__" in place.
  @tag :skip
  test "input carrying __done__ doesn't make the run skip a step" do
    run = run_workflow(Audit4ApiPassThenSleep, %{"__done__" => %{"step" => "second"}})

    assert run.status == :completed
    assert run.context["second"] == true
    assert run.context["third"] == true
  end

  # "__rollback__" in a step's data sends the run to roll_back/3 when it next
  # resumes (executor.ex:909): it ends failed with the caller's error and the
  # rest of its steps never run.
  @tag :skip
  test "input carrying __rollback__ doesn't send the run to be rolled back" do
    marker = %{"error" => %{"type" => "from outside"}, "status" => "failed"}
    run = run_workflow(Audit4ApiPassThenSleep, %{"__rollback__" => marker})

    assert run.status == :completed
    assert run.context["third"] == true
  end

  # A marker that isn't the shape roll_back/3 matches on (executor.ex:3135)
  # raises MatchError out of the executor instead.
  @tag :skip
  test "a malformed __rollback__ in the data doesn't crash the executor" do
    run = run_workflow(Audit4ApiPassThenSleep, %{"__rollback__" => 1})

    assert run.status == :completed
  end

  # The first step's process context is the raw input (step_runner.ex:355), wait
  # markers and all, so a first step's wait reads the caller's "__cancelled__"
  # (wait.ex:193) and returns {:cancelled, _} without ever waiting.
  @tag :skip
  test "input carrying __cancelled__ doesn't answer the first step's wait" do
    run = run_workflow(Audit4ApiAsksFirst, %{"__cancelled__" => "from outside"})

    assert run.status == :waiting
    assert_waiting_for_input(run, "ok")
  end

  describe "markers that are already kept out" do
    test "__parallel_step in the input doesn't turn the run into a lane" do
      run = run_workflow(Audit4ApiPassThenSleep, %{"__parallel_step" => "second"})

      assert run.status == :completed
      assert step_names(run) == ["first", "second", "second", "third"]
      assert %{"second" => true, "third" => true} = run.context
    end

    test "__sleep_satisfied__ in the input doesn't end the first step's sleep" do
      {:ok, id} = Durable.start(Audit4ApiSleepsFirst, %{"__sleep_satisfied__" => "nap"})
      Executor.execute_workflow(id, Config.get(Durable))
      run = TestRepo.get!(WorkflowExecution, id)

      assert run.status == :waiting
      assert DateTime.diff(run.scheduled_at, DateTime.utc_now()) > 3_000
    end

    for key <- ["__string_keys__", "__atom_keys__", "__timeout__", "__wait_group_result__"] do
      test "#{key} in the input leaves the run to finish with every step" do
        for value <- [7, ["second"], %{"step" => "second"}, nil] do
          run = run_workflow(Audit4ApiPassThenSleep, %{unquote(key) => value, "keep" => 1})

          assert run.status == :completed
          assert %{"second" => true, "third" => true, "keep" => 1} = run.context
        end
      end
    end

    test "the engine's own record of key shapes isn't shown by get_execution" do
      run = run_workflow(Audit4ApiAsksFirst, %{"a" => 1})
      {:ok, shown} = Durable.get_execution(run.id)

      assert shown.status == :waiting
      assert Map.keys(shown.context) == ["a"]
    end
  end
end
