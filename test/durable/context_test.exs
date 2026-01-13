defmodule Durable.ContextTest do
  @moduledoc """
  Tests for context handling edge cases.

  Tests cover:
  - Key atomization behavior
  - Nested map access
  - Large context handling
  - Non-serializable value handling
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.WorkflowExecution

  # ============================================================================
  # Context Key Handling Tests
  # ============================================================================

  describe "context key handling" do
    test "input with both string and atom versions of same key" do
      # When input has both :key and "key", atomization should handle this
      # The behavior depends on the order of keys in the map
      input = %{"key" => "string_value", :key => "atom_value"}

      {:ok, execution} = create_and_execute_workflow(MixedKeyInputWorkflow, input)

      assert execution.status == :completed
      # The workflow should complete and one of the values should be accessible
      assert execution.context["result"] != nil
    end

    test "nested map key access works correctly" do
      {:ok, execution} =
        create_and_execute_workflow(NestedContextWorkflow, %{
          "user" => %{"profile" => %{"name" => "Alice", "age" => 30}}
        })

      assert execution.status == :completed
      assert execution.context["extracted_name"] == "Alice"
      assert execution.context["extracted_age"] == 30
    end

    test "deeply nested map access (5 levels deep)" do
      input = %{
        "level1" => %{
          "level2" => %{
            "level3" => %{
              "level4" => %{
                "level5" => "deep_value"
              }
            }
          }
        }
      }

      {:ok, execution} = create_and_execute_workflow(DeepNestedContextWorkflow, input)

      assert execution.status == :completed
      assert execution.context["deep_value"] == "deep_value"
    end

    test "large context (100KB+) handles correctly" do
      {:ok, execution} = create_and_execute_workflow(LargeContextWorkflow, %{})

      assert execution.status == :completed
      # Context should contain the large data
      assert byte_size(:erlang.term_to_binary(execution.context)) > 100_000
    end
  end

  # ============================================================================
  # Non-Serializable Value Tests
  # ============================================================================

  describe "non-serializable context values" do
    test "workflow completes when step uses PID internally" do
      {:ok, execution} = create_and_execute_workflow(PidUsageWorkflow, %{})

      assert execution.status == :completed
      # The workflow should complete successfully
      # PID was used internally but not stored in context
      assert execution.context["completed"] == true
    end

    test "binary data in context preserves correctly" do
      {:ok, execution} = create_and_execute_workflow(BinaryDataWorkflow, %{})

      assert execution.status == :completed
      # Binary should be preserved
      assert execution.context["binary_data"] == "binary_content"
    end

    test "empty map and empty list in context" do
      {:ok, execution} = create_and_execute_workflow(EmptyCollectionsWorkflow, %{})

      assert execution.status == :completed
      assert execution.context["empty_map"] == %{}
      assert execution.context["empty_list"] == []
    end
  end

  # ============================================================================
  # Context Preservation Tests
  # ============================================================================

  describe "context preservation" do
    test "context preserves special characters in string values" do
      input = %{"text" => "Hello\nWorld\t\"quoted\" 'single' & <html>"}

      {:ok, execution} = create_and_execute_workflow(SpecialCharsContextWorkflow, input)

      assert execution.status == :completed
      assert execution.context["preserved"] == "Hello\nWorld\t\"quoted\" 'single' & <html>"
    end

    test "context preserves unicode strings" do
      input = %{"text" => "こんにちは世界 🌍 مرحبا"}

      {:ok, execution} = create_and_execute_workflow(UnicodeContextWorkflow, input)

      assert execution.status == :completed
      assert execution.context["preserved"] == "こんにちは世界 🌍 مرحبا"
    end

    test "context preserves numeric types correctly" do
      {:ok, execution} = create_and_execute_workflow(NumericContextWorkflow, %{})

      assert execution.status == :completed
      assert execution.context["integer"] == 42
      assert execution.context["float"] == 3.14159
      assert execution.context["negative"] == -100
      assert execution.context["zero"] == 0
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

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
end

# ============================================================================
# Test Workflow Modules
# ============================================================================

defmodule MixedKeyInputWorkflow do
  use Durable
  use Durable.Helpers

  workflow "mixed_key_input" do
    step(:process, fn data ->
      # Try to access the key - either atom or string version
      result = data[:key] || data["key"]
      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule NestedContextWorkflow do
  use Durable
  use Durable.Helpers

  workflow "nested_context" do
    step(:extract, fn data ->
      # Access nested data
      user = data["user"] || data[:user]
      profile = user["profile"] || user[:profile]
      name = profile["name"] || profile[:name]
      age = profile["age"] || profile[:age]

      data =
        data
        |> assign(:extracted_name, name)
        |> assign(:extracted_age, age)

      {:ok, data}
    end)
  end
end

defmodule DeepNestedContextWorkflow do
  use Durable
  use Durable.Helpers

  workflow "deep_nested_context" do
    step(:extract, fn data ->
      # Navigate through 5 levels
      l1 = data["level1"] || data[:level1]
      l2 = l1["level2"] || l1[:level2]
      l3 = l2["level3"] || l2[:level3]
      l4 = l3["level4"] || l3[:level4]
      l5 = l4["level5"] || l4[:level5]

      {:ok, assign(data, :deep_value, l5)}
    end)
  end
end

defmodule LargeContextWorkflow do
  use Durable
  use Durable.Helpers

  workflow "large_context" do
    step(:generate_large_data, fn data ->
      # Generate ~100KB of data
      large_list =
        for i <- 1..1000,
            do: %{
              id: i,
              name: "Item #{i}",
              description: String.duplicate("x", 100)
            }

      {:ok, assign(data, :large_data, large_list)}
    end)
  end
end

defmodule PidUsageWorkflow do
  use Durable
  use Durable.Helpers

  workflow "pid_usage" do
    step(:use_pid, fn data ->
      # Use PID internally but don't store it
      pid = self()
      _info = Process.info(pid)

      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule BinaryDataWorkflow do
  use Durable
  use Durable.Helpers

  workflow "binary_data" do
    step(:store_binary, fn data ->
      # Store a simple string (which is a binary in Elixir)
      {:ok, assign(data, :binary_data, "binary_content")}
    end)
  end
end

defmodule EmptyCollectionsWorkflow do
  use Durable
  use Durable.Helpers

  workflow "empty_collections" do
    step(:store_empty, fn data ->
      data =
        data
        |> assign(:empty_map, %{})
        |> assign(:empty_list, [])

      {:ok, data}
    end)
  end
end

defmodule SpecialCharsContextWorkflow do
  use Durable
  use Durable.Helpers

  workflow "special_chars_context" do
    step(:preserve, fn data ->
      text = data["text"]
      {:ok, assign(data, :preserved, text)}
    end)
  end
end

defmodule UnicodeContextWorkflow do
  use Durable
  use Durable.Helpers

  workflow "unicode_context" do
    step(:preserve, fn data ->
      text = data["text"]
      {:ok, assign(data, :preserved, text)}
    end)
  end
end

defmodule NumericContextWorkflow do
  use Durable
  use Durable.Helpers

  workflow "numeric_context" do
    step(:store_numbers, fn data ->
      data =
        data
        |> assign(:integer, 42)
        |> assign(:float, 3.14159)
        |> assign(:negative, -100)
        |> assign(:zero, 0)

      {:ok, data}
    end)
  end
end
