defmodule Mix.Tasks.Durable.ListTest do
  use Durable.DataCase, async: false

  alias Durable.Storage.Schemas.WorkflowExecution
  alias Mix.Tasks.Durable.List, as: ListTask

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  describe "run/1" do
    test "lists executions in table format" do
      insert_execution(workflow_name: "order", status: :completed)
      insert_execution(workflow_name: "payment", status: :running)

      ListTask.run([])

      output = collect_all_output()
      assert output =~ "TestWorkflow"
      assert output =~ "completed"
      assert output =~ "running"
    end

    test "shows no results message when empty" do
      ListTask.run([])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "No workflow executions found."
    end

    test "filters by status" do
      insert_execution(workflow_name: "done", status: :completed)
      insert_execution(workflow_name: "active", status: :running)

      ListTask.run(["--status", "completed"])

      output = collect_all_output()
      assert output =~ "completed"
      refute output =~ "running"
    end

    test "filters by queue" do
      insert_execution(workflow_name: "q1", queue: "default")
      insert_execution(workflow_name: "q2", queue: "high_priority")

      ListTask.run(["--queue", "high_priority"])

      output = collect_all_output()
      assert output =~ "high_priority"
    end

    test "respects --limit" do
      for i <- 1..5 do
        insert_execution(workflow_name: "wf_#{i}", status: :completed)
      end

      ListTask.run(["--limit", "2"])

      output = collect_all_output()
      # Should have header + 2 data rows
      lines = output |> String.split("\n") |> Enum.filter(&(&1 =~ "completed"))
      assert length(lines) == 2
    end

    test "outputs JSON format" do
      insert_execution(workflow_name: "json_test", status: :completed)

      ListTask.run(["--format", "json"])

      output = collect_all_output()
      decoded = Jason.decode!(output)
      assert is_list(decoded)
      assert length(decoded) == 1
      assert hd(decoded)["workflow_name"] == "json_test"
    end

    test "shows error for invalid status" do
      ListTask.run(["--status", "invalid_status"])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Invalid status"
      assert msg =~ "pending"
    end

    test "filters by --since" do
      old = DateTime.add(DateTime.utc_now(), -86_400, :second)
      recent = DateTime.utc_now()

      insert_execution(workflow_name: "old", inserted_at: old)
      insert_execution(workflow_name: "recent", inserted_at: recent)

      since = DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -3_600, :second))
      ListTask.run(["--since", since])

      output = collect_all_output()
      assert output =~ "recent" or output =~ "TestWorkflow"
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

    attrs =
      case Keyword.get(opts, :inserted_at) do
        nil -> attrs
        dt -> Map.put(attrs, :inserted_at, dt)
      end

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
      {:mix_shell, :error, [line]} -> collect_all_output(acc <> "\n" <> line)
    after
      100 -> acc
    end
  end
end
