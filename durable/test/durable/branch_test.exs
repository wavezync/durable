defmodule Durable.BranchTest do
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  import Ecto.Query

  describe "branch macro DSL compilation" do
    test "branch macro creates step with type :branch" do
      {:ok, definition} =
        SimpleBranchTestWorkflow.__workflow_definition__("simple_branch")

      branch_step = Enum.find(definition.steps, &(&1.type == :branch))

      assert branch_step != nil
      assert branch_step.type == :branch
      assert branch_step.opts[:clauses] != nil
      # In the new DSL, condition function is stored in body_fn
      assert branch_step.body_fn != nil
    end

    test "branch creates qualified step names for nested steps" do
      {:ok, definition} =
        SimpleBranchTestWorkflow.__workflow_definition__("simple_branch")

      step_names = Enum.map(definition.steps, & &1.name) |> Enum.map(&Atom.to_string/1)

      # Should have qualified names like branch_<id>__<clause>__<step>
      assert Enum.any?(step_names, &String.contains?(&1, "branch_"))
      assert Enum.any?(step_names, &String.contains?(&1, "__invoice__"))
      assert Enum.any?(step_names, &String.contains?(&1, "__contract__"))
    end

    test "branch includes all nested step definitions in workflow" do
      {:ok, definition} =
        SimpleBranchTestWorkflow.__workflow_definition__("simple_branch")

      # Should have: setup, branch_X, branch steps for invoice and contract, final
      assert length(definition.steps) >= 4
    end
  end

  describe "branch execution - exact match" do
    test "executes only invoice branch when doc_type is :invoice" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleBranchTestWorkflow, %{"doc_type" => "invoice"})

      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Should execute setup step
      assert "setup" in executed_steps

      # Should execute invoice branch step(s)
      assert Enum.any?(executed_steps, &String.contains?(&1, "invoice"))

      # Should NOT execute contract branch step(s)
      refute Enum.any?(executed_steps, &String.contains?(&1, "contract"))

      # Should execute final step
      assert "final" in executed_steps

      # Context should reflect invoice processing
      assert execution.context["processed_as"] == "invoice"
    end

    test "executes only contract branch when doc_type is :contract" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleBranchTestWorkflow, %{"doc_type" => "contract"})

      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Should execute contract branch step(s)
      assert Enum.any?(executed_steps, &String.contains?(&1, "contract"))

      # Should NOT execute invoice branch step(s)
      refute Enum.any?(executed_steps, &String.contains?(&1, "invoice"))

      # Context should reflect contract processing
      assert execution.context["processed_as"] == "contract"
    end
  end

  describe "branch execution - default clause" do
    test "executes default branch when no exact match" do
      {:ok, execution} =
        create_and_execute_workflow(BranchWithDefaultWorkflow, %{"doc_type" => "unknown"})

      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Should execute default branch
      assert Enum.any?(executed_steps, &String.contains?(&1, "default"))

      # Should NOT execute other branches
      refute Enum.any?(executed_steps, &String.contains?(&1, "__invoice__"))

      assert execution.context["processed_as"] == "manual_review"
    end

    test "skips branch and continues when no clause matches and no default exists" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleBranchTestWorkflow, %{"doc_type" => "unknown"})

      # Workflow completes - branch is skipped when no clause matches
      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Setup and final steps should execute
      assert "setup" in executed_steps
      assert "final" in executed_steps

      # No branch steps should execute
      refute Enum.any?(executed_steps, &String.contains?(&1, "__invoice__"))
      refute Enum.any?(executed_steps, &String.contains?(&1, "__contract__"))

      # No processed_as should be set
      refute Map.has_key?(execution.context, "processed_as")
    end
  end

  describe "branch with multiple steps per clause" do
    test "executes all steps in matching branch in order" do
      {:ok, execution} =
        create_and_execute_workflow(MultiStepBranchWorkflow, %{"doc_type" => "invoice"})

      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Should execute both invoice steps in order
      invoice_steps =
        Enum.filter(executed_steps, &String.contains?(&1, "invoice"))

      # Should have 2 invoice steps
      assert length(invoice_steps) == 2

      # Context should have both step results
      assert execution.context["step_1"] == "extracted"
      assert execution.context["step_2"] == "validated"
    end
  end

  describe "branch continues after block" do
    test "execution continues to steps after branch block" do
      {:ok, execution} =
        create_and_execute_workflow(SimpleBranchTestWorkflow, %{"doc_type" => "invoice"})

      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      executed_steps = Enum.map(step_execs, & &1.step_name)

      # Final step should execute after branch
      assert "final" in executed_steps
      assert execution.context["completed"] == true
    end
  end

  describe "branch with context access" do
    test "branch condition can access context" do
      {:ok, execution} =
        create_and_execute_workflow(ContextBranchWorkflow, %{"amount" => 1500})

      assert execution.status == :completed
      assert execution.context["approval_type"] == "manager"
    end

    test "branch steps can read and write context" do
      {:ok, execution} =
        create_and_execute_workflow(ContextBranchWorkflow, %{"amount" => 500})

      assert execution.status == :completed
      assert execution.context["approval_type"] == "auto"
    end
  end

  describe "branch with string conditions" do
    test "branch matches string condition correctly" do
      {:ok, execution} =
        create_and_execute_workflow(StringConditionBranchWorkflow, %{"category" => "electronics"})

      assert execution.status == :completed
      assert execution.context["processed_as"] == "electronics"
    end

    test "branch uses default when string does not match" do
      {:ok, execution} =
        create_and_execute_workflow(StringConditionBranchWorkflow, %{"category" => "unknown"})

      assert execution.status == :completed
      assert execution.context["processed_as"] == "other"
    end
  end

  describe "branch execution - edge cases" do
    test "branch with integer condition matches correctly" do
      {:ok, execution} =
        create_and_execute_workflow(IntegerConditionBranchWorkflow, %{"priority" => 1})

      assert execution.status == :completed
      assert execution.context["processed_as"] == "high"
    end

    test "branch with integer condition falls to default when no match" do
      {:ok, execution} =
        create_and_execute_workflow(IntegerConditionBranchWorkflow, %{"priority" => 99})

      assert execution.status == :completed
      assert execution.context["processed_as"] == "unknown"
    end

    test "branch with boolean false condition (not just falsy)" do
      {:ok, execution} =
        create_and_execute_workflow(BooleanConditionBranchWorkflow, %{"enabled" => false})

      assert execution.status == :completed
      assert execution.context["processed_as"] == "disabled"
    end

    test "branch with boolean true condition" do
      {:ok, execution} =
        create_and_execute_workflow(BooleanConditionBranchWorkflow, %{"enabled" => true})

      assert execution.status == :completed
      assert execution.context["processed_as"] == "enabled"
    end

    test "branch with nil condition value uses default if present" do
      {:ok, execution} =
        create_and_execute_workflow(NilConditionBranchWorkflow, %{"value" => nil})

      assert execution.status == :completed
      assert execution.context["processed_as"] == "nil_handled"
    end

    test "branch condition function raising exception fails workflow" do
      {:ok, execution} =
        create_and_execute_workflow(ExceptionConditionBranchWorkflow, %{})

      assert execution.status == :failed
      assert execution.error != nil
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

defmodule SimpleBranchTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "simple_branch" do
    step(:setup, fn data ->
      # In pipeline model, first step receives workflow input directly
      doc_type = String.to_atom(data["doc_type"])
      {:ok, assign(data, :doc_type, doc_type)}
    end)

    branch on: fn data -> data.doc_type end do
      :invoice ->
        step(:process_invoice, fn data ->
          {:ok, assign(data, :processed_as, "invoice")}
        end)

      :contract ->
        step(:process_contract, fn data ->
          {:ok, assign(data, :processed_as, "contract")}
        end)
    end

    step(:final, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule BranchWithDefaultWorkflow do
  use Durable
  use Durable.Helpers

  workflow "branch_with_default" do
    step(:setup, fn data ->
      doc_type = String.to_atom(data["doc_type"])
      {:ok, assign(data, :doc_type, doc_type)}
    end)

    branch on: fn data -> data.doc_type end do
      :invoice ->
        step(:process_invoice, fn data ->
          {:ok, assign(data, :processed_as, "invoice")}
        end)

      _ ->
        step(:manual_review, fn data ->
          {:ok, assign(data, :processed_as, "manual_review")}
        end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

defmodule MultiStepBranchWorkflow do
  use Durable
  use Durable.Helpers

  workflow "multi_step_branch" do
    step(:setup, fn data ->
      doc_type = String.to_atom(data["doc_type"])
      {:ok, assign(data, :doc_type, doc_type)}
    end)

    branch on: fn data -> data.doc_type end do
      :invoice ->
        step(:extract_invoice, fn data ->
          {:ok, assign(data, :step_1, "extracted")}
        end)

        step(:validate_invoice, fn data ->
          {:ok, assign(data, :step_2, "validated")}
        end)

      :contract ->
        step(:extract_contract, fn data ->
          {:ok, assign(data, :step_1, "extracted")}
        end)
    end

    step(:store, fn data ->
      {:ok, data}
    end)
  end
end

defmodule ContextBranchWorkflow do
  use Durable
  use Durable.Helpers

  workflow "context_branch" do
    step(:setup, fn data ->
      {:ok, assign(data, :amount, data["amount"])}
    end)

    branch on: fn data -> data.amount > 1000 end do
      true ->
        step(:manager_approval, fn data ->
          {:ok, assign(data, :approval_type, "manager")}
        end)

      false ->
        step(:auto_approval, fn data ->
          {:ok, assign(data, :approval_type, "auto")}
        end)
    end

    step(:complete, fn data ->
      {:ok, data}
    end)
  end
end

defmodule StringConditionBranchWorkflow do
  use Durable
  use Durable.Helpers

  workflow "string_condition_branch" do
    step(:setup, fn data ->
      # Keep the string type, don't convert to atom
      {:ok, assign(data, :category, data["category"])}
    end)

    branch on: fn data -> data.category end do
      "electronics" ->
        step(:process_electronics, fn data ->
          {:ok, assign(data, :processed_as, "electronics")}
        end)

      "clothing" ->
        step(:process_clothing, fn data ->
          {:ok, assign(data, :processed_as, "clothing")}
        end)

      _ ->
        step(:process_other, fn data ->
          {:ok, assign(data, :processed_as, "other")}
        end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

# Edge case test workflows

defmodule IntegerConditionBranchWorkflow do
  use Durable
  use Durable.Helpers

  workflow "integer_condition_branch" do
    step(:setup, fn data ->
      {:ok, assign(data, :priority, data["priority"])}
    end)

    branch on: fn data -> data.priority end do
      1 ->
        step(:high_priority, fn data ->
          {:ok, assign(data, :processed_as, "high")}
        end)

      2 ->
        step(:medium_priority, fn data ->
          {:ok, assign(data, :processed_as, "medium")}
        end)

      3 ->
        step(:low_priority, fn data ->
          {:ok, assign(data, :processed_as, "low")}
        end)

      _ ->
        step(:unknown_priority, fn data ->
          {:ok, assign(data, :processed_as, "unknown")}
        end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

defmodule BooleanConditionBranchWorkflow do
  use Durable
  use Durable.Helpers

  workflow "boolean_condition_branch" do
    step(:setup, fn data ->
      {:ok, assign(data, :enabled, data["enabled"])}
    end)

    branch on: fn data -> data.enabled end do
      true ->
        step(:process_enabled, fn data ->
          {:ok, assign(data, :processed_as, "enabled")}
        end)

      false ->
        step(:process_disabled, fn data ->
          {:ok, assign(data, :processed_as, "disabled")}
        end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

defmodule NilConditionBranchWorkflow do
  use Durable
  use Durable.Helpers

  workflow "nil_condition_branch" do
    step(:setup, fn data ->
      {:ok, assign(data, :value, data["value"])}
    end)

    branch on: fn data -> data.value end do
      nil ->
        step(:handle_nil, fn data ->
          {:ok, assign(data, :processed_as, "nil_handled")}
        end)

      _ ->
        step(:handle_other, fn data ->
          {:ok, assign(data, :processed_as, "other")}
        end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end

defmodule ExceptionConditionBranchWorkflow do
  use Durable
  use Durable.Helpers

  workflow "exception_condition_branch" do
    step(:setup, fn data ->
      {:ok, data}
    end)

    branch on: fn _data -> raise "Condition evaluation failed" end do
      :a ->
        step(:process_a, fn data ->
          {:ok, assign(data, :processed_as, "a")}
        end)

      _ ->
        step(:process_default, fn data ->
          {:ok, assign(data, :processed_as, "default")}
        end)
    end

    step(:done, fn data ->
      {:ok, data}
    end)
  end
end
