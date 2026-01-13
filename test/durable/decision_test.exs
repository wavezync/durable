defmodule Durable.DecisionTest do
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  import Ecto.Query

  describe "decision step DSL" do
    test "decision macro creates step with type :decision" do
      {:ok, definition} =
        DecisionTypeTestWorkflow.__workflow_definition__("decision_type_test")

      decision_step = Enum.find(definition.steps, &(&1.name == :branch))

      assert decision_step.type == :decision
    end

    test "decision step supports retry options" do
      {:ok, definition} = RetryDecisionTestWorkflow.__workflow_definition__("retry_decision")
      [decision_step | _] = definition.steps

      assert decision_step.opts[:retry][:max_attempts] == 3
    end
  end

  describe "decision execution - goto" do
    test "decision step jumps to target step when amount > 1000" do
      {:ok, execution} = create_and_execute_workflow(GotoTestWorkflow, %{amount: 1500})

      assert execution.status == :completed

      # Verify step execution order
      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Should have executed: setup, check_amount, manager_approval
      # Should NOT have executed: auto_approve
      assert "setup" in executed_steps
      assert "check_amount" in executed_steps
      assert "manager_approval" in executed_steps
      refute "auto_approve" in executed_steps
    end

    test "decision step jumps to auto_approve when amount <= 1000" do
      {:ok, execution} = create_and_execute_workflow(GotoTestWorkflow, %{amount: 500})

      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      assert "setup" in executed_steps
      assert "check_amount" in executed_steps
      assert "auto_approve" in executed_steps
      # manager_approval comes after auto_approve, so it should execute too
      assert "manager_approval" in executed_steps
    end

    test "decision step records goto in output" do
      {:ok, execution} = create_and_execute_workflow(GotoTestWorkflow, %{amount: 1500})

      repo = Config.get(Durable).repo

      decision_exec =
        repo.one(
          from(s in StepExecution,
            where: s.workflow_id == ^execution.id and s.step_name == "check_amount"
          )
        )

      assert decision_exec.output["decision_type"] == "goto"
      assert decision_exec.output["target_step"] == "manager_approval"
    end
  end

  describe "decision execution - multi skip" do
    test "decision step can skip multiple steps" do
      {:ok, execution} = create_and_execute_workflow(MultiSkipTestWorkflow, %{})

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Decision jumps from step 1 directly to step 4
      assert "step_one" in executed_steps
      assert "decide" in executed_steps
      assert "step_four" in executed_steps
      refute "step_two" in executed_steps
      refute "step_three" in executed_steps

      # Context should only have :reached from step_four
      assert execution.context["reached"] == true
      refute Map.has_key?(execution.context, "step_two")
      refute Map.has_key?(execution.context, "step_three")
    end
  end

  describe "decision execution - continue" do
    test "decision step with {:ok, data} proceeds to next step" do
      {:ok, execution} = create_and_execute_workflow(ContinueTestWorkflow, %{})

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # All steps should execute in order
      assert executed_steps == ["first", "decide", "second", "third"]
    end
  end

  describe "decision execution - plain return" do
    test "decision step with plain return value proceeds to next step" do
      {:ok, execution} = create_and_execute_workflow(PlainReturnTestWorkflow, %{})

      repo = Config.get(Durable).repo

      decision_exec =
        repo.one(
          from(s in StepExecution,
            where: s.workflow_id == ^execution.id and s.step_name == "decide"
          )
        )

      assert decision_exec.output["decision_type"] == "continue"
      assert execution.context["reached"] == true
    end
  end

  describe "decision validation - invalid target" do
    test "fails when target step does not exist" do
      {:ok, execution} = create_and_execute_workflow(InvalidTargetTestWorkflow, %{})

      assert execution.status == :failed
      assert execution.error["type"] == "decision_error"
      assert execution.error["message"] =~ "does not exist"
    end
  end

  describe "decision validation - backward jump" do
    test "fails when trying to jump backwards" do
      {:ok, execution} = create_and_execute_workflow(BackwardJumpTestWorkflow, %{})

      assert execution.status == :failed
      assert execution.error["type"] == "decision_error"
      assert execution.error["message"] =~ "backwards"
    end
  end

  describe "decision validation - self jump" do
    test "fails when jumping to self" do
      {:ok, execution} = create_and_execute_workflow(SelfJumpTestWorkflow, %{})

      assert execution.status == :failed
      assert execution.error["type"] == "decision_error"
      assert execution.error["message"] =~ "jump to self"
    end

    test "fails gracefully when decision function raises an exception" do
      {:ok, execution} = create_and_execute_workflow(ExceptionDecisionTestWorkflow, %{})

      assert execution.status == :failed
      assert execution.error != nil
      # The exception should be caught and converted to an error
      assert execution.error["message"] =~ "Intentional exception"
    end
  end

  describe "decision with context" do
    test "decision step can use and update context" do
      {:ok, execution} =
        create_and_execute_workflow(DecisionWithContextTestWorkflow, %{threshold: 100})

      assert execution.status == :completed
      assert execution.context["branch_taken"] == "high"
      assert execution.context["path"] == "high"
    end
  end

  describe "decision to decision" do
    test "decision can jump to another decision" do
      {:ok, execution} = create_and_execute_workflow(DecisionChainTestWorkflow, %{level: 15})

      assert execution.status == :completed
      assert execution.context["result"] == "very_high"

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      assert "first_decision" in executed_steps
      assert "second_decision" in executed_steps
      assert "very_high" in executed_steps
      refute "low_level" in executed_steps
      refute "medium" in executed_steps
    end
  end

  # Helper functions
  defp create_and_execute_workflow(module, input) do
    config = Config.get(Durable)
    repo = config.repo
    {:ok, workflow_def} = module.__default_workflow__()

    # Use Atom.to_string to get the full module name with Elixir prefix
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

# Define test workflow modules at top level so they can be looked up by Executor
defmodule DecisionTypeTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "decision_type_test" do
    step(:setup, fn data ->
      {:ok, data}
    end)

    decision(:branch, fn data ->
      {:goto, :option_a, data}
    end)

    step(:option_a, fn data ->
      {:ok, data}
    end)
  end
end

defmodule RetryDecisionTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "retry_decision" do
    decision(:risky_decision, [retry: [max_attempts: 3]], fn data ->
      {:ok, data}
    end)

    step(:next, fn data ->
      {:ok, data}
    end)
  end
end

defmodule GotoTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "goto_test" do
    step(:setup, fn data ->
      {:ok, assign(data, :amount, data["amount"])}
    end)

    decision(:check_amount, fn data ->
      if data[:amount] > 1000 do
        {:goto, :manager_approval, data}
      else
        {:goto, :auto_approve, data}
      end
    end)

    step(:auto_approve, fn data ->
      {:ok, assign(data, :approved_by, "system")}
    end)

    step(:manager_approval, fn data ->
      {:ok, assign(data, :approved_by, "manager")}
    end)
  end
end

defmodule MultiSkipTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "multi_skip" do
    step(:step_one, fn data ->
      {:ok, data}
    end)

    decision(:decide, fn data ->
      {:goto, :step_four, data}
    end)

    step(:step_two, fn data ->
      {:ok, assign(data, :step_two, true)}
    end)

    step(:step_three, fn data ->
      {:ok, assign(data, :step_three, true)}
    end)

    step(:step_four, fn data ->
      {:ok, assign(data, :reached, true)}
    end)
  end
end

defmodule ContinueTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "continue_test" do
    step(:first, fn data ->
      {:ok, assign(data, :first, true)}
    end)

    decision(:decide, fn data ->
      {:ok, data}
    end)

    step(:second, fn data ->
      {:ok, assign(data, :second, true)}
    end)

    step(:third, fn data ->
      {:ok, assign(data, :third, true)}
    end)
  end
end

defmodule PlainReturnTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "plain_return" do
    decision(:decide, fn data ->
      {:ok, data}
    end)

    step(:next, fn data ->
      {:ok, assign(data, :reached, true)}
    end)
  end
end

defmodule InvalidTargetTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "invalid_target" do
    decision(:decide, fn data ->
      {:goto, :nonexistent_step, data}
    end)

    step(:real_step, fn data ->
      {:ok, data}
    end)
  end
end

defmodule BackwardJumpTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "backward_jump" do
    step(:first, fn data ->
      {:ok, data}
    end)

    step(:second, fn data ->
      {:ok, data}
    end)

    decision(:decide, fn data ->
      {:goto, :first, data}
    end)

    step(:third, fn data ->
      {:ok, data}
    end)
  end
end

defmodule SelfJumpTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "self_jump" do
    decision(:decide, fn data ->
      {:goto, :decide, data}
    end)

    step(:next, fn data ->
      {:ok, data}
    end)
  end
end

defmodule DecisionWithContextTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "decision_with_context" do
    step(:setup, fn data ->
      {:ok,
       data
       |> assign(:value, 150)
       |> assign(:threshold, data["threshold"])}
    end)

    decision(:branch, fn data ->
      threshold = data[:threshold]

      if data[:value] > threshold do
        data = assign(data, :branch_taken, "high")
        {:goto, :high_path, data}
      else
        data = assign(data, :branch_taken, "low")
        {:goto, :low_path, data}
      end
    end)

    step(:low_path, fn data ->
      {:ok, assign(data, :path, "low")}
    end)

    step(:high_path, fn data ->
      {:ok, assign(data, :path, "high")}
    end)
  end
end

defmodule DecisionChainTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "decision_chain" do
    step(:setup, fn data ->
      {:ok, assign(data, :level, data["level"])}
    end)

    decision(:first_decision, fn data ->
      if data[:level] > 5 do
        {:goto, :second_decision, data}
      else
        {:goto, :low_level, data}
      end
    end)

    step(:low_level, fn data ->
      {:ok, assign(data, :result, "low")}
    end)

    decision(:second_decision, fn data ->
      if data[:level] > 10 do
        {:goto, :very_high, data}
      else
        {:goto, :medium, data}
      end
    end)

    step(:medium, fn data ->
      {:ok, assign(data, :result, "medium")}
    end)

    step(:very_high, fn data ->
      {:ok, assign(data, :result, "very_high")}
    end)
  end
end

defmodule ExceptionDecisionTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "exception_decision" do
    step(:setup, fn data ->
      {:ok, data}
    end)

    decision(:boom, fn _data ->
      raise "Intentional exception in decision"
    end)

    step(:never_reached, fn data ->
      {:ok, data}
    end)
  end
end
