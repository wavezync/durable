defmodule Durable.NamedBlocksTest do
  @moduledoc "Named `branch` (a deciding step with arms) and named `parallel` (lanes)."
  use Durable.DataCase, async: false

  import Durable.Testing
  import Ecto.Query

  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}
  alias Durable.TestRepo, as: Repo

  @moduletag :capture_log

  # Fails a step's first attempt, so the run parks and comes back to it.
  defmodule Flaky do
    def once(data) do
      if Logger.metadata()[:attempt] == 1, do: {:error, "first attempt"}, else: {:ok, data}
    end
  end

  defmodule Risk do
    use Durable
    use Durable.Helpers

    workflow "risk" do
      step(:score, fn order -> {:ok, assign(order, :seen, ["score"])} end)

      branch :risk, [retry: [max_attempts: 3, base: 1]], fn order ->
        cond do
          order["risk"] == "flaky" and Logger.metadata()[:attempt] == 1 -> {:error, "lookup down"}
          order["risk"] == "flaky" -> {:clear, order}
          order["risk"] == "unknown" -> {:nowhere, order}
          order["risk"] < 40 -> {:clear, order}
          order["risk"] < 80 -> {:review, assign(order, :decided, "review")}
          true -> {:blocked, order}
        end
      end do
        :clear ->
          pass()

        :review ->
          step(:ask, fn order -> {:ok, assign(order, :seen, order.seen ++ ["ask"])} end)

          step(:record, [retry: [max_attempts: 2, base: 1]], fn order ->
            with {:ok, order} <- Flaky.once(order),
                 do: {:ok, assign(order, :seen, order.seen ++ ["record"])}
          end)

        :blocked ->
          step(:ask, fn order -> {:ok, assign(order, :seen, order.seen ++ ["blocked"])} end)
          step(:stop, fn _order -> {:cancel, "blocked by risk check"} end)
      end

      step(:charge, fn order -> {:ok, assign(order, :seen, order.seen ++ ["charge"])} end)
    end
  end

  defmodule Nested do
    use Durable
    use Durable.Helpers

    workflow "nested" do
      branch :outer, fn data -> {String.to_existing_atom(data["outer"]), data} end do
        :left ->
          step(:before, fn data -> {:ok, assign(data, :seen, ["before"])} end)

          branch :inner, fn data -> {String.to_existing_atom(data["inner"]), data} end do
            :up ->
              step(:work, [retry: [max_attempts: 2, base: 1]], fn data ->
                with {:ok, data} <- Flaky.once(data),
                     do: {:ok, assign(data, :seen, data.seen ++ ["up"])}
              end)

              step(:more, fn data -> {:ok, assign(data, :seen, data.seen ++ ["more"])} end)

            :down ->
              step(:work, fn data -> {:ok, assign(data, :seen, data.seen ++ ["down"])} end)
          end

          step(:after, fn data -> {:ok, assign(data, :seen, data.seen ++ ["after"])} end)

        :right ->
          step(:work, fn data -> {:ok, assign(data, :seen, ["right"])} end)
      end

      step(:last, fn data -> {:ok, assign(data, :seen, data.seen ++ ["last"])} end)
    end
  end

  defmodule Fulfil do
    use Durable
    use Durable.Helpers

    workflow "fulfil" do
      step(:charge, fn order -> {:ok, assign(order, :charged, true)} end)

      parallel :fulfil do
        lane :shipment do
          step(:pack, fn order -> {:ok, assign(order, :packed, true)} end)

          step(:book, [retry: [max_attempts: 2, base: 1]], fn order ->
            with {:ok, order} <- Flaky.once(order), do: {:ok, assign(order, :booked, true)}
          end)

          branch :destination, fn order ->
            if order["country"] == "LK", do: {:domestic, order}, else: {:abroad, order}
          end do
            :domestic -> step(:courier, fn order -> {:ok, assign(order, :by, "courier")} end)
            :abroad -> step(:freight, fn order -> {:ok, assign(order, :by, "freight")} end)
          end
        end

        lane :paperwork do
          step(:invoice, fn order ->
            if order["country"] == "nowhere",
              do: {:error, "no tax rules"},
              else: {:ok, assign(order, :invoice, "INV-1")}
          end)
        end

        step(:points, fn order -> {:ok, assign(order, :points, 10)} end)
      end

      step(:close, [retry: [max_attempts: 2, base: 1]], fn order ->
        with {:ok, order} <- Flaky.once(order) do
          %{fulfil: %{shipment: shipment, paperwork: paperwork, points: points}} = order

          {:ok, assign(order, :summary, [shipment["by"], paperwork["invoice"], points["points"]])}
        end
      end)
    end
  end

  defmodule InArm do
    use Durable
    use Durable.Helpers

    workflow "in_arm" do
      branch :kind, fn data -> {:both, data} end do
        :both ->
          parallel :notify, into: fn data, results -> {:ok, assign(data, :got, results)} end do
            step(:email, fn data -> {:ok, assign(data, :sent, "email")} end)
            step(:sms, fn _data -> {:error, "no credit"} end)
          end

        :none ->
          pass()
      end
    end
  end

  defp ran(run) do
    for %{step_name: name, status: :completed} <- steps(run), do: name
  end

  describe "a named branch" do
    test "names what's inside it after the block and the arm" do
      {:ok, definition} = Risk.__workflow_definition__("risk")

      assert Enum.map(definition.steps, & &1.name) == [
               :score,
               :risk,
               :risk__review__ask,
               :risk__review__record,
               :risk__blocked__ask,
               :risk__blocked__stop,
               :charge
             ]
    end

    test "runs the arm its decider names, then what follows the block" do
      run = run_workflow(Risk, %{"risk" => 62})

      assert run.status == :completed
      assert run.context["seen"] == ["score", "ask", "record", "charge"]
      assert run.context["decided"] == "review"
    end

    test "an arm with pass() goes straight on" do
      run = run_workflow(Risk, %{"risk" => 10})

      assert run.status == :completed
      assert run.context["seen"] == ["score", "charge"]
    end

    test "the decider is a step: it has a row that records the arm" do
      run = run_workflow(Risk, %{"risk" => 62})

      [decided] = for %{step_name: "risk"} = step <- steps(run), do: step

      assert decided.status == :completed
      assert decided.output["target_step"] == "review"
    end

    test "a decider that fails is retried like a step" do
      run = run_workflow(Risk, %{"risk" => "flaky"})

      assert_status(run, :completed)
      assert [:failed, :completed] = for(%{step_name: "risk"} = s <- steps(run), do: s.status)
    end

    test "an arm the block doesn't have fails the run at once, naming it" do
      run = run_workflow(Risk, %{"risk" => "unknown"})

      assert run.status == :failed
      assert run.error["type"] == "branch_error"
      assert run.error["message"] =~ "[:clear, :review, :blocked]"
      assert run.error["message"] =~ ":nowhere"
      assert [_one_attempt] = for(%{step_name: "risk"} = s <- steps(run), do: s)
    end

    test "an arm can end the run" do
      run = run_workflow(Risk, %{"risk" => 95})

      assert run.status == :cancelled
      assert "risk__blocked__ask" in ran(run)
      refute "charge" in ran(run)
    end

    test "a run that comes back inside an arm finishes that arm and no other" do
      run = run_workflow(Risk, %{"risk" => 62})

      # `record` failed once, so the run was parked and resumed at it.
      assert [:failed, :completed] =
               for(%{step_name: "risk__review__record"} = s <- steps(run), do: s.status)

      assert [_once] = for(%{step_name: "risk"} = s <- steps(run), do: s)
      refute "risk__blocked__ask" in ran(run)
    end

    test "a branch inside an arm resumes in its own arm" do
      run = run_workflow(Nested, %{"outer" => "left", "inner" => "up"})

      assert run.status == :completed
      assert run.context["seen"] == ["before", "up", "more", "after", "last"]
      refute "outer__left__inner__down__work" in ran(run)
      refute "outer__right__work" in ran(run)
    end

    test "the same step name in two arms is two steps" do
      assert run_workflow(Nested, %{"outer" => "right"}).context["seen"] == ["right", "last"]

      assert run_workflow(Nested, %{"outer" => "left", "inner" => "down"}).context["seen"] ==
               ["before", "down", "after", "last"]
    end
  end

  describe "a named parallel block" do
    test "runs each lane as its own run, in order, and joins in the next step" do
      run = run_workflow(Fulfil, %{"country" => "LK"})

      assert run.status == :completed
      assert run.context["summary"] == ["courier", "INV-1", 10]

      lanes =
        Repo.all(
          from(w in WorkflowExecution,
            where: w.parent_workflow_id == ^run.id,
            select: {w.status, w.context}
          )
        )

      assert length(lanes) == 3
      assert Enum.all?(lanes, fn {status, _} -> status == :completed end)
    end

    test "a lane that comes back runs only its own steps" do
      run = run_workflow(Fulfil, %{"country" => "DE"})
      assert run.status == :completed

      # `book` failed once, so the shipment lane was parked and resumed.
      shipment =
        Repo.one(
          from(s in StepExecution,
            where: s.step_name == "fulfil__shipment__book" and s.status == :completed,
            select: s.workflow_id
          )
        )

      names =
        Repo.all(
          from(s in StepExecution,
            where: s.workflow_id == ^shipment and s.status == :completed,
            order_by: s.inserted_at,
            select: s.step_name
          )
        )

      assert names == [
               "fulfil__shipment__pack",
               "fulfil__shipment__book",
               "fulfil__shipment__destination",
               "fulfil__shipment__destination__abroad__freight"
             ]
    end

    test "the join still finds the lanes by name after the run was stored" do
      run = run_workflow(Fulfil, %{"country" => "LK"})

      # `close` failed once and was run again from the stored data.
      assert [:failed, :completed] = for(%{step_name: "close"} = s <- steps(run), do: s.status)
      assert run.context["summary"] == ["courier", "INV-1", 10]
    end

    test "a lane that fails fails the block" do
      run = run_workflow(Fulfil, %{"country" => "nowhere"})

      assert run.status == :failed
      assert run.error["message"] =~ "no tax rules"
      refute "close" in ran(run)
    end

    test "inside an arm, with into: getting every lane's outcome" do
      run = run_workflow(InArm, %{})

      assert run.status == :completed

      assert %{"email" => ["ok", %{"sent" => "email"}], "sms" => ["error", _]} =
               run.context["got"]
    end
  end

  # A step that fails while `flag` is set, for a run that is fixed and retried.
  defmodule Broken do
    def set(flag), do: :persistent_term.put({__MODULE__, flag}, true)
    def clear(flag), do: :persistent_term.erase({__MODULE__, flag})

    def unless_broken(flag, data) do
      if :persistent_term.get({__MODULE__, flag}, false),
        do: {:fail, "#{flag} is broken"},
        else: {:ok, data}
    end
  end

  # What a step's data holds that Durable put there for itself.
  defmodule Plumbing do
    def in_data(data) do
      for key <- Map.keys(data), String.starts_with?(to_string(key), "__"), do: to_string(key)
    end

    def note(data, step) do
      Map.update(data, :plumbing, %{step => in_data(data)}, &Map.put(&1, step, in_data(data)))
    end
  end

  defmodule Deep do
    use Durable
    use Durable.Helpers

    workflow "deep" do
      parallel :outer do
        lane :a do
          step(:a1, fn data -> {:ok, Plumbing.note(data, "a1")} end)
          step(:a2, fn data -> {:ok, Plumbing.note(data, "a2")} end)

          parallel :inner do
            lane :x do
              step(:x1, fn data -> {:ok, Plumbing.note(data, "x1")} end)

              step(:x2, fn data ->
                with {:ok, data} <- Broken.unless_broken(:deep_x2, data),
                     do: {:ok, data |> Plumbing.note("x2") |> assign(:x2_runs, 1)}
              end)
            end

            step(:y, fn data -> {:ok, Plumbing.note(data, "y")} end)
          end

          step(:a3, fn %{inner: %{x: x, y: _}} = data ->
            {:ok, data |> Plumbing.note("a3") |> assign(:from_x, x["x2_runs"])}
          end)
        end

        lane :b do
          step(:b1, fn data -> {:ok, Plumbing.note(data, "b1")} end)

          step(:b2, fn data ->
            with {:ok, data} <- Broken.unless_broken(:deep_b2, data),
                 do: {:ok, Plumbing.note(data, "b2")}
          end)
        end
      end

      step(:done, fn %{outer: %{a: a, b: _}} = data ->
        {:ok, data |> Plumbing.note("done") |> assign(:from_x, a["from_x"])}
      end)
    end
  end

  defmodule Merges do
    use Durable
    use Durable.Helpers

    workflow "merges" do
      parallel :both,
        into: fn data, results ->
          {:ok, a} = results.a
          {:ok, Map.merge(data, a)}
        end do
        lane :a do
          step(:a1, fn data -> {:ok, assign(data, :a1, true)} end)
          step(:a2, fn data -> {:ok, assign(data, :a2, true)} end)
        end

        step(:b, fn data -> {:ok, data} end)
      end

      step(:after, fn data -> {:ok, assign(data, :after, true)} end)
    end
  end

  defmodule UndoInArm do
    use Durable
    use Durable.Helpers

    workflow "undo_in_arm", on_failure: :rollback do
      branch :kind, fn data -> {:book, data} end do
        :book ->
          step(:reserve, [compensate: :release], fn data -> {:ok, assign(data, :held, true)} end)

        :skip ->
          pass()
      end

      step(:charge, fn _data -> {:fail, "declined"} end)

      compensate(:release, fn data -> {:ok, assign(data, :released, true)} end)
    end
  end

  defp plumbing_seen(context) when is_map(context) do
    own = for {step, keys} <- context["plumbing"] || %{}, keys != [], do: {step, keys}
    own ++ Enum.flat_map(Map.values(context), &plumbing_seen/1)
  end

  defp plumbing_seen(_value), do: []

  defp completed(run, step) do
    for %{step_name: ^step, status: :completed} <- steps(run), do: step
  end

  describe "what a lane keeps to itself" do
    test "no step sees Durable's own keys, and none end up in a lane's result" do
      run = run_workflow(Deep, %{})

      assert run.status == :completed
      assert plumbing_seen(run.context) == []
      assert Plumbing.in_data(run.context["outer"]["a"]) == []
      assert Plumbing.in_data(run.context["outer"]["a"]["inner"]["x"]) == []
    end

    test "a lane's data merged into the run doesn't make the run a lane" do
      run = run_workflow(Merges, %{})

      assert run.status == :completed
      assert %{"a1" => true, "a2" => true, "after" => true} = run.context
      assert Plumbing.in_data(run.context) == []
    end

    test "steps/1 finds the steps of a lane inside a lane" do
      run = run_workflow(Deep, %{})

      assert completed(run, "outer__a__inner__x__x2") == ["outer__a__inner__x__x2"]
    end
  end

  describe "retrying a run that failed in a lane" do
    setup do
      on_exit(fn -> Enum.each([:deep_x2, :deep_b2], &Broken.clear/1) end)
    end

    test "goes on from the step that failed, and repeats nothing" do
      Broken.set(:deep_b2)
      run = run_workflow(Deep, %{})
      assert run.status == :failed
      assert run.error["message"] =~ "deep_b2 is broken"

      Broken.clear(:deep_b2)
      {:ok, _} = Durable.retry(run.id)
      run = drain(run)

      assert run.status == :completed

      for step <- ~w(outer__a__a1 outer__b__b1 outer__b__b2 outer__a__inner__x__x1 done) do
        assert completed(run, step) == [step]
      end
    end

    test "reaches a lane two blocks down" do
      Broken.set(:deep_x2)
      run = run_workflow(Deep, %{})
      assert run.status == :failed
      assert run.error["message"] =~ "deep_x2 is broken"

      Broken.clear(:deep_x2)
      {:ok, _} = Durable.retry(run.id)
      run = drain(run)

      assert run.status == :completed
      assert run.context["from_x"] == 1

      for step <- ~w(outer__a__a1 outer__a__a2 outer__a__inner__x__x1 outer__a__inner__x__x2
                     outer__a__inner__y outer__a__a3 outer__b__b2 done) do
        assert completed(run, step) == [step]
      end
    end
  end

  describe "pruning under a failed run" do
    setup do
      on_exit(fn -> Broken.clear(:deep_b2) end)
    end

    test "keeps the lanes of a lane, so the run can still be retried" do
      Broken.set(:deep_b2)
      run = run_workflow(Deep, %{})
      assert run.status == :failed

      family = fn ->
        Repo.all(from(w in WorkflowExecution, where: w.root_workflow_id == ^run.id, select: w.id))
      end

      before = family.()
      assert length(before) == 4

      Process.sleep(5)
      policy = [completed: 1, cancelled: 1, failed: 60_000]
      Durable.Pruner.prune(%{Durable.Config.get(Durable) | prune: policy})

      assert Enum.sort(family.()) == Enum.sort(before)

      Broken.clear(:deep_b2)
      {:ok, _} = Durable.retry(run.id)
      assert drain(run).status == :completed
    end
  end

  describe "a compensation in an arm" do
    test "runs when a later step fails" do
      run = run_workflow(UndoInArm, %{})

      assert run.status == :compensated

      assert [%{status: :completed, compensation_for: "kind__book__reserve"}] =
               for(%{is_compensation: true} = row <- steps(run), do: row)
    end
  end

  defmodule Counts do
    use Durable

    defp bump(data, key), do: Map.update(data, key, 1, &(&1 + 1))

    workflow "counts" do
      step(:a, fn data -> {:ok, bump(data, "a")} end)

      branch :pick, fn data -> {:left, bump(data, "decided")} end do
        :left -> step(:work, fn data -> {:ok, bump(data, "left")} end)
        :right -> step(:work, fn data -> {:ok, bump(data, "right")} end)
      end

      parallel :both do
        step(:x, fn data -> {:ok, bump(data, "x")} end)
        step(:y, fn data -> {:ok, bump(data, "y")} end)
      end

      step(:z, fn data -> {:ok, bump(data, "z")} end)
    end
  end

  # A run stored as it is when its worker was lost right after `step`'s result
  # was saved: still at that step, with the result as its data.
  defp stopped_after(step, data, done) do
    context =
      data
      |> Map.put("__string_keys__", Map.keys(data))
      |> then(&if(done, do: Map.put(&1, "__done__", done), else: &1))

    {:ok, run} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(%{
        workflow_module: Atom.to_string(Counts),
        workflow_name: "counts",
        status: :pending,
        queue: "default",
        input: %{},
        context: context,
        current_step: step
      })
      |> Repo.insert()

    drain(run)
  end

  defp attempts(run, step), do: for(%{step_name: ^step} = row <- steps(run), do: row.status)

  describe "a run that comes back to a step whose result was already saved" do
    test "goes on from the next step" do
      run = stopped_after("a", %{"a" => 1}, %{"step" => "a"})

      assert run.status == :completed
      assert attempts(run, "a") == []
      assert %{"a" => 1, "decided" => 1, "left" => 1, "z" => 1} = run.context
    end

    test "runs the step when nothing says its result was saved" do
      run = stopped_after("a", %{}, nil)

      assert run.status == :completed
      assert attempts(run, "a") == [:completed]
      assert run.context["a"] == 1
    end

    test "takes the arm a branch already chose, without deciding again" do
      run =
        stopped_after("pick", %{"a" => 1, "decided" => 1}, %{"step" => "pick", "arm" => "left"})

      assert run.status == :completed
      assert attempts(run, "pick") == []
      assert %{"decided" => 1, "left" => 1, "z" => 1} = run.context
      refute Map.has_key?(run.context, "right")
    end

    test "doesn't start a parallel block again" do
      run = stopped_after("both", %{"a" => 1, "both" => %{}}, %{"step" => "both"})

      assert run.status == :completed
      assert Repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^run.id)) == []
      assert attempts(run, "both__x") == []
      assert run.context["z"] == 1
    end

    test "decides again when the arm it chose is no longer in the workflow" do
      run = stopped_after("pick", %{"a" => 1}, %{"step" => "pick", "arm" => "gone"})

      assert run.status == :completed
      assert attempts(run, "pick") == [:completed]
      assert run.context["left"] == 1
    end

    test "a record for another step changes nothing" do
      run = stopped_after("pick", %{"a" => 1}, %{"step" => "a"})

      assert run.status == :completed
      assert attempts(run, "pick") == [:completed]
      assert run.context["decided"] == 1
    end

    test "the record never reaches a step's data or the finished run" do
      run = run_workflow(Counts, %{})

      assert run.status == :completed
      assert Plumbing.in_data(run.context) == []
      assert Plumbing.in_data(run.context["both"]["x"]) == []
    end
  end

  describe "what a decider returns" do
    alias Durable.DSL.Step

    test "an arm of the block becomes the step's jump" do
      assert Step.__arm__({:a, %{n: 1}}, :pick, [:a, :b]) == {:goto, :a, %{n: 1}}
    end

    test "a step's other results pass through untouched" do
      for result <- [
            {:error, "down"},
            {:fail, "no"},
            {:snooze, 5},
            {:snooze, 5, "busy"},
            {:cancel, "stop"},
            {:cancel, "stop", scope: :run}
          ] do
        assert Step.__arm__(result, :pick, [:a, :b]) == result
      end
    end

    test "anything else fails without retries, saying what came back" do
      for result <- [{:c, %{}}, {:a, "not a map"}, {:ok, %{}}, {"a", %{}}, :a, nil, {:a, %{}, 1}] do
        assert {:fail, %{type: "branch_error", message: message}} =
                 Step.__arm__(result, :pick, [:a, :b])

        assert message =~ "[:a, :b]"
        assert message =~ inspect(result)
      end
    end

    test "a huge result is cut short in the error" do
      big = %{blob: String.duplicate("x", 100_000)}
      {:fail, %{message: message}} = Step.__arm__({:nowhere, big}, :pick, [:a])

      assert byte_size(message) < 1_000
    end
  end

  describe "what doesn't compile" do
    defp compile_error(body) do
      assert_raise CompileError, fn ->
        Code.compile_string("""
        defmodule Durable.NamedBlocksTest.Bad#{System.unique_integer([:positive])} do
          use Durable

          workflow "w", on_failure: :rollback do
            #{body}
          end
        end
        """)
      end
    end

    test "an arm named like a step result" do
      error = compile_error("branch :b, fn d -> {:ok, d} end do\n :ok -> pass()\n end")
      assert error.description =~ "can't have an arm called :ok"
    end

    test "a named branch given on: in place of a function" do
      error = compile_error("branch :b, on: fn d -> d end do\n :a -> pass()\n end")
      assert error.description =~ "takes a function that returns {arm, data}"
    end

    test "an arm written twice, and a lane written twice" do
      error =
        compile_error("branch :b, fn d -> {:a, d} end do\n :a -> pass()\n :a -> pass()\n end")

      assert error.description =~ "an arm written twice"

      error =
        compile_error("""
        parallel :p do
          lane :a do
            step :x, fn d -> {:ok, d} end
          end

          step :a, fn d -> {:ok, d} end
        end
        """)

      assert error.description =~ "a lane written twice"
    end

    test "a decision in a lane" do
      error =
        compile_error("""
        parallel :p do
          lane :a do
            decision :d, fn d -> {:ok, d} end
          end
        end
        """)

      assert error.description =~ "a lane can hold"
      assert error.description =~ "decision(:d"
    end

    test "two blocks, or a block and a step, with one name" do
      error =
        compile_error("""
        step :p, fn d -> {:ok, d} end

        parallel :p do
          step :x, fn d -> {:ok, d} end
        end
        """)

      assert error.description =~ "defined twice"
    end

    test "an arm that isn't an atom" do
      error = compile_error("branch :b, fn d -> {:a, d} end do\n \"a\" -> pass()\n end")
      assert error.description =~ "named by an atom"
    end

    test "an unnamed block inside an arm" do
      error =
        compile_error("""
        branch :b, fn d -> {:a, d} end do
          :a ->
            parallel do
              step :x, fn d -> {:ok, d} end
            end
        end
        """)

      assert error.description =~ "a named `parallel`"
    end

    test "a compensation in a lane" do
      error =
        compile_error("""
        parallel :p do
          lane :a do
            step :x, [compensate: :undo], fn d -> {:ok, d} end
          end
        end
        """)

      assert error.description =~ "compensate:"
    end

    test "on_error: :complete_all, which is now :collect" do
      error =
        compile_error("""
        parallel :p, on_error: :complete_all do
          step :x, fn d -> {:ok, d} end
        end
        """)

      assert error.description =~ ":collect"
    end
  end
end
