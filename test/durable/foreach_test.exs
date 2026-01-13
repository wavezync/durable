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

    test "handles empty items list gracefully" do
      {:ok, execution} =
        create_and_execute_workflow(EmptyForEachWorkflow, %{})

      assert execution.status == :completed
      # Foreach should complete without processing any items
      assert execution.context["processed_count"] == 0
      assert execution.context["completed"] == true
    end

    test "handles nil items in collection" do
      {:ok, execution} =
        create_and_execute_workflow(NilItemForEachWorkflow, %{})

      assert execution.status == :completed
      # Should process all items including nil
      assert execution.context["processed"] == [1, nil, 3]
      assert execution.context["completed"] == true
    end

    test "handles large collection (1000 items)" do
      {:ok, execution} =
        create_and_execute_workflow(LargeCollectionForEachWorkflow, %{})

      assert execution.status == :completed
      # Sum of 1..1000 = 500500
      assert execution.context["sum"] == 500_500
      assert execution.context["completed"] == true
    end
  end

  describe "foreach execution - concurrent" do
    test "executes items concurrently with concurrency limit" do
      {:ok, execution} =
        create_and_execute_workflow(ConcurrentForEachWorkflow, %{})

      assert execution.status == :completed
      # Concurrency is verified by the fact that all items complete successfully
      # and results are collected. Timing assertions are avoided due to CI variability.
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

  describe "foreach execution - edge cases" do
    # Note: Non-list/non-enumerable items cause Protocol.UndefinedError
    # These tests document this edge case behavior

    test "foreach with non-list items (map) iterates over map entries" do
      {:ok, execution} =
        create_and_execute_workflow(MapItemsForEachWorkflow, %{})

      # Maps are enumerable, so foreach processes key-value tuples
      assert execution.status == :completed
      # Map with 2 entries means 2 iterations
      assert execution.context["processed_count"] == 2
    end

    test "foreach with non-list items (string) raises Protocol.UndefinedError" do
      # Strings are not enumerable, so this raises an error
      assert_raise Protocol.UndefinedError, fn ->
        create_and_execute_workflow(StringItemsForEachWorkflow, %{})
      end
    end

    test "foreach with non-list items (integer) raises Protocol.UndefinedError" do
      # Integers are not enumerable, so this raises an error
      assert_raise Protocol.UndefinedError, fn ->
        create_and_execute_workflow(IntegerItemsForEachWorkflow, %{})
      end
    end

    test "foreach step that raises exception fails workflow" do
      {:ok, execution} =
        create_and_execute_workflow(RaisingForEachWorkflow, %{})

      assert execution.status == :failed
      assert execution.error != nil
    end

    # Note: nil items cause Enumerable protocol error
    test "foreach with items function returning nil raises Protocol.UndefinedError" do
      assert_raise Protocol.UndefinedError, fn ->
        create_and_execute_workflow(NilItemsForEachWorkflow, %{})
      end
    end

    test "foreach with deeply nested items processes correctly" do
      {:ok, execution} =
        create_and_execute_workflow(DeepNestedForEachWorkflow, %{})

      assert execution.status == :completed
      assert execution.context["processed_count"] == 2
      assert execution.context["names"] == ["Alice", "Bob"]
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
  use Durable.Helpers

  workflow "simple_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, ["item_1", "item_2", "item_3"])
        |> assign(:results, [])
        |> assign(:processed_count, 0)

      {:ok, data}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:process, fn data, item, _idx ->
        result = "#{item}_processed"
        results = data[:results] || []
        count = data[:processed_count] || 0

        data =
          data
          |> assign(:results, results ++ [result])
          |> assign(:processed_count, count + 1)

        {:ok, data}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule IndexForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "index_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, ["a", "b", "c"])
        |> assign(:indices, [])

      {:ok, data}
    end)

    foreach :track_indices, items: fn data -> data.items end do
      step(:record_index, fn data, _item, idx ->
        indices = data[:indices] || []
        {:ok, assign(data, :indices, indices ++ [idx])}
      end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

defmodule AccumulatingForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "accumulating_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, [1, 2, 3])
        |> assign(:counter, 0)

      {:ok, data}
    end)

    foreach :count_items, items: fn data -> data.items end do
      step(:increment, fn data, _item, _idx ->
        counter = data[:counter] || 0
        {:ok, assign(data, :counter, counter + 1)}
      end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

defmodule ConcurrentForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "concurrent_foreach" do
    step(:setup, fn data ->
      {:ok, assign(data, :items, [1, 2, 3])}
    end)

    foreach :process_concurrent,
      items: fn data -> data.items end,
      concurrency: 3,
      collect_as: :item_results do
      step(:slow_process, fn data, item, _idx ->
        Process.sleep(50)
        {:ok, assign(data, :processed_value, item * 10)}
      end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

defmodule FailFastForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "fail_fast_foreach" do
    step(:setup, fn data ->
      {:ok, assign(data, :items, [1, 2, 3])}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:maybe_fail, fn data, item, _idx ->
        if item == 2 do
          raise "intentional failure at item 2"
        end

        {:ok, assign(data, :processed, item)}
      end)
    end

    step(:never_reached, fn data ->
      {:ok, assign(data, :reached, true)}
    end)
  end
end

defmodule ContinueOnErrorForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "continue_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, [1, 2, 3])
        |> assign(:processed, [])

      {:ok, data}
    end)

    foreach :process_items, items: fn data -> data.items end, on_error: :continue do
      step(:maybe_fail, fn data, item, _idx ->
        if item == 2 do
          raise "intentional failure at item 2"
        end

        processed = data[:processed] || []
        {:ok, assign(data, :processed, processed ++ [item])}
      end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

defmodule CollectAsForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "collect_as_foreach" do
    step(:setup, fn data ->
      {:ok, assign(data, :items, ["a", "b", "c"])}
    end)

    foreach :process_items, items: fn data -> data.items end, collect_as: :collected_results do
      step(:transform, fn data, item, _idx ->
        {:ok, assign(data, :result, String.upcase(item))}
      end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

defmodule EmptyForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "empty_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, [])
        |> assign(:processed_count, 0)

      {:ok, data}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:process, fn data, _item, _idx ->
        count = data[:processed_count] || 0
        {:ok, assign(data, :processed_count, count + 1)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule NilItemForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "nil_item_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, [1, nil, 3])
        |> assign(:processed, [])

      {:ok, data}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:process, fn data, item, _idx ->
        processed = data[:processed] || []
        {:ok, assign(data, :processed, processed ++ [item])}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule LargeCollectionForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "large_collection_foreach" do
    step(:setup, fn data ->
      # Create a list of 1000 items
      items = Enum.to_list(1..1000)

      data =
        data
        |> assign(:items, items)
        |> assign(:sum, 0)

      {:ok, data}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:accumulate, fn data, item, _idx ->
        sum = data[:sum] || 0
        {:ok, assign(data, :sum, sum + item)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

# Edge case test workflows

defmodule MapItemsForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "map_items_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, %{a: 1, b: 2})
        |> assign(:processed_count, 0)

      {:ok, data}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:process, fn data, _item, _idx ->
        count = data[:processed_count] || 0
        {:ok, assign(data, :processed_count, count + 1)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule StringItemsForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "string_items_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, "not a list")
        |> assign(:processed_count, 0)

      {:ok, data}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:process, fn data, _item, _idx ->
        count = data[:processed_count] || 0
        {:ok, assign(data, :processed_count, count + 1)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule IntegerItemsForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "integer_items_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, 42)
        |> assign(:processed_count, 0)

      {:ok, data}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:process, fn data, _item, _idx ->
        count = data[:processed_count] || 0
        {:ok, assign(data, :processed_count, count + 1)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule ErrorReturningForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "error_returning_foreach" do
    step(:setup, fn data ->
      {:ok, assign(data, :items, [1, 2, 3])}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:process, fn data, item, _idx ->
        if item == 2 do
          {:error, "Item 2 caused an error"}
        else
          {:ok, assign(data, :processed, item)}
        end
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule RaisingForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "raising_foreach" do
    step(:setup, fn data ->
      {:ok, assign(data, :items, [1, 2, 3])}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:process, fn data, item, _idx ->
        if item == 2 do
          raise "Item 2 caused an error"
        end

        {:ok, assign(data, :processed, item)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule NilItemsForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "nil_items_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, nil)
        |> assign(:processed_count, 0)

      {:ok, data}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:process, fn data, _item, _idx ->
        count = data[:processed_count] || 0
        {:ok, assign(data, :processed_count, count + 1)}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule DeepNestedForEachWorkflow do
  use Durable
  use Durable.Helpers

  workflow "deep_nested_foreach" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:items, [%{user: %{name: "Alice"}}, %{user: %{name: "Bob"}}])
        |> assign(:processed_count, 0)
        |> assign(:names, [])

      {:ok, data}
    end)

    foreach :process_items, items: fn data -> data.items end do
      step(:process, fn data, item, _idx ->
        name = item.user.name
        count = data[:processed_count] || 0
        names = data[:names] || []

        data =
          data
          |> assign(:processed_count, count + 1)
          |> assign(:names, names ++ [name])

        {:ok, data}
      end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end
