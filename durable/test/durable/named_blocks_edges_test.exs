defmodule Durable.NamedBlocksEdgesTest do
  @moduledoc "Named blocks next to the rest of the engine: retries, queues, unnamed blocks, `into:`."
  use Durable.DataCase, async: false

  import Durable.Testing
  import Ecto.Query

  alias Durable.Storage.Schemas.WorkflowExecution
  alias Durable.TestRepo, as: Repo

  @moduletag :capture_log

  defmodule Seen do
    def put(key, value), do: :persistent_term.put({__MODULE__, key}, value)
    def get(key), do: :persistent_term.get({__MODULE__, key}, nil)
    def clear(key), do: :persistent_term.erase({__MODULE__, key})

    def queue(key) do
      {:ok, row} = Durable.Query.get_execution(Durable.Context.workflow_id())
      put(key, row.queue)
    end
  end

  defmodule Scoring do
    use Durable
    use Durable.Helpers

    workflow "scoring" do
      parallel :lookups,
        into: fn application, results ->
          if Seen.get(:scorer_down),
            do: {:error, "scorer is down"},
            else: {:ok, assign(application, :scores, results |> Map.keys() |> Enum.sort())}
        end do
        step(:credit, fn application -> {:ok, assign(application, :credit, 710)} end)
        step(:fraud, fn application -> {:ok, assign(application, :fraud, 0.02)} end)
      end

      step(:decide, fn application -> {:ok, assign(application, :decided, true)} end)
    end

    workflow "scoring_unnamed" do
      parallel into: fn application, results ->
                 if Seen.get(:scorer_down),
                   do: {:error, "scorer is down"},
                   else: {:ok, assign(application, :scores, results |> Map.keys() |> Enum.sort())}
               end do
        step(:credit, fn application -> {:ok, assign(application, :credit, 710)} end)
        step(:fraud, fn application -> {:ok, assign(application, :fraud, 0.02)} end)
      end

      step(:decide, fn application -> {:ok, assign(application, :decided, true)} end)
    end
  end

  defmodule TwoWorkflows do
    use Durable
    use Durable.Helpers

    workflow "personal" do
      parallel :lookups, into: fn loan, _results -> {:ok, assign(loan, :desk, "personal")} end do
        step(:credit, fn loan -> {:ok, loan} end)
      end
    end

    workflow "business" do
      parallel :lookups, into: fn loan, _results -> {:ok, assign(loan, :desk, "business")} end do
        step(:credit, fn loan -> {:ok, loan} end)
      end
    end
  end

  defmodule Mixed do
    use Durable
    use Durable.Helpers

    workflow "mixed" do
      parallel :lookups do
        step(:credit, fn loan -> {:ok, assign(loan, :credit, 710)} end)
        step(:fraud, fn loan -> {:ok, assign(loan, :fraud, 0.02)} end)
      end

      step(:plain, fn loan ->
        Seen.put(:plain, loan.lookups |> Map.keys() |> Enum.sort())
        {:ok, loan}
      end)

      parallel do
        step(:notify, fn loan ->
          Seen.put(:unnamed, loan.lookups |> Map.keys() |> Enum.sort())
          {:ok, loan}
        end)
      end
    end
  end

  defmodule Queues do
    use Durable

    workflow "queues" do
      step(:transcribe, [queue: :gpu], fn call -> {:ok, call} end)

      branch :language, fn call ->
        Seen.queue(:decider)
        {:english, call}
      end do
        :english ->
          step(:summarise, fn call ->
            Seen.queue(:arm)
            {:ok, call}
          end)
      end
    end
  end

  defmodule Jumps do
    use Durable
    use Durable.Helpers

    workflow "jumps" do
      parallel :lookups,
        into: fn loan, _results ->
          {:goto, :approve, assign(loan, :joined, loan[:joined] || 1)}
        end do
        step(:credit, fn loan -> {:ok, loan} end)
      end

      step(:manual_review, fn loan -> {:ok, assign(loan, :reviewed, true)} end)

      step(:approve, fn loan ->
        row = Repo.get(WorkflowExecution, Durable.Context.workflow_id())
        Seen.put(:record, row.context["__done__"])
        {:ok, assign(loan, :approved, true)}
      end)
    end
  end

  # A loan application: three lookups side by side, reduced by the next step.
  defmodule Loan do
    use Durable
    use Durable.Helpers

    workflow "loan" do
      parallel :lookups, on_error: :collect do
        step(:credit, fn application -> {:ok, assign(application, :score, 710)} end)

        step(:fraud, fn application ->
          Seen.put(:fraud_ran, true)
          {:ok, assign(application, :fraud, 0.02)}
        end)

        lane :sanctions do
          step(:query, fn application ->
            if application["sanctions_down"],
              do: {:fail, "sanctions API is down"},
              else: {:ok, assign(application, :hits, [])}
          end)

          step(:screen, fn application -> {:ok, assign(application, :listed, false)} end)
        end
      end

      step(:decide, [retry: [max_attempts: 2, base: 1]], fn application ->
        Seen.put({:decide, Logger.metadata()[:attempt]}, application.lookups)

        cond do
          application["decide_flaky"] && Logger.metadata()[:attempt] == 1 ->
            {:error, "first attempt"}

          match?(%{sanctions: {:error, _}}, application.lookups) ->
            {:ok, assign(application, :outcome, "manual_review")}

          true ->
            {:ok, %{"score" => score}} = application.lookups.credit

            {:ok,
             assign(application, :outcome, if(score > 650, do: "approved", else: "declined"))}
        end
      end)
    end
  end

  setup do
    on_exit(fn -> Seen.clear(:scorer_down) end)
  end

  defp lanes(run),
    do: Repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^run.id))

  describe "retrying a run whose into: failed once every lane had finished" do
    for workflow <- ["scoring", "scoring_unnamed"] do
      test "runs into: again and goes on (#{workflow})" do
        Seen.put(:scorer_down, true)
        run = run_workflow(Scoring, %{}, workflow: unquote(workflow))
        assert run.status == :failed
        assert Enum.all?(lanes(run), &(&1.status == :completed))

        Seen.clear(:scorer_down)
        {:ok, _} = Durable.retry(run.id)
        run = drain(run)

        assert run.status == :completed
        assert run.context["decided"]
        assert length(run.context["scores"]) == 2
        # The lanes had finished: nothing ran twice.
        assert length(lanes(run)) == 2
      end
    end
  end

  test "two workflows in one module each keep their own into:" do
    assert run_workflow(TwoWorkflows, %{}, workflow: "personal").context["desk"] == "personal"
    assert run_workflow(TwoWorkflows, %{}, workflow: "business").context["desk"] == "business"
  end

  test "a step of an unnamed block finds an earlier block's lanes by name, as any step does" do
    assert run_workflow(Mixed, %{}).status == :completed
    assert Seen.get(:plain) == [:credit, :fraud]
    assert Seen.get(:unnamed) == [:credit, :fraud]
  end

  test "a decider runs on the run's own queue, not the one the step before it used" do
    assert run_workflow(Queues, %{}).status == :completed
    assert Seen.get(:arm) == "default"
    assert Seen.get(:decider) == "default"
  end

  describe "into: that jumps" do
    test "records the jump with the save, so a run that comes back doesn't fan out again" do
      run = run_workflow(Jumps, %{})
      assert run.status == :completed
      assert Seen.get(:record) == %{"step" => "lookups", "arm" => "approve"}

      # Stored as it is when the worker is lost right after that save.
      {:ok, stopped} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(%{
          workflow_module: Atom.to_string(Jumps),
          workflow_name: "jumps",
          status: :pending,
          queue: "default",
          input: %{},
          context: %{
            "joined" => 1,
            "__string_keys__" => ["joined"],
            "__done__" => Seen.get(:record)
          },
          current_step: "lookups"
        })
        |> Repo.insert()

      run = drain(stopped)
      assert run.status == :completed
      assert lanes(run) == []
      assert run.context["approved"]
      refute run.context["reviewed"]
    end
  end

  describe "on_error: :collect" do
    test "every lane that finished is {:ok, its data}" do
      run = run_workflow(Loan, %{})

      assert run.status == :completed
      assert run.context["outcome"] == "approved"

      assert %{credit: {:ok, %{"score" => 710}}, fraud: {:ok, _}, sanctions: {:ok, sanctions}} =
               Seen.get({:decide, 1})

      assert sanctions["listed"] == false
    end

    test "a lane that fails is {:error, reason}; the others finish and the run goes on" do
      Seen.clear(:fraud_ran)
      run = run_workflow(Loan, %{"sanctions_down" => true})

      assert run.status == :completed
      assert run.context["outcome"] == "manual_review"
      assert Seen.get(:fraud_ran)

      assert %{credit: {:ok, _}, fraud: {:ok, _}, sanctions: {:error, reason}} =
               Seen.get({:decide, 1})

      assert reason["message"] =~ "sanctions API is down"

      assert lanes(run) |> Enum.map(& &1.status) |> Enum.sort() ==
               [:completed, :completed, :failed]

      # Stored, a pair is a two-item list.
      assert ["error", %{"message" => _}] = run.context["lookups"]["sanctions"]
      assert ["ok", %{"score" => 710}] = run.context["lookups"]["credit"]
    end

    test "the next step is handed the same pairs when the run comes back to it" do
      run = run_workflow(Loan, %{"sanctions_down" => true, "decide_flaky" => true})

      assert run.status == :completed
      assert Seen.get({:decide, 2}) == Seen.get({:decide, 1})
      assert %{sanctions: {:error, _}, credit: {:ok, _}} = Seen.get({:decide, 2})
    end

    test "only :fail_fast and :collect are ways for a named block to take a failure" do
      code = """
      defmodule Durable.NamedBlocksEdgesTest.Strategy do
        use Durable

        workflow "strategy" do
          parallel :lookups, on_error: :ignore do
            step(:credit, fn loan -> {:ok, loan} end)
          end
        end
      end
      """

      error = assert_raise CompileError, fn -> Code.compile_string(code) end
      assert error.description =~ ":collect"
    end
  end

  test "a named parallel block with nothing in it doesn't compile" do
    code = """
    defmodule Durable.NamedBlocksEdgesTest.Empty do
      use Durable

      workflow "empty" do
        parallel :lookups do
        end

        step(:decide, fn loan -> {:ok, loan} end)
      end
    end
    """

    error = assert_raise CompileError, fn -> Code.compile_string(code) end
    assert error.description =~ "lookups"
    assert error.description =~ "no lanes"
  end
end
