defmodule Durable.ForEachTest do
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  import Ecto.Query

  describe "foreach macro DSL compilation" do
    test "foreach macro creates step with type :foreach" do
      {:ok, definition} =
        SimpleForEachWorkflow.__workflow_definition__("simple_foreach")

      foreach_step = Enum.find(definition.steps, &(&1.type == :foreach))

      assert foreach_step != nil
      assert foreach_step.type == :foreach
      assert foreach_step.opts[:steps] != nil
      assert is_list(foreach_step.opts[:steps])
    end

    test "foreach creates qualified step names for nested steps" do
      {:ok, definition} =
        SimpleForEachWorkflow.__workflow_definition__("simple_foreach")

      step_names = Enum.map(definition.steps, & &1.name) |> Enum.map(&Atom.to_string/1)

      # Should have qualified names like foreach_<name>__<step>
      assert Enum.any?(step_names, &String.contains?(&1, "foreach_"))
      assert Enum.any?(step_names, &String.contains?(&1, "__process"))
    end

    test "foreach includes all nested step definitions in workflow" do
      {:ok, definition} =
        SimpleForEachWorkflow.__workflow_definition__("simple_foreach")

      # Should have: setup, foreach_X, foreach step, final
      assert length(definition.steps) >= 3
    end
  end

  describe "foreach execution - sequential" do
    test "executes steps for each item in collection" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleForEachWorkflow, %{})

      assert execution.status == :completed

      # Check that all items were processed
      assert execution.context["processed_count"] == 3
    end

    test "current_item returns the current item being processed" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleForEachWorkflow, %{})

      assert execution.status == :completed

      # Results should contain processed items
      assert execution.context["results"] == [
               "item_1_processed",
               "item_2_processed",
               "item_3_processed"
             ]
    end

    test "current_index returns the current index" do
      {:ok, execution} =
        create_and_execute_workflow(IndexForEachWorkflow, %{})

      assert execution.status == :completed

      # Should have captured all indices
      assert execution.context["indices"] == [0, 1, 2]
    end

    test "context changes accumulate across iterations" do
      {:ok, execution} =
        create_and_execute_workflow(AccumulatingForEachWorkflow, %{})

      assert execution.status == :completed

      # Counter should have been incremented 3 times
      assert execution.context["counter"] == 3
    end
  end

  describe "foreach execution - concurrent" do
    test "executes items concurrently with concurrency limit" do
      # Each item takes 50ms, 3 items with concurrency 3 should be ~50ms
      # Sequential would be ~150ms
      start_time = System.monotonic_time(:millisecond)

      {:ok, execution} =
        create_and_execute_workflow(ConcurrentForEachWorkflow, %{})

      elapsed = System.monotonic_time(:millisecond) - start_time

      assert execution.status == :completed
      # Should complete faster than sequential (150ms), give some headroom
      assert elapsed < 140
    end

    test "concurrent foreach processes all items using collect_as" do
      {:ok, execution} =
        create_and_execute_workflow(ConcurrentForEachWorkflow, %{})

      assert execution.status == :completed
      # When using collect_as, results are properly collected even in concurrent mode
      assert length(execution.context["item_results"]) == 3
    end
  end

  describe "foreach execution - error handling" do
    test "fail_fast stops on first error" do
      {:ok, execution} =
        create_and_execute_workflow(FailFastForEachWorkflow, %{})

      assert execution.status == :failed
      assert execution.error["type"] == "foreach_error"
    end

    test "continue collects errors and continues processing" do
      {:ok, execution} =
        create_and_execute_workflow(ContinueOnErrorForEachWorkflow, %{})

      assert execution.status == :failed
      assert execution.error["type"] == "foreach_error"
      # Should have collected errors
      assert is_list(execution.error["errors"])
    end
  end

  describe "foreach with collect_as option" do
    test "collects results into specified context key" do
      {:ok, execution} =
        create_and_execute_workflow(CollectAsForEachWorkflow, %{})

      assert execution.status == :completed
      assert is_list(execution.context["collected_results"])
      assert length(execution.context["collected_results"]) == 3
    end
  end

  describe "foreach continues after block" do
    test "execution continues to steps after foreach block" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleForEachWorkflow, %{})

      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Final step should execute after foreach
      assert "final" in executed_steps
      assert execution.context["completed"] == true
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

defmodule SimpleForEachWorkflow do
  use Durable
  use Durable.Context

  workflow "simple_foreach" do
    step :setup do
      put_context(:items, ["item_1", "item_2", "item_3"])
      put_context(:results, [])
      put_context(:processed_count, 0)
    end

    foreach :process_items, items: :items do
      step :process do
        item = current_item()
        result = "#{item}_processed"
        append_context(:results, result)
        increment_context(:processed_count, 1)
      end
    end

    step :final do
      put_context(:completed, true)
    end
  end
end

defmodule IndexForEachWorkflow do
  use Durable
  use Durable.Context

  workflow "index_foreach" do
    step :setup do
      put_context(:items, ["a", "b", "c"])
      put_context(:indices, [])
    end

    foreach :track_indices, items: :items do
      step :record_index do
        idx = current_index()
        append_context(:indices, idx)
      end
    end

    step :done do
      :ok
    end
  end
end

defmodule AccumulatingForEachWorkflow do
  use Durable
  use Durable.Context

  workflow "accumulating_foreach" do
    step :setup do
      put_context(:items, [1, 2, 3])
      put_context(:counter, 0)
    end

    foreach :count_items, items: :items do
      step :increment do
        increment_context(:counter, 1)
      end
    end

    step :done do
      :ok
    end
  end
end

defmodule ConcurrentForEachWorkflow do
  use Durable
  use Durable.Context

  workflow "concurrent_foreach" do
    step :setup do
      put_context(:items, [1, 2, 3])
    end

    foreach :process_concurrent, items: :items, concurrency: 3, collect_as: :item_results do
      step :slow_process do
        Process.sleep(50)
        item = current_item()
        put_context(:processed_value, item * 10)
      end
    end

    step :done do
      :ok
    end
  end
end

defmodule FailFastForEachWorkflow do
  use Durable
  use Durable.Context

  workflow "fail_fast_foreach" do
    step :setup do
      put_context(:items, [1, 2, 3])
    end

    foreach :process_items, items: :items do
      step :maybe_fail do
        item = current_item()

        if item == 2 do
          raise "intentional failure at item 2"
        end

        put_context(:processed, item)
      end
    end

    step :never_reached do
      put_context(:reached, true)
    end
  end
end

defmodule ContinueOnErrorForEachWorkflow do
  use Durable
  use Durable.Context

  workflow "continue_foreach" do
    step :setup do
      put_context(:items, [1, 2, 3])
      put_context(:processed, [])
    end

    foreach :process_items, items: :items, on_error: :continue do
      step :maybe_fail do
        item = current_item()

        if item == 2 do
          raise "intentional failure at item 2"
        end

        append_context(:processed, item)
      end
    end

    step :done do
      :ok
    end
  end
end

defmodule CollectAsForEachWorkflow do
  use Durable
  use Durable.Context

  workflow "collect_as_foreach" do
    step :setup do
      put_context(:items, ["a", "b", "c"])
    end

    foreach :process_items, items: :items, collect_as: :collected_results do
      step :transform do
        item = current_item()
        put_context(:result, String.upcase(item))
      end
    end

    step :done do
      :ok
    end
  end
end
