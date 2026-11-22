defmodule Durable.Audit4ApiDslTest do
  @moduledoc """
  Workflow definitions that can't work. One that would crash or hang a run is
  refused when the module compiles, with an error that names the mistake. One
  that runs but ignores what was written compiles with a warning at its line.
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

  # The module `body` compiles to, and what the compiler printed.
  defp warned(body) do
    {module, printed} = with_io(:stderr, fn -> define(body) end)
    assert function_exported?(module, :__workflows__, 0)
    {module, printed}
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

  describe "definitions that would crash or hang a run are refused" do
    test "two workflows with one name in a module" do
      assert %CompileError{description: description} =
               compile_error("""
               workflow "same" do
                 step(:a, fn d -> {:ok, Map.put(d, "ran", "first")} end)
               end

               workflow "same" do
                 step(:b, fn d -> {:ok, Map.put(d, "ran", "second")} end)
               end
               """)

      assert description =~ ~s(workflow "same" is defined twice)
    end

    # The name is spliced into function names and stored in a string column.
    for name <- [":orders", ~s(""), "42"] do
      test "a workflow named #{name}" do
        assert %CompileError{description: description} =
                 compile_error(
                   "workflow #{unquote(name)} do\n step(:a, fn d -> {:ok, d} end)\nend"
                 )

        assert description =~ "a workflow's name must be a non-empty string"
      end
    end

    test "a workflow whose name is a variable or an attribute is refused in so many words" do
      for name <- ["title", "@title"] do
        assert %CompileError{description: description} =
                 compile_error(
                   "title = \"dynamic\"\n@title title\nworkflow #{name} do\n step(:a, fn d -> {:ok, d} end)\nend"
                 )

        assert description =~ "written in place"
        assert description =~ "got: #{name}"
      end
    end

    test "a step named with a string" do
      assert %CompileError{description: description} =
               compile_error(~s|workflow "w" do\n step("work", fn d -> {:ok, d} end)\nend|)

      assert description =~ ~s(step "work" of workflow "w" must be named by an atom)
    end

    for retry <- [~s([max_attempts: "3"]), "[max_attempts: 0]", "[max_attempts: -1]"] do
      test "retry: #{retry}" do
        assert %CompileError{description: description} =
                 compile_error(one_step("[retry: #{unquote(retry)}]"))

        assert description =~ "max_attempts takes a positive integer"
      end
    end

    test "retry: that isn't a keyword list" do
      for retry <- ["3", ":exponential", "true"] do
        assert %CompileError{description: description} =
                 compile_error(one_step("[retry: #{retry}]"))

        assert description =~ "It takes a keyword list"
      end
    end

    test "a retry backoff that doesn't exist" do
      assert %CompileError{description: description} =
               compile_error(one_step("[retry: [max_attempts: 2, backoff: :fibonacci]]"))

      assert description =~ "backoff takes one of [:exponential, :linear, :constant]"
    end

    test "a retry base that isn't a number of milliseconds" do
      assert %CompileError{description: description} =
               compile_error(one_step(~s([retry: [max_attempts: 2, base: "1s"]])))

      assert description =~ "base and max_backoff take milliseconds"
    end

    for timeout <- ["-5", "0", ~s("5s"), "1.5", ":infinity"] do
      test "a step with timeout: #{timeout}" do
        assert %CompileError{description: description} =
                 compile_error(one_step("[timeout: #{unquote(timeout)}]"))

        assert description =~ "step :work of workflow \"w\" has timeout: #{unquote(timeout)}"
      end
    end

    test "the same checks reach a step in a lane, an arm, a decision and a compensation" do
      for body <- [
            "parallel :p do\n step(:work, [timeout: -5], fn d -> {:ok, d} end)\n end",
            "parallel :p do\n lane :l do\n step(:work, [retry: 3], fn d -> {:ok, d} end)\n end\n end",
            "branch :b, fn d -> {:x, d} end do\n :x -> step(:work, [timeout: 0], fn d -> {:ok, d} end)\n end",
            "branch on: fn d -> d end do\n 1 -> step(:work, [timeout: 0], fn d -> {:ok, d} end)\n end",
            "branch :b, [retry: [backoff: :never]], fn d -> {:x, d} end do\n :x -> step(:work, fn d -> {:ok, d} end)\n end",
            "decision(:work, [retry: [max_attempts: 0]], fn d -> {:ok, d} end)",
            "compensate(:work, [timeout: -1], fn d -> {:ok, d} end)"
          ] do
        assert %CompileError{} = compile_error(~s|workflow "w" do\n #{body}\nend|)
      end
    end

    # Executor.deadline/2 takes a positive integer; a string or a float can only
    # be a mistake.
    for timeout <- [~s("2h"), "1.5", ":never", "[hours: 2]"] do
      test "a workflow with timeout: #{timeout}" do
        assert %CompileError{description: description} =
                 compile_error(
                   ~s|workflow "w", timeout: #{unquote(timeout)} do\n step(:a, fn d -> {:ok, d} end)\nend|
                 )

        assert description =~ ~s(workflow "w" has timeout:)
      end
    end

    test "a step whose compensate: names no compensation" do
      assert %CompileError{description: description} =
               compile_error("""
               workflow "w", on_failure: :rollback do
                 step(:book, [compensate: :unbook_misspelt], fn d -> {:ok, d} end)
                 step(:fail, fn _ -> {:error, "no"} end)
                 compensate(:unbook, fn d -> {:ok, d} end)
               end
               """)

      assert description =~ "has compensate: :unbook_misspelt, but the workflow has no"
    end

    test "a compensation of another workflow in the module doesn't count" do
      assert %CompileError{} =
               compile_error("""
               workflow "one" do
                 step(:book, [compensate: :unbook], fn d -> {:ok, d} end)
               end

               workflow "two" do
                 step(:book, fn d -> {:ok, d} end)
                 compensate(:unbook, fn d -> {:ok, d} end)
               end
               """)
    end
  end

  describe "definitions that run but ignore what was written warn" do
    # normalize_step_opts/4 keeps the options it knows, so a misspelt `retry:`
    # is a step with no retries.
    test "a step option that doesn't exist, with the one it probably meant" do
      {module, printed} =
        warned(
          ~s|workflow "w" do\n step(:work, [retries: [max_attempts: 3]], fn _ -> {:error, "no"} end)\nend|
        )

      assert printed =~ "unknown option :retries on :work is ignored; did you mean :retry?"
      # The line of the step, in the source given to the compiler.
      assert printed =~ "nofile:5"

      # It runs as written: one attempt.
      run = run_workflow(module, %{})
      assert run.status == :failed
      assert length(steps(run)) == 1
    end

    test "an option that resembles none gets no guess" do
      {_module, printed} = warned(one_step("[colour: :red]"))
      assert printed =~ "unknown option :colour on :work is ignored\n"
    end

    test "a retry option that doesn't exist" do
      {_module, printed} = warned(one_step("[retry: [max_attempt: 3, jitter: false]]"))

      assert printed =~
               "unknown option :max_attempt on retry: of :work is ignored; did you mean :max_attempts?"

      assert printed =~ "unknown option :jitter on retry: of :work is ignored"
    end

    test "wherever the step is written, at its own line" do
      {_module, printed} =
        warned("""
        workflow "w" do
          parallel :p do
            lane :l do
              step(:in_lane, [retrys: []], fn d -> {:ok, d} end)
            end

            step(:alone, [optional: true, timout: 5], fn d -> {:ok, d} end)
          end

          branch :b, [queue: :slow], fn d -> {:x, d} end do
            :x -> step(:in_arm, [compensat: :undo], fn d -> {:ok, d} end)
          end

          decision(:decide, [time_out: 5], fn d -> {:ok, d} end)
          compensate(:undo, [queue: :slow], fn d -> {:ok, d} end)
        end
        """)

      assert printed =~ "unknown option :retrys on :in_lane is ignored; did you mean :retry?"
      assert printed =~ "nofile:7"
      assert printed =~ "unknown option :timout on :alone is ignored; did you mean :timeout?"
      assert printed =~ "nofile:10"
      refute printed =~ ":optional"
      assert printed =~ "unknown option :queue on :b is ignored"

      assert printed =~
               "unknown option :compensat on :in_arm is ignored; did you mean :compensate?"

      assert printed =~ "unknown option :time_out on :decide is ignored; did you mean :timeout?"
      assert printed =~ "unknown option :queue on compensate :undo is ignored"
    end

    test "every option a step takes, and a lane's, says nothing" do
      {_module, printed} =
        warned("""
        workflow "w" do
          step(
            :work,
            [
              retry: [max_attempts: 3, backoff: :linear, base: 0, max_backoff: 10],
              timeout: seconds(5),
              compensate: :undo,
              queue: :default
            ],
            fn d -> {:ok, d} end
          )

          parallel :p do
            lane :l, optional: true, default: %{}, timeout: seconds(5) do
              step(:a, [timeout: 5], fn d -> {:ok, d} end)
            end

            step(:b, [optional: true, default: %{}], fn d -> {:ok, d} end)
          end

          compensate(:undo, [retry: [max_attempts: 2], timeout: 5], fn d -> {:ok, d} end)
        end
        """)

      assert printed == ""
    end

    # Executor.deadline/2 treats anything but a positive integer as no timeout.
    for timeout <- ["0", "-1", ":infinity"] do
      test "a workflow with timeout: #{timeout} has no timeout, and says so" do
        {module, printed} =
          warned(
            ~s|workflow "w", timeout: #{unquote(timeout)} do\n step(:a, fn d -> {:ok, d} end)\nend|
          )

        assert printed =~
                 ~s(workflow "w" has timeout: #{unquote(timeout)}, which means no timeout)

        assert printed =~ "nofile:4"

        {:ok, id} = Durable.start(module, %{})
        assert TestRepo.get!(Durable.Storage.Schemas.WorkflowExecution, id).deadline_at == nil
      end
    end

    test "a workflow timeout written with a helper is checked as the number it is" do
      {module, printed} =
        warned(~s|workflow "w", timeout: hours(2) do\n step(:a, fn d -> {:ok, d} end)\nend|)

      assert printed == ""
      {:ok, id} = Durable.start(module, %{})
      assert TestRepo.get!(Durable.Storage.Schemas.WorkflowExecution, id).deadline_at != nil
    end
  end
end
