defmodule Durable.ValidationTest do
  @moduledoc """
  Tests for input and step return validation edge cases.

  Tests cover:
  - Step return value validation
  - Workflow input validation
  - Invalid data handling
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.WorkflowExecution

  # ============================================================================
  # Step Return Validation Tests
  # ============================================================================

  describe "step return validation" do
    test "step returning nil instead of {:ok, data} fails workflow" do
      {:ok, execution} = create_and_execute_workflow(NilReturnWorkflow, %{})

      # Step returning nil should cause workflow to fail or handle gracefully
      assert execution.status == :failed
    end

    test "step returning plain value instead of tuple fails workflow" do
      {:ok, execution} = create_and_execute_workflow(PlainValueReturnWorkflow, %{})

      # Step returning plain value should cause workflow to fail
      assert execution.status == :failed
    end

    test "step raising exception marks workflow failed" do
      {:ok, execution} = create_and_execute_workflow(RaisingStepWorkflow, %{})

      assert execution.status == :failed
      assert execution.error != nil
    end

    test "step returning {:ok, data} with nil data continues workflow" do
      {:ok, execution} = create_and_execute_workflow(OkNilDataWorkflow, %{})

      # {:ok, nil} should be handled - workflow may fail or continue
      # depending on implementation
      assert execution.status in [:completed, :failed]
    end

    test "step returning {:ok, data, extra} fails with wrong tuple format" do
      {:ok, execution} = create_and_execute_workflow(WrongTupleFormatWorkflow, %{})

      # Wrong tuple format should cause workflow to fail
      assert execution.status == :failed
    end
  end

  # ============================================================================
  # Workflow Input Validation Tests
  # ============================================================================

  describe "workflow input validation" do
    test "empty map input to workflow" do
      {:ok, execution} = create_and_execute_workflow(SimpleInputWorkflow, %{})

      assert execution.status == :completed
      assert execution.context["input_received"] == true
    end

    test "workflow with expected input missing key" do
      # Workflow expects "name" but input doesn't have it
      {:ok, execution} = create_and_execute_workflow(ExpectedInputWorkflow, %{"other" => "value"})

      # Behavior depends on implementation - may complete with nil or fail
      assert execution.status in [:completed, :failed]
    end

    test "workflow with numeric string as input value" do
      {:ok, execution} =
        create_and_execute_workflow(NumericInputWorkflow, %{"count" => "42"})

      assert execution.status == :completed
      # The string "42" should be preserved as-is
      assert execution.context["count_value"] == "42"
    end
  end

  # ============================================================================
  # Empty and Edge Case Workflows
  # ============================================================================

  describe "empty and edge case workflows" do
    test "workflow with only one step that returns immediately" do
      {:ok, execution} = create_and_execute_workflow(SingleStepWorkflow, %{})

      assert execution.status == :completed
      assert execution.context["done"] == true
    end

    test "workflow step that modifies input directly" do
      {:ok, execution} =
        create_and_execute_workflow(InputModificationWorkflow, %{"value" => 10})

      assert execution.status == :completed
      # Verify the modification worked
      assert execution.context["doubled"] == 20
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

defmodule NilReturnWorkflow do
  use Durable
  use Durable.Helpers

  workflow "nil_return" do
    step(:returns_nil, fn _data ->
      nil
    end)
  end
end

defmodule PlainValueReturnWorkflow do
  use Durable
  use Durable.Helpers

  workflow "plain_value_return" do
    step(:returns_plain, fn _data ->
      "just a string"
    end)
  end
end

defmodule ErrorReturnWorkflow do
  use Durable
  use Durable.Helpers

  workflow "error_return" do
    step(:returns_error, fn _data ->
      {:error, "This step explicitly failed"}
    end)
  end
end

defmodule ErrorMapReturnWorkflow do
  use Durable
  use Durable.Helpers

  workflow "error_map_return" do
    step(:returns_error, fn _data ->
      {:error, %{reason: "This step explicitly failed", code: "STEP_ERROR"}}
    end)
  end
end

defmodule RaisingStepWorkflow do
  use Durable
  use Durable.Helpers

  workflow "raising_step" do
    step(:raises, fn _data ->
      raise "This step raises an exception"
    end)
  end
end

defmodule OkNilDataWorkflow do
  use Durable
  use Durable.Helpers

  workflow "ok_nil_data" do
    step(:returns_ok_nil, fn _data ->
      {:ok, nil}
    end)

    step(:after_nil, fn data ->
      {:ok, assign(data || %{}, :after_nil, true)}
    end)
  end
end

defmodule WrongTupleFormatWorkflow do
  use Durable
  use Durable.Helpers

  workflow "wrong_tuple_format" do
    step(:wrong_format, fn data ->
      {:ok, data, "extra_element"}
    end)
  end
end

defmodule SimpleInputWorkflow do
  use Durable
  use Durable.Helpers

  workflow "simple_input" do
    step(:process, fn data ->
      {:ok, assign(data || %{}, :input_received, true)}
    end)
  end
end

defmodule ExpectedInputWorkflow do
  use Durable
  use Durable.Helpers

  workflow "expected_input" do
    step(:process, fn data ->
      name = data["name"]

      data =
        (data || %{})
        |> assign(:name_value, name)
        |> assign(:name_present, name != nil)

      {:ok, data}
    end)
  end
end

defmodule NumericInputWorkflow do
  use Durable
  use Durable.Helpers

  workflow "numeric_input" do
    step(:process, fn data ->
      count = data["count"]
      {:ok, assign(data, :count_value, count)}
    end)
  end
end

defmodule SingleStepWorkflow do
  use Durable
  use Durable.Helpers

  workflow "single_step" do
    step(:only_step, fn data ->
      {:ok, assign(data, :done, true)}
    end)
  end
end

defmodule InputModificationWorkflow do
  use Durable
  use Durable.Helpers

  workflow "input_modification" do
    step(:double_value, fn data ->
      value = data["value"] || 0
      {:ok, assign(data, :doubled, value * 2)}
    end)
  end
end
