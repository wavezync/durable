defmodule Durable.ParallelTest do
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{PendingEvent, WaitGroup, WorkflowExecution}

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

  describe "parallel execution - durable fan-out" do
    test "parent goes to :waiting and creates child executions" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(SimpleParallelTestWorkflow, %{})

      # Parent should be waiting (not completed)
      assert parent.status == :waiting

      # Should have created child executions
      children = get_child_executions(repo, parent.id)
      assert length(children) == 2
      assert Enum.all?(children, &(&1.status == :pending))

      # Each child should have __parallel_step in context
      Enum.each(children, fn child ->
        assert child.context["__parallel_step"] != nil
        assert child.parent_workflow_id == parent.id
      end)

      # Parent should have parallel metadata
      assert parent.context["__parallel_children"] != nil
      assert parent.context["__parallel_wait_group_id"] != nil
    end

    test "executing children and resuming parent produces completed workflow" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(SimpleParallelTestWorkflow, %{})
      assert parent.status == :waiting

      # Execute all children
      execute_children(repo, parent.id, config)

      # Parent should be resumed (status: :pending after all children done)
      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :pending

      # Execute parent to continue
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :completed

      # Results should be in __results__ map
      results = parent.context["__results__"]
      assert is_map(results)
      assert ["ok", %{"from_task_a" => true, "initialized" => true}] = results["task_a"]
      assert ["ok", %{"from_task_b" => true, "initialized" => true}] = results["task_b"]
    end

    test "WaitGroup and PendingEvents are created for parallel children" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(SimpleParallelTestWorkflow, %{})

      # Should have a WaitGroup
      wait_groups = repo.all(from(w in WaitGroup, where: w.workflow_id == ^parent.id))
      assert length(wait_groups) == 1
      assert hd(wait_groups).wait_type == :all
      assert length(hd(wait_groups).event_names) == 2

      # Should have PendingEvents
      events = repo.all(from(p in PendingEvent, where: p.workflow_id == ^parent.id))
      assert length(events) == 2
      assert Enum.all?(events, &(&1.status == :pending))
    end
  end

  describe "parallel execution - results model" do
    test "next step can access __results__ from context" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(ResultsAccessWorkflow, %{})
      execute_children(repo, parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :completed
      assert parent.context["processed_task_a"] == true
      assert parent.context["processed_task_b"] == true
    end

    test "error results are preserved in results map" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(ErrorPreservingParallelWorkflow, %{})
      execute_children(repo, parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :completed

      results = parent.context["__results__"]
      assert results["good_task"] == ["ok", %{"good" => true}]
      assert match?(["error", _], results["bad_task"])
    end
  end

  describe "parallel execution - into: callback" do
    test "into: callback transforms results and returns {:ok, ctx}" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(IntoOkWorkflow, %{})
      execute_children(repo, parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :completed
      assert parent.context["payment_id"] == 123
      assert parent.context["delivery_status"] == "confirmed"
      refute Map.has_key?(parent.context, "__results__")
    end

    test "into: callback returning {:error, reason} fails workflow" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(IntoErrorWorkflow, %{})
      execute_children(repo, parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :failed
      assert parent.error["message"] == "Payment and delivery both failed"
    end

    test "into: callback returning {:goto, step, ctx} jumps to step" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(IntoGotoWorkflow, %{})
      execute_children(repo, parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :completed
      assert parent.context["backorder_handled"] == true
      refute Map.has_key?(parent.context, "normal_flow_executed")
    end
  end

  describe "parallel execution - returns: option" do
    test "returns: option changes result key name" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(ReturnsKeyWorkflow, %{})
      execute_children(repo, parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :completed

      results = parent.context["__results__"]
      assert Map.has_key?(results, "order_data")
      assert Map.has_key?(results, "user_data")
      refute Map.has_key?(results, "fetch_order")
      refute Map.has_key?(results, "fetch_user")
    end
  end

  describe "parallel execution - error handling" do
    test "fail_fast stops on first error by default" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(FailFastParallelWorkflow, %{})
      execute_children(repo, parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :failed
      assert parent.error["type"] == "test_error"
    end

    test "complete_all collects all results including errors" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(CompleteAllWithResultsWorkflow, %{})
      execute_children(repo, parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :completed

      results = parent.context["__results__"]
      assert results["good_task"] == ["ok", %{"good" => true}]
      assert match?(["error", _], results["bad_task"])
    end
  end

  describe "parallel execution - distributed" do
    test "children can be executed on separate workers" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(SimpleParallelTestWorkflow, %{})
      assert parent.status == :waiting

      children = get_child_executions(repo, parent.id)

      # Execute children one at a time (simulating different workers)
      Enum.each(children, fn child ->
        Executor.execute_workflow(child.id, config)
        child = repo.get!(WorkflowExecution, child.id)
        assert child.status == :completed
      end)

      # Parent should be resumed
      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :pending

      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :completed
    end

    test "children can target different queues" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(QueueRoutingWorkflow, %{})
      assert parent.status == :waiting

      children =
        repo.all(
          from(w in WorkflowExecution,
            where: w.parent_workflow_id == ^parent.id,
            order_by: [asc: :inserted_at]
          )
        )

      queues = Enum.map(children, & &1.queue) |> Enum.sort()
      assert "default" in queues
      assert "gpu" in queues
    end
  end

  describe "parallel with single step" do
    test "parallel block with single step works correctly" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(SingleStepParallelWorkflow, %{})
      execute_children(repo, parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :completed

      results = parent.context["__results__"]
      assert results["only_task"] == ["ok", %{"from_only_task" => true, "initialized" => true}]
    end
  end

  describe "parallel with many steps" do
    test "10+ parallel steps execute successfully" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(ManyParallelStepsWorkflow, %{})
      execute_children(repo, parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      Executor.execute_workflow(parent.id, config)
      parent = repo.get!(WorkflowExecution, parent.id)

      assert parent.status == :completed

      results = parent.context["__results__"]

      for i <- 1..15 do
        key = "step_#{i}"
        assert Map.has_key?(results, key), "Missing result for #{key}"
      end
    end
  end

  describe "parallel cascade cancellation" do
    test "cancelling parent cancels pending parallel children" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(SimpleParallelTestWorkflow, %{})
      assert parent.status == :waiting

      children = get_child_executions(repo, parent.id)
      assert length(children) == 2
      assert Enum.all?(children, &(&1.status == :pending))

      # Cancel parent
      :ok = Executor.cancel_workflow(parent.id, "test_cancel")

      # Children should be cancelled
      children = get_child_executions(repo, parent.id)
      assert Enum.all?(children, &(&1.status == :cancelled))
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

  defp get_child_executions(repo, parent_id) do
    repo.all(
      from(w in WorkflowExecution,
        where: w.parent_workflow_id == ^parent_id,
        order_by: [asc: :inserted_at]
      )
    )
  end

  defp execute_children(repo, parent_id, config) do
    children = get_child_executions(repo, parent_id)

    Enum.each(children, fn child ->
      Executor.execute_workflow(child.id, config)
    end)
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
                     |> Map.put(:payment_id, payment["id"])
                     |> Map.put(:delivery_status, delivery["status"])

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

defmodule QueueRoutingWorkflow do
  use Durable
  use Durable.Helpers

  workflow "queue_routing" do
    step(:setup, fn data ->
      {:ok, assign(data, :initialized, true)}
    end)

    parallel do
      step(:gpu_task, [queue: "gpu"], fn data ->
        {:ok, assign(data, :gpu_done, true)}
      end)

      step(:default_task, fn data ->
        {:ok, assign(data, :default_done, true)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end
