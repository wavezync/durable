defmodule Mix.Tasks.Durable.CleanupTest do
  use Durable.DataCase, async: false

  alias Durable.Storage.Schemas.WorkflowExecution
  alias Mix.Tasks.Durable.Cleanup, as: CleanupTask

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  describe "run/1" do
    test "dry run counts without deleting" do
      insert_execution(status: :completed, days_ago: 31)
      insert_execution(status: :completed, days_ago: 31)

      CleanupTask.run(["--older-than", "30d", "--dry-run"])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "Dry run"
      assert msg =~ "2"

      # Verify nothing was deleted
      assert Durable.TestRepo.aggregate(WorkflowExecution, :count) == 2
    end

    test "deletes old completed and failed executions" do
      old_completed = insert_execution(status: :completed, days_ago: 31)
      old_failed = insert_execution(status: :failed, days_ago: 31)
      _recent = insert_execution(status: :completed, days_ago: 1)
      _running = insert_execution(status: :running, days_ago: 31)

      CleanupTask.run(["--older-than", "30d"])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "Deleted"
      assert msg =~ "2"

      # Verify old completed/failed are gone
      assert Durable.TestRepo.get(WorkflowExecution, old_completed.id) == nil
      assert Durable.TestRepo.get(WorkflowExecution, old_failed.id) == nil

      # Verify recent and running are preserved
      assert Durable.TestRepo.aggregate(WorkflowExecution, :count) == 2
    end

    test "respects --status filter" do
      insert_execution(status: :completed, days_ago: 31)
      insert_execution(status: :failed, days_ago: 31)

      CleanupTask.run(["--older-than", "30d", "--status", "completed"])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "Deleted"
      assert msg =~ "1"

      # Failed should still exist
      assert Durable.TestRepo.aggregate(WorkflowExecution, :count) == 1
    end

    test "requires --older-than flag" do
      CleanupTask.run([])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "--older-than is required"
    end

    test "preserves recent data" do
      insert_execution(status: :completed, days_ago: 1)

      CleanupTask.run(["--older-than", "30d"])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "Deleted"
      assert msg =~ "0"

      assert Durable.TestRepo.aggregate(WorkflowExecution, :count) == 1
    end

    test "handles hour duration format" do
      insert_execution(status: :completed, days_ago: 2)

      CleanupTask.run(["--older-than", "24h"])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "Deleted"
      assert msg =~ "1"
    end

    test "handles minute duration format" do
      insert_execution(status: :completed, days_ago: 1)

      CleanupTask.run(["--older-than", "60m"])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "Deleted"
      assert msg =~ "1"
    end
  end

  # Helpers

  defp insert_execution(opts) do
    days_ago = Keyword.get(opts, :days_ago, 0)
    inserted_at = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)

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
    |> Ecto.Changeset.force_change(:inserted_at, inserted_at)
    |> Durable.TestRepo.insert!()
  end
end
