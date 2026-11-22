defmodule Durable.Audit4ApiDslTest do
  @moduledoc """
  Workflow definitions that can't work. Each should be refused when the module
  compiles, with an error that names the mistake: found at run time instead,
  it's a run that crashes the executor, retries for ever or quietly has no
  timeout.
  """
  use Durable.DataCase, async: false

  import Durable.Testing
  import ExUnit.CaptureIO

  @moduletag :capture_log

  # Compiles a workflow module from `body` and returns it.
  defp define(body) do
    name = "Audit4ApiDsl#{System.unique_integer([:positive])}"
    source = "defmodule #{name} do\n  use Durable\n  use Durable.Wait\n#{body}\nend"

    [{module, _bytecode}] = Code.compile_string(source)
    module
  end

  defp compile_error(body) do
    capture_io(:stderr, fn ->
      send(self(), {:raised, catch_error(define(body))})
    end)

    assert_received {:raised, error}
    error
  end

  # What the compiler said, whether it raised the message or printed it first.
  defp refused(body) do
    {error, printed} = with_io(:stderr, fn -> catch_error(define(body)) end)
    Exception.message(error) <> printed
  end

  defp one_step(opts), do: ~s|workflow "w" do\n step(:work, #{opts}, fn d -> {:ok, d} end)\nend|

  describe "definitions that are refused" do
    test "a step name used twice, also through a lane's qualified name" do
      assert refused("""
             workflow "w" do
               step(:a, fn d -> {:ok, d} end)
               step(:a, fn d -> {:ok, d} end)
             end
             """) =~ "step :a is defined twice"

      assert refused("""
             workflow "w" do
               step(:lookups__credit, fn d -> {:ok, d} end)
               parallel :lookups do
                 step(:credit, fn d -> {:ok, d} end)
                 step(:fraud, fn d -> {:ok, d} end)
               end
             end
             """) =~ "step :lookups__credit is defined twice"
    end

    test "a parallel block with no lanes, and a lane with a timeout that isn't one" do
      assert refused(~s|workflow "w" do\n parallel :p do\n end\nend|) =~ "has no lanes"

      assert %ArgumentError{} =
               compile_error("""
               workflow "w" do
                 parallel :p do
                   lane :a, timeout: -1 do
                     step(:a1, fn d -> {:ok, d} end)
                   end

                   step(:b, fn d -> {:ok, d} end)
                 end
               end
               """)
    end

    test "workflow options that don't exist or hold a value they can't" do
      for opts <- [
            "retries: 3",
            "on_failure: :explode",
            "on_failure: [rollback_after: 0]",
            "reuse: :sometimes",
            "on_duplicate: :ignore",
            "debounce: [timeout: 5]",
            "on_duplicate: :run_again, reuse: :never"
          ] do
        assert %ArgumentError{} =
                 compile_error(~s|workflow "w", #{opts} do\n step(:a, fn d -> {:ok, d} end)\nend|)
      end
    end

    test "two workflows in one module with a step of the same name both run their own" do
      module =
        define("""
        workflow "one" do
          step(:work, fn d -> {:ok, Map.put(d, "ran", "one")} end)
        end

        workflow "two" do
          step(:work, fn d -> {:ok, Map.put(d, "ran", "two")} end)
        end
        """)

      assert module.__workflows__() |> Enum.sort() == ["one", "two"]
      assert run_workflow(module, %{}, workflow: "one").context["ran"] == "one"
      assert run_workflow(module, %{}, workflow: "two").context["ran"] == "two"
    end

    test "a workflow with no steps completes with its input" do
      module = define(~s|workflow "empty" do\nend|)
      run = run_workflow(module, %{"a" => 1})

      assert run.status == :completed
      assert run.context == %{"a" => 1}
    end
  end

  describe "definitions that compile and shouldn't" do
    # workflow/3 (dsl/workflow.ex:65) never looks at the names already
    # registered: both are listed, both define `__workflow_def_same__/0`, and
    # the second can never be started.
    @tag :skip
    test "two workflows with one name in a module" do
      assert %{} =
               compile_error("""
               workflow "same" do
                 step(:a, fn d -> {:ok, Map.put(d, "ran", "first")} end)
               end

               workflow "same" do
                 step(:b, fn d -> {:ok, Map.put(d, "ran", "second")} end)
               end
               """)
    end

    # The name is spliced into function names and stored in a string column
    # (dsl/workflow.ex:72, :120). An atom or "" compiles and every start then
    # returns {:error, %Ecto.Changeset{}}.
    for name <- [":orders", ~s("")] do
      @tag :skip
      test "a workflow named #{name}" do
        assert %{} =
                 compile_error(
                   "workflow #{unquote(name)} do\n step(:a, fn d -> {:ok, d} end)\nend"
                 )
      end
    end

    # A name that isn't a literal crashes the macro itself with
    # Protocol.UndefinedError (String.Chars for the AST tuple, dsl/workflow.ex:72)
    # rather than a CompileError that says a workflow's name must be a string.
    @tag :skip
    test "a workflow whose name is a variable is refused in so many words" do
      error =
        compile_error(
          "title = \"dynamic\"\nworkflow title do\n step(:a, fn d -> {:ok, d} end)\nend"
        )

      assert error.__struct__ in [CompileError, ArgumentError]
    end

    # step/3 (dsl/step.ex:113) takes any term for a name. A string compiles, and
    # the executor raises ArgumentError from Atom.to_string/1 (executor.ex:2383)
    # with the run left :running.
    @tag :skip
    test "a step named with a string" do
      assert %{} = compile_error(~s|workflow "w" do\n step("work", fn d -> {:ok, d} end)\nend|)
    end

    # normalize_step_opts/1 (dsl/step.ex:155) keeps the four options it knows
    # and drops the rest without a word, so a misspelt `retry:` is no retry.
    @tag :skip
    test "a step option that doesn't exist" do
      assert %{} = compile_error(one_step("[retries: [max_attempts: 3]]"))
    end

    # Nothing checks the retry options (dsl/step.ex:162). `max_attempts: "3"`
    # compares as greater than any attempt number (step_runner.ex:605), so the
    # step retries for ever.
    for retry <- [~s([max_attempts: "3"]), "[max_attempts: 0]", "[max_attempts: -1]", "3"] do
      @tag :skip
      test "retry: #{retry}" do
        assert %{} = compile_error(one_step("[retry: #{unquote(retry)}]"))
      end
    end

    # An unknown backoff has no clause in Backoff.calculate/3 (backoff.ex): the
    # first failure raises FunctionClauseError out of the executor.
    @tag :skip
    test "a retry backoff that doesn't exist" do
      assert %{} = compile_error(one_step("[retry: [max_attempts: 2, backoff: :fibonacci]]"))
    end

    # A lane's timeout is checked (dsl/step.ex:918), a step's isn't: -5 or "5s"
    # reaches Task.yield/2 (step_runner.ex:441), which has no clause for it.
    for timeout <- ["-5", ~s("5s"), "1.5"] do
      @tag :skip
      test "a step with timeout: #{timeout}" do
        assert %{} = compile_error(one_step("[timeout: #{unquote(timeout)}]"))
      end
    end

    # Executor.deadline/2 (executor.ex:1235) takes a positive integer and treats
    # anything else as no timeout at all, so `timeout: "2h"` never times out.
    for timeout <- ["0", "-1", ~s("2h"), "1.5", ":infinity"] do
      @tag :skip
      test "a workflow with timeout: #{timeout}" do
        assert %{} =
                 compile_error(
                   ~s|workflow "w", timeout: #{unquote(timeout)} do\n step(:a, fn d -> {:ok, d} end)\nend|
                 )
      end
    end

    # `compensate:` isn't matched against the workflow's compensations
    # (executor.ex:3189): the run fails and rolls back with nothing undone.
    @tag :skip
    test "a step whose compensate: names no compensation" do
      assert %{} =
               compile_error("""
               workflow "w", on_failure: :rollback do
                 step(:book, [compensate: :unbook_misspelt], fn d -> {:ok, d} end)
                 step(:fail, fn _ -> {:error, "no"} end)
                 compensate(:unbook, fn d -> {:ok, d} end)
               end
               """)
    end
  end

  describe "what those definitions do at run time today" do
    test "a retry count that's a string retries until something stops it" do
      module =
        capture_io(:stderr, fn ->
          send(
            self(),
            {:module,
             define(
               ~s|workflow "w" do\n step(:work, [retry: [max_attempts: "3", backoff: :constant, base: 1]], fn _ -> {:error, "no"} end)\nend|
             )}
          )
        end)
        |> then(fn _ ->
          assert_received {:module, module}
          module
        end)

      {:ok, id} = Durable.start(module, %{})
      run = Durable.DataCase.execute_while_pending(id, 12)

      # Twelve attempts in, a step that asked for "3" is still going.
      assert run.status == :pending
      assert length(steps(run)) == 12
      :ok = Durable.cancel(id)
    end

    test "a workflow timeout that isn't a positive integer is no timeout" do
      for timeout <- ["0", "-1", ~s("2h")] do
        module =
          define(~s|workflow "w", timeout: #{timeout} do\n step(:a, fn d -> {:ok, d} end)\nend|)

        {:ok, id} = Durable.start(module, %{})

        assert {:ok, %{status: :pending}} = Durable.get_execution(id)
        assert TestRepo.get!(Durable.Storage.Schemas.WorkflowExecution, id).deadline_at == nil
      end
    end
  end
end
