defmodule Mix.Tasks.Durable.CancelTest do
  use Durable.DataCase, async: false

  alias Durable.Storage.Schemas.WorkflowExecution
  alias Mix.Tasks.Durable.Cancel, as: CancelTask

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  describe "run/1" do
    test "cancels a pending workflow" do
      execution = insert_execution(status: :pending)

      CancelTask.run([execution.id])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "cancelled"

      updated = Durable.TestRepo.get!(WorkflowExecution, execution.id)
      assert updated.status == :cancelled
    end

    test "cancels with a reason" do
      execution = insert_execution(status: :running)

      CancelTask.run([execution.id, "--reason", "Testing cancellation"])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "cancelled"

      updated = Durable.TestRepo.get!(WorkflowExecution, execution.id)
      assert updated.status == :cancelled
      assert updated.error["message"] == "Testing cancellation"
    end

    test "shows error for non-existent workflow" do
      fake_id = Ecto.UUID.generate()

      CancelTask.run([fake_id])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "not found"
    end

    test "shows error for already completed workflow" do
      execution = insert_execution(status: :completed)

      CancelTask.run([execution.id])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "already completed"
    end

    test "shows usage when no workflow ID provided" do
      CancelTask.run([])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Usage:"
    end
  end

  # Helpers

  defp insert_execution(opts) do
    attrs = %{
      workflow_module: "TestWorkflow",
      workflow_name: "test",
      status: Keyword.get(opts, :status, :pending),
      queue: "default",
      priority: 0,
      input: %{},
      context: %{}
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> Durable.TestRepo.insert!()
  end
end
