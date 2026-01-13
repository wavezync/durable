defmodule Durable.IntegrationTest do
  @moduledoc """
  Advanced integration tests combining multiple Durable features.

  These tests verify that different features work correctly together
  in realistic workflow scenarios. Features are used sequentially
  (not nested within each other).
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  import Ecto.Query

  # ============================================================================
  # Scenario 1: E-Commerce Order Processing
  # Features: Branch -> ForEach -> Parallel (sequential)
  # ============================================================================

  describe "Scenario 1: E-Commerce Order Processing" do
    test "physical order takes physical processing path" do
      input = %{
        "type" => "physical",
        "items" => [
          %{"id" => 1, "name" => "Widget", "price" => 29.99},
          %{"id" => 2, "name" => "Gadget", "price" => 49.99}
        ]
      }

      {:ok, execution} = create_and_execute_workflow(OrderProcessingWorkflow, input)

      assert execution.status == :completed

      # Physical branch should have executed
      assert execution.context["processed_as"] == "physical"
      assert execution.context["shipping_label"] == "SHIP-123"

      # Digital branch should NOT have executed
      refute Map.has_key?(execution.context, "download_url")

      # ForEach should have processed all items
      assert execution.context["items_processed"] == ["Widget", "Gadget"]

      # Final parallel tasks should have executed
      assert execution.context["email_sent"] == true
      assert execution.context["analytics_updated"] == true
      assert execution.context["completed"] == true
    end

    test "digital order takes digital processing path" do
      input = %{
        "type" => "digital",
        "items" => [
          %{"id" => 1, "name" => "E-Book", "price" => 9.99}
        ]
      }

      {:ok, execution} = create_and_execute_workflow(OrderProcessingWorkflow, input)

      assert execution.status == :completed

      # Digital branch should have executed
      assert execution.context["processed_as"] == "digital"
      assert execution.context["download_url"] == "https://example.com/download"

      # Physical branch should NOT have executed
      refute Map.has_key?(execution.context, "shipping_label")

      # ForEach should have processed item
      assert execution.context["items_processed"] == ["E-Book"]
      assert execution.context["completed"] == true
    end

    test "all features execute in correct sequence" do
      input = %{
        "type" => "digital",
        "items" => [%{"id" => 1, "name" => "Test", "price" => 10}]
      }

      {:ok, execution} = create_and_execute_workflow(OrderProcessingWorkflow, input)

      step_execs = get_step_executions(execution.id)
      step_names = Enum.map(step_execs, & &1.step_name)

      # Verify steps executed - use qualified name patterns for generated step names
      assert "validate_order" in step_names
      assert Enum.any?(step_names, &String.contains?(&1, "__process_digital"))
      assert Enum.any?(step_names, &String.contains?(&1, "__process_item"))
      assert Enum.any?(step_names, &String.contains?(&1, "__send_confirmation"))
      assert Enum.any?(step_names, &String.contains?(&1, "__update_analytics"))
      assert "complete" in step_names
    end
  end

  # ============================================================================
  # Scenario 2: Document Approval Workflow
  # Features: Decision (with goto) -> Parallel -> Branch -> ForEach
  # ============================================================================

  describe "Scenario 2: Document Approval Workflow" do
    test "auto-approves low-value requests by jumping to finalize" do
      input = %{
        "amount" => 500,
        "items" => ["item1", "item2"]
      }

      {:ok, execution} = create_and_execute_workflow(DocumentApprovalWorkflow, input)

      assert execution.status == :completed

      # Should have jumped directly to finalize (skipping parallel and branch)
      assert execution.context["finalized"] == true

      # These should NOT have executed (decision jumped over them)
      refute Map.has_key?(execution.context, "notified")
      refute Map.has_key?(execution.context, "audit_logged")
      refute Map.has_key?(execution.context, "items_updated")
    end

    test "high-value request goes through full approval flow" do
      input = %{
        "amount" => 5000,
        "items" => ["doc1", "doc2", "doc3"],
        "approval_result" => "approved"
      }

      {:ok, execution} = create_and_execute_workflow(DocumentApprovalWorkflow, input)

      assert execution.status == :completed

      # Parallel notification steps should have run
      assert execution.context["notified"] == true
      assert execution.context["audit_logged"] == true

      # Approved branch should have run
      assert execution.context["approval_processed"] == "approved"

      # ForEach should have processed all items
      assert execution.context["items_updated"] == ["doc1", "doc2", "doc3"]

      # Rejection should NOT have run
      refute Map.has_key?(execution.context, "rejection_notified")

      assert execution.context["finalized"] == true
    end

    test "rejected request follows rejection path" do
      input = %{
        "amount" => 10_000,
        "items" => ["contract1"],
        "approval_result" => "rejected"
      }

      {:ok, execution} = create_and_execute_workflow(DocumentApprovalWorkflow, input)

      assert execution.status == :completed

      # Parallel should have run
      assert execution.context["notified"] == true
      assert execution.context["audit_logged"] == true

      # Rejected branch should execute
      assert execution.context["approval_processed"] == "rejected"
      assert execution.context["rejection_notified"] == true

      # Approved forEach should NOT run items
      refute Map.has_key?(execution.context, "items_updated")

      assert execution.context["finalized"] == true
    end

    test "decision routing skips intermediate steps correctly" do
      input = %{"amount" => 100, "items" => []}

      {:ok, execution} = create_and_execute_workflow(DocumentApprovalWorkflow, input)

      step_execs = get_step_executions(execution.id)
      step_names = Enum.map(step_execs, & &1.step_name)

      # Should have: create_request, check_auto_approve, finalize
      assert "create_request" in step_names
      assert "check_auto_approve" in step_names
      assert "finalize" in step_names

      # Should NOT have parallel or branch steps
      refute Enum.any?(step_names, &String.contains?(&1, "__notify"))
      refute Enum.any?(step_names, &String.contains?(&1, "__audit"))
    end
  end

  # ============================================================================
  # Scenario 3: Batch Data Migration
  # Features: ForEach -> Decision -> Parallel -> Branch
  # ============================================================================

  describe "Scenario 3: Batch Data Migration" do
    test "successful migration processes all batches" do
      input = %{
        "batches" => [
          %{"id" => "batch1"},
          %{"id" => "batch2"},
          %{"id" => "batch3"}
        ]
      }

      {:ok, execution} = create_and_execute_workflow(BatchMigrationWorkflow, input)

      assert execution.status == :completed

      # All batches processed via foreach
      assert execution.context["migrated_ids"] == ["batch1", "batch2", "batch3"]

      # Parallel reporting tasks completed
      assert execution.context["report_generated"] == true
      assert execution.context["notifications_sent"] == true
      assert execution.context["cleanup_done"] == true

      # Success path taken
      assert execution.context["migration_status"] == "success"
      assert execution.context["completed_at"] == true
    end

    test "empty batches takes empty path via decision" do
      input = %{"batches" => []}

      {:ok, execution} = create_and_execute_workflow(BatchMigrationWorkflow, input)

      assert execution.status == :completed
      assert execution.context["migrated_ids"] == []

      # Decision should route to empty path (skip parallel and mark_success)
      assert execution.context["migration_status"] == "empty"
      assert execution.context["completed_at"] == true

      # Parallel should NOT have run
      refute Map.has_key?(execution.context, "report_generated")
      refute Map.has_key?(execution.context, "notifications_sent")
    end

    test "parallel reporting runs all tasks" do
      input = %{"batches" => [%{"id" => "batch1"}]}

      {:ok, execution} = create_and_execute_workflow(BatchMigrationWorkflow, input)

      assert execution.status == :completed

      step_execs = get_step_executions(execution.id)
      step_names = Enum.map(step_execs, & &1.step_name)

      # All three parallel steps should have executed
      assert Enum.any?(step_names, &String.contains?(&1, "__generate_report"))
      assert Enum.any?(step_names, &String.contains?(&1, "__send_notifications"))
      assert Enum.any?(step_names, &String.contains?(&1, "__cleanup_temp"))
    end
  end

  # ============================================================================
  # Scenario 4: Resume Durability with Combined Features
  # ============================================================================

  describe "Scenario 4: Resume durability with combined features" do
    test "parallel durability preserves context on resume" do
      config = Config.get(Durable)
      repo = config.repo
      {:ok, workflow_def} = OrderProcessingWorkflow.__default_workflow__()

      # Create an execution that's partway through
      attrs = %{
        workflow_module: Atom.to_string(OrderProcessingWorkflow),
        workflow_name: workflow_def.name,
        status: :pending,
        queue: "default",
        priority: 0,
        input: %{"type" => "digital", "items" => [%{"id" => 1, "name" => "Test", "price" => 10}]},
        context: %{
          "order_type" => "digital",
          "line_items" => [%{"id" => 1, "name" => "Test", "price" => 10}],
          "processed_as" => "digital",
          "download_url" => "https://example.com/download",
          "items_processed" => ["Test"]
        }
      }

      {:ok, execution} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(attrs)
        |> repo.insert()

      # Find the final parallel block
      parallel_step =
        Enum.find(workflow_def.steps, fn step ->
          step.type == :parallel and
            Enum.any?(
              step.opts[:steps] || [],
              &(Atom.to_string(&1) |> String.contains?("send_confirmation"))
            )
        end)

      parallel_step_names = parallel_step.opts[:steps]

      # Pre-create completed step execution for send_confirmation
      confirmation_step =
        Enum.find(
          parallel_step_names,
          &(Atom.to_string(&1) |> String.contains?("send_confirmation"))
        )

      {:ok, _} =
        %StepExecution{}
        |> StepExecution.changeset(%{
          workflow_id: execution.id,
          step_name: Atom.to_string(confirmation_step),
          step_type: "step",
          attempt: 1,
          status: :completed,
          output: %{
            "__output__" => nil,
            "__context__" => %{"email_sent" => true, "preserved_marker" => "from_completed_step"}
          }
        })
        |> repo.insert()

      # Set current_step to the parallel block
      {:ok, execution} =
        execution
        |> Ecto.Changeset.change(current_step: Atom.to_string(parallel_step.name))
        |> repo.update()

      # Resume execution
      Executor.execute_workflow(execution.id, config)
      execution = repo.get!(WorkflowExecution, execution.id)

      assert execution.status == :completed

      # Context from completed step should be preserved
      assert execution.context["preserved_marker"] == "from_completed_step"
      assert execution.context["email_sent"] == true

      # The other parallel step should have run
      assert execution.context["analytics_updated"] == true

      # Workflow should have completed
      assert execution.context["completed"] == true

      # send_confirmation should only have 1 execution (not re-run)
      step_execs = get_step_executions(execution.id)

      confirmation_execs =
        Enum.filter(step_execs, &String.contains?(&1.step_name, "send_confirmation"))

      assert length(confirmation_execs) == 1
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

# ============================================================================
# Test Workflow Modules
# ============================================================================

defmodule OrderProcessingWorkflow do
  @moduledoc """
  Scenario 1: E-Commerce Order Processing
  Features: Branch -> ForEach -> Parallel (sequential, not nested)
  """
  use Durable
  use Durable.Helpers

  workflow "order_processing" do
    # First step receives workflow input as data
    step(:validate_order, fn data ->
      data =
        data
        |> assign(:order_type, data["type"])
        |> assign(:line_items, data["items"])

      {:ok, data}
    end)

    # Branch based on order type
    branch on: fn data -> data.order_type end do
      "physical" ->
        step(:process_physical, fn data ->
          data =
            data
            |> assign(:processed_as, "physical")
            |> assign(:shipping_label, "SHIP-123")

          {:ok, data}
        end)

      "digital" ->
        step(:process_digital, fn data ->
          data =
            data
            |> assign(:processed_as, "digital")
            |> assign(:download_url, "https://example.com/download")

          {:ok, data}
        end)
    end

    # ForEach to process line items (sequential)
    foreach :process_items, items: fn data -> data.line_items end do
      step(:process_item, fn data, item, _idx ->
        current_list = data[:items_processed] || []
        {:ok, assign(data, :items_processed, current_list ++ [item["name"]])}
      end)
    end

    # Parallel notification tasks
    parallel do
      step(:send_confirmation, fn data ->
        {:ok, assign(data, :email_sent, true)}
      end)

      step(:update_analytics, fn data ->
        {:ok, assign(data, :analytics_updated, true)}
      end)
    end

    step(:complete, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule DocumentApprovalWorkflow do
  @moduledoc """
  Scenario 2: Document Approval with Decision routing
  Features: Decision (goto) -> Parallel -> Branch -> ForEach (sequential)
  """
  use Durable
  use Durable.Helpers

  workflow "document_approval" do
    # First step receives workflow input as data
    step(:create_request, fn data ->
      data =
        data
        |> assign(:amount, data["amount"])
        |> assign(:affected_items, data["items"])
        # Preserve original input for later steps
        |> assign(:original_input, data)

      {:ok, data}
    end)

    # Decision - auto-approve low value, otherwise continue
    decision(:check_auto_approve, fn data ->
      if data[:amount] < 1000 do
        {:goto, :finalize, data}
      else
        {:ok, data}
      end
    end)

    # Parallel notification (only runs for high-value)
    parallel do
      step(:notify_approvers, fn data ->
        {:ok, assign(data, :notified, true)}
      end)

      step(:create_audit_log, fn data ->
        {:ok, assign(data, :audit_logged, true)}
      end)
    end

    step(:set_approval, fn data ->
      # Access original input saved by first step
      original = data[:original_input] || %{}
      result = original["approval_result"] || "approved"
      {:ok, assign(data, :approval_result, result)}
    end)

    # Branch based on approval result
    branch on: fn data -> data.approval_result end do
      "approved" ->
        step(:process_approved, fn data ->
          {:ok, assign(data, :approval_processed, "approved")}
        end)

      "rejected" ->
        step(:process_rejected, fn data ->
          data =
            data
            |> assign(:approval_processed, "rejected")
            |> assign(:rejection_notified, true)

          {:ok, data}
        end)
    end

    # ForEach to update items (only runs for both, but only updates if approved)
    foreach :update_items, items: fn data -> data.affected_items end do
      step(:update_item, fn data, item, _idx ->
        if data[:approval_processed] == "approved" do
          current_list = data[:items_updated] || []
          {:ok, assign(data, :items_updated, current_list ++ [item])}
        else
          {:ok, data}
        end
      end)
    end

    step(:finalize, fn data ->
      {:ok, assign(data, :finalized, true)}
    end)
  end
end

defmodule BatchMigrationWorkflow do
  @moduledoc """
  Scenario 3: Batch Data Migration
  Features: ForEach -> Decision -> Parallel -> Branch (sequential)
  """
  use Durable
  use Durable.Helpers

  workflow "batch_migration" do
    # First step receives workflow input as data
    step(:initialize, fn data ->
      data =
        data
        |> assign(:batches, data["batches"])
        |> assign(:migrated_ids, [])

      {:ok, data}
    end)

    # ForEach to process batches (sequential)
    foreach :process_batches, items: fn data -> data.batches end do
      step(:migrate_batch, fn data, batch, _idx ->
        current_ids = data[:migrated_ids] || []
        {:ok, assign(data, :migrated_ids, current_ids ++ [batch["id"]])}
      end)
    end

    # Decision based on migration results
    # If empty, jump to finalize (skipping parallel and mark_success)
    decision(:check_results, fn data ->
      ids = data[:migrated_ids] || []

      if ids != [] do
        {:ok, data}
      else
        {:goto, :finalize, data}
      end
    end)

    # Parallel reporting (only runs if we have batches)
    parallel do
      step(:generate_report, fn data ->
        {:ok, assign(data, :report_generated, true)}
      end)

      step(:send_notifications, fn data ->
        {:ok, assign(data, :notifications_sent, true)}
      end)

      step(:cleanup_temp, fn data ->
        {:ok, assign(data, :cleanup_done, true)}
      end)
    end

    # Success path - set status
    step(:mark_success, fn data ->
      {:ok, assign(data, :migration_status, "success")}
    end)

    # Final step - both paths end here
    step(:finalize, fn data ->
      # If status not set yet, it means we jumped here (empty path)
      data =
        if Map.has_key?(data, :migration_status) do
          data
        else
          assign(data, :migration_status, "empty")
        end

      {:ok, assign(data, :completed_at, true)}
    end)
  end
end
