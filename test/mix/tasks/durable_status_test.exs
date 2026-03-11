defmodule Mix.Tasks.Durable.StatusTest do
  use Durable.DataCase, async: false

  alias Durable.Storage.Schemas.WorkflowExecution
  alias Mix.Tasks.Durable.Status, as: StatusTask

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  describe "run/1" do
    test "shows queue status and workflow summary with empty database" do
      StatusTask.run([])

      assert_received {:mix_shell, :info, [queue_header]}
      assert queue_header =~ "Queue Status"

      # Should show the default queue
      assert_receive {:mix_shell, :info, [queue_line]}
      assert queue_line =~ "Queue" or queue_line =~ "default"

      # Should eventually show workflow summary
      collect_and_assert_output("Workflow Summary")
    end

    test "shows counts for seeded data" do
      insert_execution(status: :completed)
      insert_execution(status: :completed)
      insert_execution(status: :failed)
      insert_execution(status: :running)

      StatusTask.run([])

      output = collect_all_output()
      assert output =~ "completed"
      assert output =~ "2"
      assert output =~ "failed"
      assert output =~ "running"
    end

    test "shows zero when no executions exist for a status" do
      StatusTask.run([])

      output = collect_all_output()
      assert output =~ "Workflow Summary"
      assert output =~ "No workflow executions found."
    end
  end

  # Helpers

  defp insert_execution(opts) do
    attrs = %{
      workflow_module: "TestWorkflow",
      workflow_name: Keyword.get(opts, :workflow_name, "test"),
      status: Keyword.get(opts, :status, :pending),
      queue: Keyword.get(opts, :queue, "default"),
      priority: 0,
      input: %{},
      context: %{}
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> Durable.TestRepo.insert!()
  end

  defp collect_all_output do
    collect_all_output("")
  end

  defp collect_all_output(acc) do
    receive do
      {:mix_shell, :info, [line]} -> collect_all_output(acc <> "\n" <> line)
    after
      100 -> acc
    end
  end

  defp collect_and_assert_output(expected) do
    output = collect_all_output()
    assert output =~ expected
  end
end
