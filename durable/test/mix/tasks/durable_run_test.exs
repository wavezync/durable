defmodule Mix.Tasks.Durable.RunTest do
  use Durable.DataCase, async: false

  alias Mix.Tasks.Durable.Run, as: RunTask

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  describe "run/1" do
    test "starts a valid workflow" do
      RunTask.run(["Durable.TestWorkflows.SimpleWorkflow"])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "Workflow started:"
    end

    test "starts workflow with JSON input" do
      RunTask.run([
        "Durable.TestWorkflows.SimpleWorkflow",
        "--input",
        ~s({"key": "value"})
      ])

      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "Workflow started:"
    end

    test "shows error for non-existent module" do
      RunTask.run(["NonExistent.Module"])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "not found"
    end

    test "shows error for non-workflow module" do
      RunTask.run(["Enum"])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "not a Durable workflow"
    end

    test "shows error for invalid JSON input" do
      RunTask.run([
        "Durable.TestWorkflows.SimpleWorkflow",
        "--input",
        "not json"
      ])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Invalid JSON"
    end

    test "shows error for JSON array input" do
      RunTask.run([
        "Durable.TestWorkflows.SimpleWorkflow",
        "--input",
        "[1, 2, 3]"
      ])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "must be a JSON object"
    end

    test "shows usage when no module provided" do
      RunTask.run([])

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Usage:"
    end
  end
end
