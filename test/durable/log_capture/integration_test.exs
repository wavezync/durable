defmodule Durable.LogCapture.IntegrationTest do
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  import Ecto.Query

  require Logger

  # These modules are defined at compile time so they can be looked up by name
  # The module name must match what's stored in workflow_module field

  describe "workflow step log capture" do
    test "captures Logger output in workflow step" do
      # Create and execute workflow directly
      {:ok, execution} = create_and_execute_workflow(LoggingTestWorkflow, %{})

      # Wait for async logger
      Process.sleep(100)

      repo = Config.get(Durable).repo

      # Query the step execution
      step_exec =
        repo.one(
          from(s in StepExecution,
            where: s.workflow_id == ^execution.id and s.step_name == "log_various_levels"
          )
        )

      assert step_exec != nil, "Step execution should be created"
      assert step_exec.status == :completed
      assert is_list(step_exec.logs)
      assert step_exec.logs != [], "expected Logger calls to be captured in step.logs"

      messages = Enum.map_join(step_exec.logs, " ", & &1["message"])
      assert messages =~ "message" or messages =~ "workflow"
    end

    test "captures IO output in workflow step" do
      {:ok, execution} = create_and_execute_workflow(IOLoggingTestWorkflow, %{})

      Process.sleep(100)

      repo = Config.get(Durable).repo

      step_exec =
        repo.one(
          from(s in StepExecution,
            where: s.workflow_id == ^execution.id and s.step_name == "io_output"
          )
        )

      assert step_exec != nil, "Step execution should be created"
      assert step_exec.status == :completed
      assert is_list(step_exec.logs)
      assert step_exec.logs != [], "expected IO output to be captured in step.logs"

      io_logs = Enum.filter(step_exec.logs, fn log -> log["source"] == "io" end)
      assert io_logs != [], "expected at least one log entry with source=io"

      io_messages = Enum.map_join(io_logs, " ", & &1["message"])
      assert io_messages =~ "IO" or io_messages =~ "output"
    end

    test "each step has isolated logs" do
      {:ok, execution} = create_and_execute_workflow(MultiStepLoggingTestWorkflow, %{})

      Process.sleep(100)

      repo = Config.get(Durable).repo

      step_execs =
        repo.all(
          from(s in StepExecution,
            where: s.workflow_id == ^execution.id,
            order_by: [asc: s.inserted_at]
          )
        )

      assert length(step_execs) == 2

      [first, second] = step_execs

      assert first.logs != [], "first step should have captured logs"
      assert second.logs != [], "second step should have captured logs"

      first_messages = Enum.map_join(first.logs, " ", & &1["message"])
      second_messages = Enum.map_join(second.logs, " ", & &1["message"])

      # Logs must be isolated: the first step's buffer must not contain the
      # second step's log message, and vice versa.
      refute first_messages =~ "Second step log",
             "first step's logs leaked the second step's message"

      refute second_messages =~ "First step log",
             "second step's logs leaked the first step's message"
    end
  end

  describe "log entry structure" do
    test "log entries have required fields" do
      {:ok, execution} = create_and_execute_workflow(LoggingTestWorkflow, %{})

      Process.sleep(100)

      repo = Config.get(Durable).repo

      step_exec =
        repo.one(
          from(s in StepExecution,
            where: s.workflow_id == ^execution.id and s.step_name == "log_various_levels"
          )
        )

      assert step_exec != nil
      assert step_exec.logs != [], "expected at least one captured log entry"

      [log | _] = step_exec.logs

      assert Map.has_key?(log, "timestamp")
      assert Map.has_key?(log, "level")
      assert Map.has_key?(log, "message")
      assert Map.has_key?(log, "source")
      assert Map.has_key?(log, "metadata")
    end

    test "timestamp is ISO8601 format" do
      {:ok, execution} = create_and_execute_workflow(LoggingTestWorkflow, %{})

      Process.sleep(100)

      repo = Config.get(Durable).repo

      step_exec =
        repo.one(
          from(s in StepExecution,
            where: s.workflow_id == ^execution.id and s.step_name == "log_various_levels"
          )
        )

      assert step_exec != nil
      assert step_exec.logs != [], "expected at least one captured log entry"

      [log | _] = step_exec.logs
      assert {:ok, _, _} = DateTime.from_iso8601(log["timestamp"])
    end
  end

  # Helper to create and execute a workflow synchronously
  defp create_and_execute_workflow(module, input) do
    config = Config.get(Durable)
    repo = config.repo

    # Get workflow definition
    {:ok, workflow_def} = module.__default_workflow__()

    # Create execution record
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

    # Execute directly
    Executor.execute_workflow(execution.id, config)

    # Reload to get updated status
    {:ok, repo.get!(WorkflowExecution, execution.id)}
  end
end

# Define test workflow modules at top level so they can be looked up
defmodule LoggingTestWorkflow do
  use Durable
  use Durable.Helpers

  require Logger

  workflow "logging_test" do
    step(:log_various_levels, fn data ->
      Logger.info("Info message from workflow")
      Logger.warning("Warning message from workflow")

      {:ok, assign(data, :logged, true)}
    end)
  end
end

defmodule IOLoggingTestWorkflow do
  use Durable
  use Durable.Helpers

  workflow "io_logging_test" do
    step(:io_output, fn data ->
      IO.puts("IO.puts output from workflow")

      {:ok, assign(data, :io_logged, true)}
    end)
  end
end

defmodule MultiStepLoggingTestWorkflow do
  use Durable
  use Durable.Helpers

  require Logger

  workflow "multi_step_logging" do
    step(:first_step, fn data ->
      Logger.info("First step log")
      {:ok, assign(data, :step1, true)}
    end)

    step(:second_step, fn data ->
      Logger.info("Second step log")
      {:ok, assign(data, :step2, true)}
    end)
  end
end
