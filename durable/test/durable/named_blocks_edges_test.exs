defmodule Durable.NamedBlocksEdgesTest do
  @moduledoc "Named blocks next to the rest of the engine: retries, queues, other blocks, `into:`."
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
  end

  defmodule RateLock do
    use Durable
    use Durable.Helpers

    # The rate is held while the lookups run. `into:` forgets its `{:ok, _}`.
    workflow "rate_lock", on_failure: :rollback do
      step(:lock_rate, [compensate: :release_rate], fn loan -> {:ok, assign(loan, :rate, 4.1)} end)

      parallel :lookups, into: fn loan, _results -> assign(loan, :scored, true) end do
        step(:credit, fn loan -> {:ok, assign(loan, :credit, 710)} end)
      end

      compensate(:release_rate, fn loan ->
        Seen.put(:rate_released, true)
        {:ok, loan}
      end)
    end
  end

  defmodule Checks do
    use Durable
    use Durable.Helpers
    use Durable.Orchestration
    use Durable.Wait

    # The applicant uploads a document while the credit bureau is asked.
    workflow "checks" do
      parallel :checks do
        step(:identity, fn application ->
          case call_workflow(__MODULE__, %{"applicant" => application["applicant"]},
                 ref: :identity,
                 workflow: "verify_identity"
               ) do
            {:ok, result} -> {:ok, %{verified: result["verified"]}}
            {:error, reason} -> {:error, reason}
          end
        end)

        step(:credit, [retry: [max_attempts: 2]], fn _application ->
          if Seen.get(:bureau_down), do: {:error, "bureau is down"}, else: {:ok, %{score: 710}}
        end)
      end
    end

    workflow "verify_identity" do
      step(:check_document, fn applicant ->
        document = wait_for_input("document")
        {:ok, assign(applicant, :verified, document["valid"])}
      end)
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

      parallel :send do
        step(:notify, fn loan ->
          Seen.put(:later, loan.lookups |> Map.keys() |> Enum.sort())
          {:ok, loan}
        end)
      end
    end
  end

  defmodule Outputs do
    use Durable
    use Durable.Helpers

    workflow "loan" do
      parallel :lookups do
        step(:credit, fn loan -> {:ok, assign(loan, :score, 710)} end)
        step(:fraud, fn _loan -> {:ok, %{risk: 0.02}} end)
        step(:address, fn loan -> {:ok, loan} end)

        lane :sanctions do
          step(:query, fn loan -> {:ok, assign(loan, :hits, [])} end)
          step(:screen, fn loan -> {:ok, assign(loan, :listed, loan.hits != [])} end)
        end
      end

      parallel :quotes, on_error: :collect do
        step(:north, fn loan -> {:ok, assign(loan, :rate, 6.1)} end)
        step(:south, fn _loan -> {:error, "no answer"} end)
      end

      step(:decide, fn loan ->
        Seen.put(:loan, loan)
        {:ok, loan}
      end)
    end

    workflow "loan_into" do
      parallel :lookups,
        into: fn loan, results ->
          Seen.put(:loan_into, results)
          {:ok, loan}
        end do
        step(:credit, fn loan -> {:ok, assign(loan, :score, 710)} end)
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
        Seen.put(:record, row.engine_state["__done__"])
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

  # Lookups a decision can do without: a failed one doesn't fail the block.
  defmodule Enrich do
    use Durable
    use Durable.Helpers

    workflow "enrich" do
      parallel :lookups do
        step(:credit, fn application ->
          if application["bureau_down"],
            do: {:fail, "credit bureau is down"},
            else: {:ok, assign(application, :score, 710)}
        end)

        step(:device, [optional: true], fn application ->
          if application["device_down"],
            do: {:fail, "device check is down"},
            else: {:ok, assign(application, :device, "known")}
        end)

        lane :social, optional: true do
          step(:find, fn application ->
            if application["social_down"],
              do: {:fail, "profile search is down"},
              else: {:ok, assign(application, :profiles, 2)}
          end)

          step(:rate, fn application -> {:ok, assign(application, :rated, true)} end)
        end
      end

      step(:decide, [retry: [max_attempts: 2, base: 1]], fn application ->
        Seen.put({:enrich, Logger.metadata()[:attempt]}, application.lookups)

        if application["decide_flaky"] && Logger.metadata()[:attempt] == 1,
          do: {:error, "first attempt"},
          else: {:ok, assign(application, :decided, true)}
      end)
    end

    workflow "enrich_collect" do
      parallel :lookups, on_error: :collect do
        step(:credit, fn application -> {:ok, assign(application, :score, 710)} end)
        step(:device, [optional: true], fn _application -> {:fail, "device check is down"} end)
      end

      step(:decide, fn application ->
        Seen.put(:enrich_collect, application.lookups)
        {:ok, application}
      end)
    end
  end

  setup do
    on_exit(fn -> Seen.clear(:scorer_down) end)
  end

  defp lanes(run),
    do: Repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^run.id))

  describe "retrying a run whose into: failed once every lane had finished" do
    test "runs into: again and goes on" do
      Seen.put(:scorer_down, true)
      run = run_workflow(Scoring, %{}, workflow: "scoring")
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

  describe "retrying a block that stopped a lane waiting for its child workflow" do
    # Stopping the block cancelled the lane's child. A retry that put the lane
    # back without it would have `call_workflow` find the child cancelled and
    # fail the lane again with "parent_cancelled".
    test "puts that lane back to work, child and all" do
      on_exit(fn -> Seen.clear(:bureau_down) end)
      Seen.put(:bureau_down, true)
      run = run_workflow(Checks, %{"applicant" => "A-1"}, workflow: "checks")
      assert run.status == :failed
      assert run.error["message"] == "bureau is down"

      Seen.clear(:bureau_down)
      {:ok, _} = Durable.retry(run.id)
      run = drain(run)
      assert run.status == :waiting

      identity = Enum.find(lanes(run), &(&1.current_step == "checks__identity"))
      [child] = Enum.filter(lanes(identity), &(&1.status == :waiting))
      :ok = Durable.provide_input(child.id, "document", %{"valid" => true})
      run = drain(run)

      assert run.status == :completed

      assert %{"identity" => %{"verified" => true}, "credit" => %{"score" => 710}} =
               run.context["checks"]
    end
  end

  test "an into: that returns something else fails the run as a step would, compensations and all" do
    on_exit(fn -> Seen.clear(:rate_released) end)
    run = run_workflow(RateLock, %{})

    assert run.status == :compensated
    assert run.error["type"] == "parallel_into_error"
    assert run.error["message"] =~ "into: of parallel :lookups must return {:ok, data}"
    assert Seen.get(:rate_released)
  end

  test "two workflows in one module each keep their own into:" do
    assert run_workflow(TwoWorkflows, %{}, workflow: "personal").context["desk"] == "personal"
    assert run_workflow(TwoWorkflows, %{}, workflow: "business").context["desk"] == "business"
  end

  test "a step of a later block finds an earlier block's lanes by name, as any step does" do
    assert run_workflow(Mixed, %{}).status == :completed
    assert Seen.get(:plain) == [:credit, :fraud]
    assert Seen.get(:later) == [:credit, :fraud]
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
          context: %{"joined" => 1},
          engine_state: %{
            "v" => 1,
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

  describe "optional: true" do
    test "an optional lane that fails is nil to the next step, and the run goes on" do
      run =
        run_workflow(Enrich, %{"device_down" => true, "social_down" => true}, workflow: "enrich")

      assert run.status == :completed
      assert %{credit: %{"score" => 710}, device: nil, social: nil} = Seen.get({:enrich, 1})

      # Why it failed is on the lane's own run.
      failed = Enum.filter(lanes(run), &(&1.status == :failed))

      assert failed |> Enum.map(& &1.error["message"]) |> Enum.sort() ==
               ["device check is down", "profile search is down"]
    end

    test "an optional lane that finishes is its data, like any lane" do
      run = run_workflow(Enrich, %{}, workflow: "enrich")

      assert run.status == :completed

      assert %{device: %{"device" => "known"}, social: %{"rated" => true}} =
               Seen.get({:enrich, 1})
    end

    test "a lane that isn't optional still fails the block" do
      run =
        run_workflow(Enrich, %{"bureau_down" => true, "device_down" => true}, workflow: "enrich")

      assert run.status == :failed
      assert run.error["message"] =~ "credit bureau is down"
    end

    test "the next step is handed the same when the run comes back to it" do
      input = %{"device_down" => true, "decide_flaky" => true}
      run = run_workflow(Enrich, input, workflow: "enrich")

      assert run.status == :completed
      assert %{device: nil, credit: %{}} = Seen.get({:enrich, 2})
      assert Seen.get({:enrich, 2}) == Seen.get({:enrich, 1})
    end

    test "in a block that collects it is {:error, reason}, as every failed lane is" do
      run = run_workflow(Enrich, %{}, workflow: "enrich_collect")

      assert run.status == :completed

      assert %{credit: {:ok, _}, device: {:error, %{"message" => "device check is down"}}} =
               Seen.get(:enrich_collect)
    end

    test "is for a lane of a named block" do
      code = """
      defmodule Durable.NamedBlocksEdgesTest.OptionalLane do
        use Durable

        workflow "optional_lane" do
          parallel :lookups do
            lane :social, optional: :sometimes do
              step(:find, fn loan -> {:ok, loan} end)
            end
          end
        end
      end
      """

      error = assert_raise CompileError, fn -> Code.compile_string(code) end
      assert error.description =~ "optional: true"
    end
  end

  describe "what a lane hands to the next step" do
    test "is what it produced, not the data it was started with" do
      run =
        run_workflow(Outputs, %{"statements" => String.duplicate("x", 1_000)}, workflow: "loan")

      assert run.status == :completed

      assert %{
               credit: %{"score" => 710},
               fraud: %{"risk" => 0.02},
               address: %{},
               sanctions: %{"hits" => [], "listed" => false}
             } == Seen.get(:loan).lookups

      # One copy of the statements in the stored run, not one per lane.
      assert byte_size(Jason.encode!(run.context)) < 2_000
    end

    test "leaves out an earlier block's lanes, so blocks don't pile up copies" do
      run_workflow(Outputs, %{"statements" => "many"}, workflow: "loan")

      assert %{north: {:ok, %{"rate" => 6.1}}, south: {:error, %{"message" => "no answer"}}} =
               Seen.get(:loan).quotes

      assert {:ok, %{"rate" => 6.1}} == Seen.get(:loan).quotes.north
    end

    test "is what into: is handed too" do
      run_workflow(Outputs, %{"statements" => "many"}, workflow: "loan_into")
      assert Seen.get(:loan_into) == %{credit: {:ok, %{"score" => 710}}}
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
