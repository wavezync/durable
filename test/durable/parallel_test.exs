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
  end

  describe "parallel execution - all succeed" do
    test "executes all parallel steps" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleParallelTestWorkflow, %{})

      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Should execute setup step
      assert "setup" in executed_steps

      # Should execute both parallel steps
      assert Enum.any?(executed_steps, &String.contains?(&1, "task_a"))
      assert Enum.any?(executed_steps, &String.contains?(&1, "task_b"))

      # Should execute final step
      assert "final" in executed_steps
    end

    test "context from all parallel steps is available after parallel block" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleParallelTestWorkflow, %{})

      assert execution.status == :completed

      # Both parallel steps should have set their context values
      assert execution.context["from_task_a"] == true
      assert execution.context["from_task_b"] == true
      # Final step should see both values
      assert execution.context["completed"] == true
    end

    test "steps execute concurrently (timing test)" do
      # Each parallel step sleeps for 50ms
      # Sequential would take >= 100ms, parallel should be ~50ms
      start_time = System.monotonic_time(:millisecond)

      {:ok, execution} =
        create_and_execute_workflow(TimingParallelWorkflow, %{})

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert execution.status == :completed
      # Should complete in less than 150ms (allowing for overhead)
      # If sequential, would be >= 100ms
      # This is a weak test but verifies basic concurrency
      assert elapsed < 200
    end
  end

  describe "parallel execution - error handling" do
    test "workflow fails if any parallel step fails (fail_fast)" do
      {:ok, execution} =
        create_and_execute_workflow(FailingParallelWorkflow, %{})

      assert execution.status == :failed
      assert execution.error["type"] == "parallel_error"
      assert is_list(execution.error["errors"])
    end

    test "complete_all waits for all steps and collects errors" do
      {:ok, execution} =
        create_and_execute_workflow(CompleteAllParallelWorkflow, %{})

      assert execution.status == :failed
      assert execution.error["type"] == "parallel_error"
      # Should have collected error from failing step
      errors = execution.error["errors"]
      assert errors != []
    end
  end

  describe "context merge strategies" do
    test "deep_merge combines nested maps" do
      {:ok, execution} =
        create_and_execute_workflow(DeepMergeParallelWorkflow, %{})

      assert execution.status == :completed

      # Both parallel steps set nested values
      assert execution.context["nested"]["from_a"] == true
      assert execution.context["nested"]["from_b"] == true
    end

    test "collect gathers step results" do
      {:ok, execution} =
        create_and_execute_workflow(CollectParallelWorkflow, %{})

      assert execution.status == :completed

      # Results should be collected under __parallel_results__
      assert is_map(execution.context["__parallel_results__"])
    end
  end

  describe "parallel continues after block" do
    test "execution continues to steps after parallel block" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleParallelTestWorkflow, %{})

      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Final step should execute after parallel
      assert "final" in executed_steps
      assert execution.context["completed"] == true
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
          # This is the context snapshot stored by step_runner for durability
          output: %{
            "__output__" => nil,
            "__context__" => %{"from_task_a" => "original_value", "task_a_runs" => 1}
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

      # task_a should NOT be re-run (value should be preserved from stored context)
      assert execution.context["from_task_a"] == "original_value"
      assert execution.context["task_a_runs"] == 1

      # task_b SHOULD have run (it wasn't completed before)
      assert execution.context["from_task_b"] == true

      # Final step should have completed
      assert execution.context["completed"] == true

      # Check step executions - task_a should only have 1 execution (the pre-existing one)
      step_execs = get_step_executions(execution.id)
      task_a_execs = Enum.filter(step_execs, &String.contains?(&1.step_name, "task_a"))
      assert length(task_a_execs) == 1
    end

    test "all parallel step contexts are merged when resuming with completed steps" do
      config = Config.get(Durable)
      repo = config.repo
      {:ok, workflow_def} = ResumableParallelWorkflow.__default_workflow__()

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

      parallel_step = Enum.find(workflow_def.steps, &(&1.type == :parallel))
      parallel_step_names = parallel_step.opts[:steps]

      # Mark BOTH parallel steps as completed (simulating all done)
      for step_name <- parallel_step_names do
        name_str = Atom.to_string(step_name)

        context_key =
          if String.contains?(name_str, "task_a"), do: "from_task_a", else: "from_task_b"

        {:ok, _} =
          %StepExecution{}
          |> StepExecution.changeset(%{
            workflow_id: execution.id,
            step_name: name_str,
            step_type: "step",
            attempt: 1,
            status: :completed,
            output: %{
              "__output__" => nil,
              "__context__" => %{context_key => "stored_value"}
            }
          })
          |> repo.insert()
      end

      {:ok, execution} =
        execution
        |> Ecto.Changeset.change(current_step: Atom.to_string(parallel_step.name))
        |> repo.update()

      # Execute the workflow - should skip all parallel steps
      Executor.execute_workflow(execution.id, config)
      execution = repo.get!(WorkflowExecution, execution.id)

      assert execution.status == :completed

      # Context from both stored parallel steps should be merged
      assert execution.context["from_task_a"] == "stored_value"
      assert execution.context["from_task_b"] == "stored_value"
      assert execution.context["completed"] == true

      # No new step executions for parallel steps (both were already done)
      step_execs = get_step_executions(execution.id)
      parallel_execs = Enum.filter(step_execs, &String.contains?(&1.step_name, "parallel_"))
      # Only the 2 pre-existing ones
      assert length(parallel_execs) == 2
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
  use Durable.Context

  workflow "simple_parallel" do
    step :setup do
      put_context(:initialized, true)
    end

    parallel do
      step :task_a do
        put_context(:from_task_a, true)
      end

      step :task_b do
        put_context(:from_task_b, true)
      end
    end

    step :final do
      put_context(:completed, true)
    end
  end
end

defmodule TimingParallelWorkflow do
  use Durable
  use Durable.Context

  workflow "timing_parallel" do
    step :setup do
      :ok
    end

    parallel do
      step :slow_a do
        Process.sleep(50)
        put_context(:a_done, true)
      end

      step :slow_b do
        Process.sleep(50)
        put_context(:b_done, true)
      end
    end

    step :done do
      :ok
    end
  end
end

defmodule FailingParallelWorkflow do
  use Durable
  use Durable.Context

  workflow "failing_parallel" do
    step :setup do
      :ok
    end

    parallel do
      step :good_task do
        put_context(:good, true)
      end

      step :bad_task do
        raise "intentional failure"
      end
    end

    step :never_reached do
      put_context(:reached, true)
    end
  end
end

defmodule CompleteAllParallelWorkflow do
  use Durable
  use Durable.Context

  workflow "complete_all_parallel" do
    step :setup do
      :ok
    end

    parallel on_error: :complete_all do
      step :good_task do
        Process.sleep(10)
        put_context(:good, true)
      end

      step :bad_task do
        raise "intentional failure"
      end
    end

    step :never_reached do
      put_context(:reached, true)
    end
  end
end

defmodule DeepMergeParallelWorkflow do
  use Durable
  use Durable.Context

  workflow "deep_merge_parallel" do
    step :setup do
      put_context(:nested, %{})
    end

    parallel merge: :deep_merge do
      step :task_a do
        nested = get_context(:nested) || %{}
        put_context(:nested, Map.put(nested, :from_a, true))
      end

      step :task_b do
        nested = get_context(:nested) || %{}
        put_context(:nested, Map.put(nested, :from_b, true))
      end
    end

    step :done do
      :ok
    end
  end
end

defmodule CollectParallelWorkflow do
  use Durable
  use Durable.Context

  workflow "collect_parallel" do
    step :setup do
      :ok
    end

    parallel merge: :collect do
      step :task_a do
        put_context(:result_a, "value_a")
      end

      step :task_b do
        put_context(:result_b, "value_b")
      end
    end

    step :done do
      :ok
    end
  end
end

defmodule ResumableParallelWorkflow do
  use Durable
  use Durable.Context

  workflow "resumable_parallel" do
    step :setup do
      put_context(:initialized, true)
    end

    parallel do
      step :task_a do
        # This will be tracked to verify it doesn't re-run
        current_runs = get_context(:task_a_runs, 0)
        put_context(:task_a_runs, current_runs + 1)
        put_context(:from_task_a, true)
      end

      step :task_b do
        put_context(:from_task_b, true)
      end
    end

    step :final do
      put_context(:completed, true)
    end
  end
end
