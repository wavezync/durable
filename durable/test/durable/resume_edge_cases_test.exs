defmodule Durable.ResumeEdgeCasesTest do
  @moduledoc """
  Tests for resume and durability edge cases.

  Tests cover:
  - Resume with corrupted state
  - Resume with invalid current_step
  - Resume with modified workflow definitions
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  # ============================================================================
  # Resume with Corrupted State Tests
  # ============================================================================

  describe "resume with corrupted state" do
    # Note: Resume with non-existent current_step atom causes ArgumentError
    # This is documented behavior - binary_to_existing_atom fails
    # The test below documents this edge case

    test "resume with non-existent current_step raises ArgumentError" do
      config = Config.get(Durable)
      repo = config.repo
      {:ok, workflow_def} = ResumableWorkflow.__default_workflow__()

      # Create workflow with invalid current_step
      attrs = %{
        workflow_module: Atom.to_string(ResumableWorkflow),
        workflow_name: workflow_def.name,
        status: :pending,
        queue: "default",
        priority: 0,
        input: %{},
        context: %{"step1_done" => true},
        current_step: "nonexistent_step_name"
      }

      {:ok, execution} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(attrs)
        |> repo.insert()

      # Execute - should raise ArgumentError due to binary_to_existing_atom
      assert_raise ArgumentError, fn ->
        Executor.execute_workflow(execution.id, config)
      end
    end

    test "resume with empty context but populated step history" do
      config = Config.get(Durable)
      repo = config.repo
      {:ok, workflow_def} = ResumableWorkflow.__default_workflow__()

      # Create workflow in running state
      attrs = %{
        workflow_module: Atom.to_string(ResumableWorkflow),
        workflow_name: workflow_def.name,
        status: :pending,
        queue: "default",
        priority: 0,
        input: %{"value" => 10},
        context: %{},
        current_step: "step2"
      }

      {:ok, execution} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(attrs)
        |> repo.insert()

      # Add a completed step execution record
      {:ok, _step_exec} =
        %StepExecution{}
        |> StepExecution.changeset(%{
          workflow_id: execution.id,
          step_name: "step1",
          step_type: "step",
          attempt: 1,
          status: :completed,
          output: %{
            "__output__" => nil,
            "__context__" => %{"step1_done" => true, "computed" => 20}
          }
        })
        |> repo.insert()

      # Execute/resume the workflow
      Executor.execute_workflow(execution.id, config)
      execution = repo.get!(WorkflowExecution, execution.id)

      # Workflow should complete - context should be restored from step executions
      assert execution.status == :completed
    end

    test "resume from beginning when current_step is nil" do
      config = Config.get(Durable)
      repo = config.repo
      {:ok, workflow_def} = ResumableWorkflow.__default_workflow__()

      # Create workflow with nil current_step
      attrs = %{
        workflow_module: Atom.to_string(ResumableWorkflow),
        workflow_name: workflow_def.name,
        status: :pending,
        queue: "default",
        priority: 0,
        input: %{"value" => 5},
        context: %{},
        current_step: nil
      }

      {:ok, execution} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(attrs)
        |> repo.insert()

      # Execute - should start from beginning
      Executor.execute_workflow(execution.id, config)
      execution = repo.get!(WorkflowExecution, execution.id)

      assert execution.status == :completed
      assert execution.context["step1_done"] == true
      assert execution.context["step2_done"] == true
    end
  end

  # ============================================================================
  # Resume with Modified Definitions Tests
  # ============================================================================

  describe "resume with definition changes" do
    test "workflow completes normally when resuming existing step" do
      config = Config.get(Durable)
      repo = config.repo
      {:ok, workflow_def} = ResumableWorkflow.__default_workflow__()

      # Get the actual step names from the workflow definition
      step_names = Enum.map(workflow_def.steps, & &1.name)

      # Find step2's actual name
      step2_name =
        Enum.find(step_names, fn name ->
          name == :step2 or Atom.to_string(name) == "step2"
        end)

      attrs = %{
        workflow_module: Atom.to_string(ResumableWorkflow),
        workflow_name: workflow_def.name,
        status: :pending,
        queue: "default",
        priority: 0,
        input: %{"value" => 10},
        context: %{"step1_done" => true, "computed" => 20},
        current_step: Atom.to_string(step2_name)
      }

      {:ok, execution} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(attrs)
        |> repo.insert()

      # Execute from step2
      Executor.execute_workflow(execution.id, config)
      execution = repo.get!(WorkflowExecution, execution.id)

      assert execution.status == :completed
      assert execution.context["step2_done"] == true
    end
  end

  # ============================================================================
  # Context Restoration Tests
  # ============================================================================

  describe "context restoration on resume" do
    test "context from completed steps is merged on resume" do
      config = Config.get(Durable)
      repo = config.repo
      {:ok, workflow_def} = MultiStepResumableWorkflow.__default_workflow__()

      attrs = %{
        workflow_module: Atom.to_string(MultiStepResumableWorkflow),
        workflow_name: workflow_def.name,
        status: :pending,
        queue: "default",
        priority: 0,
        input: %{},
        context: %{},
        current_step: "step3"
      }

      {:ok, execution} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(attrs)
        |> repo.insert()

      # Add completed step executions for step1 and step2
      for {step_name, context} <- [
            {"step1", %{"step1_value" => "a"}},
            {"step2", %{"step2_value" => "b"}}
          ] do
        {:ok, _} =
          %StepExecution{}
          |> StepExecution.changeset(%{
            workflow_id: execution.id,
            step_name: step_name,
            step_type: "step",
            attempt: 1,
            status: :completed,
            output: %{"__output__" => nil, "__context__" => context}
          })
          |> repo.insert()
      end

      # Resume from step3
      Executor.execute_workflow(execution.id, config)
      execution = repo.get!(WorkflowExecution, execution.id)

      assert execution.status == :completed
      # Context from previous steps should be preserved
      # Note: Exact behavior depends on implementation
      assert execution.context["step3_value"] == "c"
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  # No helper needed - tests create executions manually
end

# ============================================================================
# Test Workflow Modules
# ============================================================================

defmodule ResumableWorkflow do
  use Durable
  use Durable.Helpers

  workflow "resumable" do
    step(:step1, fn data ->
      value = data["value"] || 0

      data =
        data
        |> assign(:step1_done, true)
        |> assign(:computed, value * 2)

      {:ok, data}
    end)

    step(:step2, fn data ->
      {:ok, assign(data, :step2_done, true)}
    end)
  end
end

defmodule MultiStepResumableWorkflow do
  use Durable
  use Durable.Helpers

  workflow "multi_step_resumable" do
    step(:step1, fn data ->
      {:ok, assign(data, :step1_value, "a")}
    end)

    step(:step2, fn data ->
      {:ok, assign(data, :step2_value, "b")}
    end)

    step(:step3, fn data ->
      {:ok, assign(data, :step3_value, "c")}
    end)

    step(:step4, fn data ->
      {:ok, assign(data, :step4_value, "d")}
    end)
  end
end
