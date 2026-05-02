defmodule Durable.LogCapture.HandlerTest do
  use ExUnit.Case, async: false

  alias Durable.LogCapture
  alias Durable.LogCapture.Handler

  require Logger

  describe "attach/0 and detach/0" do
    test "handler can be attached" do
      # Handler should already be attached from application start
      assert Handler.attached?()
    end

    test "attach is idempotent" do
      # Should not fail if called multiple times
      assert :ok = Handler.attach()
      assert :ok = Handler.attach()
      assert Handler.attached?()
    end

    test "detach removes handler" do
      # Detach
      assert :ok = Handler.detach()
      refute Handler.attached?()

      # Re-attach for other tests
      assert :ok = Handler.attach()
      assert Handler.attached?()
    end
  end

  describe "log capture in workflow context" do
    setup do
      # Ensure handler is attached
      Handler.attach()
      :ok
    end

    test "captures Logger.info in workflow context" do
      Process.put(:durable_workflow_id, "test-workflow")
      LogCapture.start_capture()

      Logger.info("Test log message from handler test")

      # Allow async log processing (Logger can be async)
      Process.sleep(100)

      logs = LogCapture.stop_capture()
      Process.delete(:durable_workflow_id)

      assert Enum.any?(logs, fn log ->
               log["message"] =~ "Test log message from handler test"
             end)
    end

    test "captures Logger.warning in workflow context" do
      Process.put(:durable_workflow_id, "test-workflow")
      LogCapture.start_capture()

      Logger.warning("Warning message")
      Process.sleep(100)

      logs = LogCapture.stop_capture()
      Process.delete(:durable_workflow_id)

      warning_log = Enum.find(logs, fn log -> log["level"] == "warning" end)
      assert warning_log
      assert warning_log["message"] =~ "Warning message"
    end

    test "captures Logger.error in workflow context" do
      Process.put(:durable_workflow_id, "test-workflow")
      LogCapture.start_capture()

      Logger.error("Error message")
      Process.sleep(100)

      logs = LogCapture.stop_capture()
      Process.delete(:durable_workflow_id)

      error_log = Enum.find(logs, fn log -> log["level"] == "error" end)
      assert error_log
      assert error_log["message"] =~ "Error message"
    end

    test "does not capture logs outside workflow context" do
      LogCapture.start_capture()

      Logger.info("Outside workflow")
      Process.sleep(100)

      logs = LogCapture.stop_capture()

      # Should be empty because no workflow context
      assert logs == []
    end

    test "captures multiple log levels" do
      Process.put(:durable_workflow_id, "test-workflow")
      LogCapture.start_capture()

      Logger.info("Info message")
      Logger.warning("Warning message")
      Logger.error("Error message")
      Process.sleep(100)

      logs = LogCapture.stop_capture()
      Process.delete(:durable_workflow_id)

      levels = logs |> Enum.map(& &1["level"]) |> Enum.uniq() |> Enum.sort()
      assert "info" in levels
      assert "warning" in levels
      assert "error" in levels
    end
  end
end
