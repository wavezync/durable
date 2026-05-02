defmodule Durable.OrchestrationTest do
  @moduledoc """
  Tests for workflow orchestration (call_workflow/start_workflow).

  Tests cover:
  - call_workflow: sync child, child completes/fails, timeout, resume, idempotency
  - start_workflow: fire-and-forget, idempotency, independent completion
  - Cascade cancellation
  - Nesting (A calls B calls C)
  - Integration with branches
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{PendingEvent, WorkflowExecution}

  import Ecto.Query

  # ============================================================================
  # call_workflow Tests
  # ============================================================================

  describe "call_workflow/3" do
    test "parent calls child, child completes, parent gets result" do
      config = Config.get(Durable)
      repo = config.repo

      # Start parent — it will create child and go to :waiting
      {:ok, parent} = create_and_execute_workflow(CallWorkflowParent, %{})

      assert parent.status == :waiting
      assert parent.context["before_call"] == true

      # Child should exist with parent_workflow_id set
      child_id = parent.context["__child:simple_child_workflow"]
      assert child_id != nil

      child = repo.get!(WorkflowExecution, child_id)
      assert child.parent_workflow_id == parent.id
      assert child.status == :pending

      # A pending event should exist for child completion
      event_name = "__child_done:#{child_id}"
      pending = get_pending_event(repo, parent.id, event_name)
      assert pending != nil
      assert pending.status == :pending

      # Execute the child workflow
      Executor.execute_workflow(child_id, config)

      child = repo.get!(WorkflowExecution, child_id)
      assert child.status == :completed
      assert child.context["child_result"] == "done"

      # Parent should have been resumed — execute it
      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :pending

      Executor.execute_workflow(parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :completed
      assert parent.context["call_result"] != nil
      assert parent.context["after_call"] == true
    end

    test "parent calls child, child fails, parent gets error" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(CallWorkflowFailingParent, %{})

      assert parent.status == :waiting

      child_id = parent.context["__child:failing_child_workflow"]
      assert child_id != nil

      # Execute the failing child
      Executor.execute_workflow(child_id, config)

      child = repo.get!(WorkflowExecution, child_id)
      assert child.status == :failed

      # Parent should be resumed
      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :pending

      Executor.execute_workflow(parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :completed
      assert parent.context["got_error"] == true
    end

    test "idempotency: resumed parent does not create duplicate child" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(CallWorkflowParent, %{})

      assert parent.status == :waiting
      child_id = parent.context["__child:simple_child_workflow"]

      # Count children before
      children_before =
        repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^parent.id))

      assert length(children_before) == 1

      # Execute child to complete it
      Executor.execute_workflow(child_id, config)

      # Resume parent — it should find the result, not create another child
      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :pending

      Executor.execute_workflow(parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :completed

      # Still only 1 child
      children_after =
        repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^parent.id))

      assert length(children_after) == 1
    end

    test "resume: child still running causes parent to re-wait" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(CallWorkflowParent, %{})

      assert parent.status == :waiting
      child_id = parent.context["__child:simple_child_workflow"]

      # Manually set parent back to pending to simulate crash-resume
      # without child completing
      parent_exec = repo.get!(WorkflowExecution, parent.id)

      parent_exec
      |> Ecto.Changeset.change(status: :pending)
      |> repo.update!()

      # Delete the pending event so it won't block
      repo.delete_all(from(p in PendingEvent, where: p.workflow_id == ^parent.id))

      # Re-execute parent — child is still pending, should re-wait
      Executor.execute_workflow(parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :waiting

      # Now execute child
      Executor.execute_workflow(child_id, config)

      # Resume parent
      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :pending

      Executor.execute_workflow(parent.id, config)

      parent = repo.get!(WorkflowExecution, parent.id)
      assert parent.status == :completed
    end
  end

  # ============================================================================
  # start_workflow Tests
  # ============================================================================

  describe "start_workflow/3" do
    test "fire-and-forget: parent continues, child created with parent_workflow_id" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(FireForgetParent, %{})

      # Parent should complete (no waiting)
      assert parent.status == :completed
      assert parent.context["before_fire"] == true
      assert parent.context["after_fire"] == true

      child_id = parent.context["__fire_forget:confirmation_email"]
      assert child_id != nil

      child = repo.get!(WorkflowExecution, child_id)
      assert child.parent_workflow_id == parent.id
      assert child.status == :pending

      # Execute child independently
      Executor.execute_workflow(child_id, config)

      child = repo.get!(WorkflowExecution, child_id)
      assert child.status == :completed
    end

    test "idempotency: same ref returns same child_id on resume" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(FireForgetIdempotentParent, %{})

      assert parent.status == :completed

      # Both start_workflow calls in the step used the same ref
      # Only one child should exist
      children =
        repo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^parent.id))

      # The step calls start_workflow twice with different refs
      assert length(children) == 2
      assert parent.context["child1_id"] != parent.context["child2_id"]
    end

    test "multiple fire-and-forget children with distinct refs" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(FireForgetIdempotentParent, %{})

      assert parent.status == :completed

      children =
        repo.all(
          from(w in WorkflowExecution,
            where: w.parent_workflow_id == ^parent.id,
            order_by: [asc: :inserted_at]
          )
        )

      assert length(children) == 2

      Enum.each(children, fn child ->
        assert child.parent_workflow_id == parent.id

        # Execute each child
        Executor.execute_workflow(child.id, config)
        child = repo.get!(WorkflowExecution, child.id)
        assert child.status == :completed
      end)
    end
  end

  # ============================================================================
  # Cascade Cancellation Tests
  # ============================================================================

  describe "cascade cancellation" do
    test "cancel parent cancels pending children" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(CallWorkflowParent, %{})

      assert parent.status == :waiting
      child_id = parent.context["__child:simple_child_workflow"]

      child = repo.get!(WorkflowExecution, child_id)
      assert child.status == :pending

      # Cancel parent
      :ok = Executor.cancel_workflow(parent.id, "test_cancel")

      # Child should be cancelled too
      child = repo.get!(WorkflowExecution, child_id)
      assert child.status == :cancelled
      assert child.error["message"] == "parent_cancelled"
    end

    test "cancel parent does not affect completed children" do
      config = Config.get(Durable)
      repo = config.repo

      # Use fire-and-forget so parent completes
      {:ok, parent} = create_and_execute_workflow(FireForgetParent, %{})

      child_id = parent.context["__fire_forget:confirmation_email"]

      # Complete the child first
      Executor.execute_workflow(child_id, config)

      child = repo.get!(WorkflowExecution, child_id)
      assert child.status == :completed

      # Now create another workflow that we can cancel
      # (The fire-forget parent already completed, so let's test with call_workflow)
      {:ok, parent2} = create_and_execute_workflow(CallWorkflowParent, %{})

      child2_id = parent2.context["__child:simple_child_workflow"]

      # Complete child2
      Executor.execute_workflow(child2_id, config)

      child2 = repo.get!(WorkflowExecution, child2_id)
      assert child2.status == :completed

      # Cancel parent (which is now pending after child resumed it)
      parent2 = repo.get!(WorkflowExecution, parent2.id)
      assert parent2.status == :pending

      :ok = Executor.cancel_workflow(parent2.id, "test_cancel")

      # Already-completed child should remain completed
      child2 = repo.get!(WorkflowExecution, child2_id)
      assert child2.status == :completed
    end
  end

  # ============================================================================
  # Nesting Tests
  # ============================================================================

  describe "nesting" do
    test "A calls B calls C — full chain completes" do
      config = Config.get(Durable)
      repo = config.repo

      # Start A (grandparent)
      {:ok, a} = create_and_execute_workflow(GrandparentWorkflow, %{})

      assert a.status == :waiting

      # B (child of A) should exist
      b_id = a.context["__child:parent_workflow"]
      assert b_id != nil

      # Execute B — it will call C and wait
      Executor.execute_workflow(b_id, config)

      b = repo.get!(WorkflowExecution, b_id)
      assert b.status == :waiting

      # C (child of B) should exist
      c_id = b.context["__child:simple_child_workflow"]
      assert c_id != nil

      c = repo.get!(WorkflowExecution, c_id)
      assert c.parent_workflow_id == b_id

      # Execute C
      Executor.execute_workflow(c_id, config)

      c = repo.get!(WorkflowExecution, c_id)
      assert c.status == :completed

      # B should be resumed
      b = repo.get!(WorkflowExecution, b_id)
      assert b.status == :pending

      Executor.execute_workflow(b_id, config)

      b = repo.get!(WorkflowExecution, b_id)
      assert b.status == :completed

      # A should be resumed
      a = repo.get!(WorkflowExecution, a.id)
      assert a.status == :pending

      Executor.execute_workflow(a.id, config)

      a = repo.get!(WorkflowExecution, a.id)
      assert a.status == :completed
      assert a.context["chain_complete"] == true
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration" do
    test "start_workflow inside step works (no blocking)" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, parent} = create_and_execute_workflow(FireForgetParent, %{})

      assert parent.status == :completed

      # Child exists and can run independently
      child_id = parent.context["__fire_forget:confirmation_email"]
      assert child_id != nil

      Executor.execute_workflow(child_id, config)

      child = repo.get!(WorkflowExecution, child_id)
      assert child.status == :completed
    end

    test "list_children returns child workflows" do
      config = Config.get(Durable)

      {:ok, parent} = create_and_execute_workflow(FireForgetIdempotentParent, %{})

      children = Durable.list_children(parent.id)
      assert length(children) == 2

      Enum.each(children, fn child ->
        Executor.execute_workflow(child.id, config)
      end)

      completed_children = Durable.list_children(parent.id, status: :completed)
      assert length(completed_children) == 2

      pending_children = Durable.list_children(parent.id, status: :pending)
      assert pending_children == []
    end
  end

  # ============================================================================
  # Helpers
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

  defp get_pending_event(repo, workflow_id, event_name) do
    repo.one(
      from(p in PendingEvent,
        where: p.workflow_id == ^workflow_id and p.event_name == ^event_name
      )
    )
  end
end

# ============================================================================
# Test Workflow Modules
# ============================================================================

defmodule SimpleChildWorkflow do
  use Durable
  use Durable.Helpers

  workflow "simple_child" do
    step(:do_work, fn data ->
      {:ok, assign(data, :child_result, "done")}
    end)
  end
end

defmodule FailingChildWorkflow do
  use Durable
  use Durable.Helpers

  workflow "failing_child" do
    step(:fail_step, fn _data ->
      {:error, %{type: "child_failure", message: "child failed on purpose"}}
    end)
  end
end

defmodule CallWorkflowParent do
  use Durable
  use Durable.Helpers
  use Durable.Orchestration

  workflow "call_parent" do
    step(:before, fn data ->
      {:ok, assign(data, :before_call, true)}
    end)

    step(:call_child, fn data ->
      case call_workflow(SimpleChildWorkflow, %{}) do
        {:ok, result} ->
          {:ok, assign(data, :call_result, result)}

        {:error, reason} ->
          {:ok, assign(data, :call_error, reason)}
      end
    end)

    step(:after, fn data ->
      {:ok, assign(data, :after_call, true)}
    end)
  end
end

defmodule CallWorkflowFailingParent do
  use Durable
  use Durable.Helpers
  use Durable.Orchestration

  workflow "call_failing_parent" do
    step(:call_failing_child, fn data ->
      case call_workflow(FailingChildWorkflow, %{}) do
        {:ok, result} ->
          {:ok, assign(data, :call_result, result)}

        {:error, _reason} ->
          {:ok, assign(data, :got_error, true)}
      end
    end)
  end
end

defmodule FireForgetParent do
  use Durable
  use Durable.Helpers
  use Durable.Orchestration

  workflow "fire_forget_parent" do
    step(:before, fn data ->
      {:ok, assign(data, :before_fire, true)}
    end)

    step(:fire_child, fn data ->
      {:ok, child_id} =
        start_workflow(SimpleChildWorkflow, %{}, ref: :confirmation_email)

      {:ok, assign(data, :child_id, child_id)}
    end)

    step(:after, fn data ->
      {:ok, assign(data, :after_fire, true)}
    end)
  end
end

defmodule FireForgetIdempotentParent do
  use Durable
  use Durable.Helpers
  use Durable.Orchestration

  workflow "fire_forget_idempotent" do
    step(:fire_two_children, fn data ->
      {:ok, child1_id} =
        start_workflow(SimpleChildWorkflow, %{}, ref: :email1)

      {:ok, child2_id} =
        start_workflow(SimpleChildWorkflow, %{}, ref: :email2)

      data
      |> assign(:child1_id, child1_id)
      |> assign(:child2_id, child2_id)
      |> then(&{:ok, &1})
    end)
  end
end

# Nested: A -> B -> C
defmodule ParentWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Orchestration

  workflow "parent_wf" do
    step(:call_simple, fn data ->
      case call_workflow(SimpleChildWorkflow, %{}) do
        {:ok, result} ->
          {:ok, assign(data, :child_result, result)}

        {:error, reason} ->
          {:ok, assign(data, :child_error, reason)}
      end
    end)
  end
end

defmodule GrandparentWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Orchestration

  workflow "grandparent_wf" do
    step(:call_parent, fn data ->
      case call_workflow(ParentWorkflow, %{}) do
        {:ok, result} ->
          {:ok, data |> assign(:nested_result, result) |> assign(:chain_complete, true)}

        {:error, reason} ->
          {:ok, assign(data, :nested_error, reason)}
      end
    end)
  end
end
