defmodule Durable.ParallelTest do
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  import Ecto.Query

  describe "parallel macro DSL compilation" do
    test "parallel macro creates step with type :parallel" do
      {:ok, definition} =
        SimpleParallelTestWorkflow.__workflow_definition__("simple_parallel")

      parallel_step = Enum.find(definition.steps, &(&1.type == :parallel))

      assert parallel_step != nil
      assert parallel_step.type == :parallel
      assert parallel_step.opts[:steps] != nil
      assert is_list(parallel_step.opts[:steps])
    end

    test "parallel creates qualified step names for nested steps" do
      {:ok, definition} =
        SimpleParallelTestWorkflow.__workflow_definition__("simple_parallel")

      step_names = Enum.map(definition.steps, & &1.name) |> Enum.map(&Atom.to_string/1)

      # Should have qualified names like parallel_<id>__<step>
      assert Enum.any?(step_names, &String.contains?(&1, "parallel_"))
      assert Enum.any?(step_names, &String.contains?(&1, "__task_a"))
      assert Enum.any?(step_names, &String.contains?(&1, "__task_b"))
    end

    test "parallel includes all nested step definitions in workflow" do
      {:ok, definition} =
        SimpleParallelTestWorkflow.__workflow_definition__("simple_parallel")

      # Should have: setup, parallel_X, parallel steps (task_a, task_b), final
      assert length(definition.steps) >= 4
    end

    test "parallel step opts include returns key" do
      {:ok, definition} =
        SimpleParallelTestWorkflow.__workflow_definition__("simple_parallel")

      # Find a parallel step
      parallel_step =
        Enum.find(definition.steps, fn step ->
          String.contains?(Atom.to_string(step.name), "__task_a")
        end)

      assert parallel_step.opts[:returns] == :task_a
    end
  end

  describe "parallel execution - results model" do
    test "parallel steps produce results in __results__ map" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleParallelTestWorkflow, %{})

      assert execution.status == :completed

      # Results should be in __results__ map with tagged tuples
      results = execution.context["__results__"]
      assert is_map(results)
      assert results["task_a"] == ["ok", %{"from_task_a" => true, "initialized" => true}]
      assert results["task_b"] == ["ok", %{"from_task_b" => true, "initialized" => true}]
    end

    test "next step can access __results__ from context" do
      {:ok, execution} =
        create_and_execute_workflow(ResultsAccessWorkflow, %{})

      assert execution.status == :completed

      # The final step should have processed the results
      assert execution.context["processed_task_a"] == true
      assert execution.context["processed_task_b"] == true
    end

    test "error results are preserved as {:error, reason} in results map" do
      {:ok, execution} =
        create_and_execute_workflow(ErrorPreservingParallelWorkflow, %{})

      assert execution.status == :completed

      # Check that error is preserved in results
      results = execution.context["__results__"]
      assert results["good_task"] == ["ok", %{"good" => true}]
      assert match?(["error", _], results["bad_task"])
    end
  end

  describe "parallel execution - into: callback" do
    test "into: callback transforms results and returns {:ok, ctx}" do
      {:ok, execution} =
        create_and_execute_workflow(IntoOkWorkflow, %{})

      assert execution.status == :completed

      # The into callback should have transformed the results
      assert execution.context["payment_id"] == 123
      assert execution.context["delivery_status"] == "confirmed"
      # __results__ should NOT be in context when into: is used
      refute Map.has_key?(execution.context, "__results__")
    end

    test "into: callback returning {:error, reason} fails workflow" do
      {:ok, execution} =
        create_and_execute_workflow(IntoErrorWorkflow, %{})

      assert execution.status == :failed
      assert execution.error["message"] == "Payment and delivery both failed"
    end

    test "into: callback returning {:goto, step, ctx} jumps to step" do
      {:ok, execution} =
        create_and_execute_workflow(IntoGotoWorkflow, %{})

      assert execution.status == :completed

      # Should have skipped to handle_backorder step
      assert execution.context["backorder_handled"] == true
      # Should NOT have executed the normal_flow step
      refute Map.has_key?(execution.context, "normal_flow_executed")
    end
  end

  describe "parallel execution - returns: option" do
    test "returns: option changes result key name" do
      {:ok, execution} =
        create_and_execute_workflow(ReturnsKeyWorkflow, %{})

      assert execution.status == :completed

      results = execution.context["__results__"]
      # Should use custom key names from returns:
      assert Map.has_key?(results, "order_data")
      assert Map.has_key?(results, "user_data")
      # Should NOT have the original step names
      refute Map.has_key?(results, "fetch_order")
      refute Map.has_key?(results, "fetch_user")
    end
  end

  describe "parallel execution - error handling" do
    test "fail_fast stops on first error by default" do
      {:ok, execution} =
        create_and_execute_workflow(FailFastParallelWorkflow, %{})

      assert execution.status == :failed
      # Error should be from the failing step
      assert execution.error["type"] == "test_error"
    end

    test "complete_all collects all results including errors" do
      {:ok, execution} =
        create_and_execute_workflow(CompleteAllWithResultsWorkflow, %{})

      assert execution.status == :completed

      # All results should be collected, including errors
      results = execution.context["__results__"]
      assert results["good_task"] == ["ok", %{"good" => true}]
      assert match?(["error", _], results["bad_task"])
    end
  end

  describe "parallel execution - concurrency" do
    test "steps execute concurrently" do
      {:ok, execution} =
        create_and_execute_workflow(TimingParallelWorkflow, %{})

      assert execution.status == :completed

      # Both steps should complete
      results = execution.context["__results__"]
      assert match?(["ok", _], results["slow_a"])
      assert match?(["ok", _], results["slow_b"])
    end

    test "10+ parallel steps execute successfully" do
      {:ok, execution} =
        create_and_execute_workflow(ManyParallelStepsWorkflow, %{})

      assert execution.status == :completed

      results = execution.context["__results__"]
      # All 15 steps should have results
      for i <- 1..15 do
        key = "step_#{i}"
        assert Map.has_key?(results, key), "Missing result for #{key}"
      end
    end
  end

  describe "parallel with single step" do
    test "parallel block with single step works correctly" do
      {:ok, execution} =
        create_and_execute_workflow(SingleStepParallelWorkflow, %{})

      assert execution.status == :completed

      results = execution.context["__results__"]
      assert results["only_task"] == ["ok", %{"from_only_task" => true, "initialized" => true}]
    end
  end

  describe "parallel resume behavior (durability)" do
    test "completed parallel steps are not re-executed on resume" do
      config = Config.get(Durable)
      repo = config.repo
      {:ok, workflow_def} = ResumableParallelWorkflow.__default_workflow__()

      # Create workflow execution manually
      attrs = %{
        workflow_module: Atom.to_string(ResumableParallelWorkflow),
        workflow_name: workflow_def.name,
        status: :pending,
        queue: "default",
        priority: 0,
        input: %{},
        context: %{"initialized" => true}
      }

      {:ok, execution} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(attrs)
        |> repo.insert()

      # Find the parallel step to get its name
      parallel_step = Enum.find(workflow_def.steps, &(&1.type == :parallel))
      parallel_step_names = parallel_step.opts[:steps]

      # Manually create a completed step execution for one of the parallel steps
      # This simulates a partial execution (task_a completed, task_b did not)
      task_a_name =
        Enum.find(parallel_step_names, &(Atom.to_string(&1) |> String.contains?("task_a")))

      {:ok, _step_exec} =
        %StepExecution{}
        |> StepExecution.changeset(%{
          workflow_id: execution.id,
          step_name: Atom.to_string(task_a_name),
          step_type: "step",
          attempt: 1,
          status: :completed,
          # Store result for durability
          output: %{
            "__output__" => nil,
            "__context__" => %{"from_task_a" => "original_value", "task_a_runs" => 1},
            "__result__" => %{"from_task_a" => "original_value", "task_a_runs" => 1}
          }
        })
        |> repo.insert()

      # Set current_step to the parallel step (simulating a resume point)
      {:ok, execution} =
        execution
        |> Ecto.Changeset.change(current_step: Atom.to_string(parallel_step.name))
        |> repo.update()

      # Now execute/resume the workflow
      Executor.execute_workflow(execution.id, config)
      execution = repo.get!(WorkflowExecution, execution.id)

      assert execution.status == :completed

      # Check results - task_a should have stored result, task_b should have new result
      results = execution.context["__results__"]
      assert match?(["ok", %{"from_task_a" => "original_value"}], results["task_a"])
      assert match?(["ok", %{"from_task_b" => true}], results["task_b"])

      # Check step executions - task_a should only have 1 execution (the pre-existing one)
      step_execs = get_step_executions(execution.id)
      task_a_execs = Enum.filter(step_execs, &String.contains?(&1.step_name, "task_a"))
      assert length(task_a_execs) == 1
    end
  end

  # Helper functions
  defp create_and_execute_workflow(module, input) do
    config = Config.get(Durable)
    repo = config.repo
    {:ok, workflow_def} = module.__default_workflow__()

    attrs = %{
      workflow_module: Atom.to_string(module),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: "default",
      priority: 0,
      input: input,
      context: %{}
    }

    {:ok, execution} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(attrs)
      |> repo.insert()

    Executor.execute_workflow(execution.id, config)
    {:ok, repo.get!(WorkflowExecution, execution.id)}
  end

  defp get_step_executions(workflow_id) do
    config = Config.get(Durable)
    repo = config.repo

    repo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id,
        order_by: [asc: s.inserted_at]
      )
    )
  end
end

# Test workflow modules

defmodule SimpleParallelTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "simple_parallel" do
    step(:setup, fn data ->
      {:ok, assign(data, :initialized, true)}
    end)

    parallel do
      step(:task_a, fn data ->
        {:ok, assign(data, :from_task_a, true)}
      end)

      step(:task_b, fn data ->
        {:ok, assign(data, :from_task_b, true)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule ResultsAccessWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Context

  workflow "results_access" do
    step(:setup, fn data ->
      {:ok, assign(data, :initialized, true)}
    end)

    parallel do
      step(:task_a, fn data ->
        {:ok, assign(data, :value_a, 42)}
      end)

      step(:task_b, fn data ->
        {:ok, assign(data, :value_b, 99)}
      end)
    end

    step(:process_results, fn data ->
      # Results are serialized with string keys and list format: ["ok", data] or ["error", reason]
      results = data[:__results__] || %{}

      data =
        case results["task_a"] do
          ["ok", _] -> assign(data, :processed_task_a, true)
          _ -> data
        end

      data =
        case results["task_b"] do
          ["ok", _] -> assign(data, :processed_task_b, true)
          _ -> data
        end

      {:ok, data}
    end)
  end
end

defmodule ErrorPreservingParallelWorkflow do
  use Durable
  use Durable.Helpers

  workflow "error_preserving_parallel" do
    step(:setup, fn data ->
      {:ok, data}
    end)

    parallel on_error: :complete_all do
      step(:good_task, fn data ->
        {:ok, assign(data, :good, true)}
      end)

      step(:bad_task, fn _data ->
        {:error, %{type: "test_error", message: "intentional failure"}}
      end)
    end

    step(:final, fn data ->
      {:ok, data}
    end)
  end
end

defmodule IntoOkWorkflow do
  use Durable
  use Durable.Helpers

  workflow "into_ok" do
    step(:setup, fn data ->
      {:ok, assign(data, :initialized, true)}
    end)

    parallel into: fn ctx, results ->
               case {results[:payment], results[:delivery]} do
                 {{:ok, payment}, {:ok, delivery}} ->
                   new_ctx =
                     ctx
                     |> Map.put(:payment_id, payment.id)
                     |> Map.put(:delivery_status, delivery.status)

                   {:ok, new_ctx}

                 _ ->
                   {:error, "Unexpected result combination"}
               end
             end do
      step(:payment, fn _data ->
        {:ok, %{id: 123, status: "paid"}}
      end)

      step(:delivery, fn _data ->
        {:ok, %{id: 456, status: "confirmed"}}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule IntoErrorWorkflow do
  use Durable
  use Durable.Helpers

  workflow "into_error" do
    step(:setup, fn data ->
      {:ok, assign(data, :initialized, true)}
    end)

    parallel into: fn _ctx, results ->
               case {results[:payment], results[:delivery]} do
                 {{:ok, _}, {:ok, _}} ->
                   {:error, "Both succeeded but we expected failure"}

                 _ ->
                   {:error, "Payment and delivery both failed"}
               end
             end do
      step(:payment, fn _data ->
        {:error, "Payment failed"}
      end)

      step(:delivery, fn _data ->
        {:error, "Delivery failed"}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule IntoGotoWorkflow do
  use Durable
  use Durable.Helpers

  workflow "into_goto" do
    step(:setup, fn data ->
      {:ok, assign(data, :initialized, true)}
    end)

    parallel into: fn ctx, results ->
               case results[:delivery] do
                 {:error, _} ->
                   {:goto, :handle_backorder, ctx}

                 {:ok, _} ->
                   {:ok, ctx}
               end
             end do
      step(:payment, fn _data ->
        {:ok, %{id: 123}}
      end)

      step(:delivery, fn _data ->
        {:error, :not_found}
      end)
    end

    step(:normal_flow, fn data ->
      {:ok, assign(data, :normal_flow_executed, true)}
    end)

    step(:handle_backorder, fn data ->
      {:ok, assign(data, :backorder_handled, true)}
    end)

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule ReturnsKeyWorkflow do
  use Durable
  use Durable.Helpers

  workflow "returns_key" do
    step(:setup, fn data ->
      {:ok, assign(data, :initialized, true)}
    end)

    parallel do
      step(:fetch_order, [returns: :order_data], fn _data ->
        {:ok, %{items: ["item1", "item2"]}}
      end)

      step(:fetch_user, [returns: :user_data], fn _data ->
        {:ok, %{name: "John", email: "john@example.com"}}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule FailFastParallelWorkflow do
  use Durable
  use Durable.Helpers

  workflow "fail_fast_parallel" do
    step(:setup, fn data ->
      {:ok, data}
    end)

    parallel on_error: :fail_fast do
      step(:good_task, fn data ->
        Process.sleep(50)
        {:ok, assign(data, :good, true)}
      end)

      step(:bad_task, fn _data ->
        {:error, %{type: "test_error", message: "intentional failure"}}
      end)
    end

    step(:never_reached, fn data ->
      {:ok, assign(data, :reached, true)}
    end)
  end
end

defmodule CompleteAllWithResultsWorkflow do
  use Durable
  use Durable.Helpers

  workflow "complete_all_with_results" do
    step(:setup, fn data ->
      {:ok, data}
    end)

    parallel on_error: :complete_all do
      step(:good_task, fn data ->
        {:ok, assign(data, :good, true)}
      end)

      step(:bad_task, fn _data ->
        {:error, %{type: "test_error", message: "intentional failure"}}
      end)
    end

    step(:final, fn data ->
      {:ok, data}
    end)
  end
end

defmodule TimingParallelWorkflow do
  use Durable
  use Durable.Helpers

  workflow "timing_parallel" do
    step(:setup, fn data ->
      {:ok, data}
    end)

    parallel do
      step(:slow_a, fn data ->
        Process.sleep(50)
        {:ok, assign(data, :a_done, true)}
      end)

      step(:slow_b, fn data ->
        Process.sleep(50)
        {:ok, assign(data, :b_done, true)}
      end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

defmodule SingleStepParallelWorkflow do
  use Durable
  use Durable.Helpers

  workflow "single_step_parallel" do
    step(:setup, fn data ->
      {:ok, assign(data, :initialized, true)}
    end)

    parallel do
      step(:only_task, fn data ->
        {:ok, assign(data, :from_only_task, true)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule ManyParallelStepsWorkflow do
  use Durable
  use Durable.Helpers

  workflow "many_parallel_steps" do
    step(:setup, fn data ->
      {:ok, assign(data, :initialized, true)}
    end)

    parallel do
      step(:step_1, fn data -> {:ok, assign(data, :step_1, true)} end)
      step(:step_2, fn data -> {:ok, assign(data, :step_2, true)} end)
      step(:step_3, fn data -> {:ok, assign(data, :step_3, true)} end)
      step(:step_4, fn data -> {:ok, assign(data, :step_4, true)} end)
      step(:step_5, fn data -> {:ok, assign(data, :step_5, true)} end)
      step(:step_6, fn data -> {:ok, assign(data, :step_6, true)} end)
      step(:step_7, fn data -> {:ok, assign(data, :step_7, true)} end)
      step(:step_8, fn data -> {:ok, assign(data, :step_8, true)} end)
      step(:step_9, fn data -> {:ok, assign(data, :step_9, true)} end)
      step(:step_10, fn data -> {:ok, assign(data, :step_10, true)} end)
      step(:step_11, fn data -> {:ok, assign(data, :step_11, true)} end)
      step(:step_12, fn data -> {:ok, assign(data, :step_12, true)} end)
      step(:step_13, fn data -> {:ok, assign(data, :step_13, true)} end)
      step(:step_14, fn data -> {:ok, assign(data, :step_14, true)} end)
      step(:step_15, fn data -> {:ok, assign(data, :step_15, true)} end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule ResumableParallelWorkflow do
  use Durable
  use Durable.Helpers

  workflow "resumable_parallel" do
    step(:setup, fn data ->
      {:ok, assign(data, :initialized, true)}
    end)

    parallel do
      step(:task_a, fn data ->
        # This will be tracked to verify it doesn't re-run
        current_runs = data[:task_a_runs] || 0
        data = assign(data, :task_a_runs, current_runs + 1)
        {:ok, assign(data, :from_task_a, true)}
      end)

      step(:task_b, fn data ->
        {:ok, assign(data, :from_task_b, true)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end
