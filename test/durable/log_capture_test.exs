defmodule Durable.LogCaptureTest do
  use ExUnit.Case, async: false

  alias Durable.LogCapture

  require Logger

  describe "start_capture/0 and stop_capture/0" do
    test "initializes empty log buffer" do
      LogCapture.start_capture()
      assert LogCapture.get_logs() == []
      LogCapture.stop_capture()
    end

    test "returns captured logs on stop" do
      # Set workflow context so handler captures logs
      Process.put(:durable_workflow_id, "test-workflow-id")

      LogCapture.start_capture()
      LogCapture.add_log(:info, "test message", %{})
      logs = LogCapture.stop_capture()

      Process.delete(:durable_workflow_id)

      assert length(logs) == 1
      assert hd(logs)["message"] == "test message"
      assert hd(logs)["level"] == "info"
    end

    test "clears buffer after stop" do
      LogCapture.start_capture()
      LogCapture.add_log(:info, "test", %{})
      LogCapture.stop_capture()

      # Starting again should have empty buffer
      LogCapture.start_capture()
      assert LogCapture.get_logs() == []
      LogCapture.stop_capture()
    end
  end

  describe "add_log/3" do
    setup do
      LogCapture.start_capture()
      on_exit(fn -> LogCapture.stop_capture() end)
    end

    test "adds log entry with correct structure" do
      LogCapture.add_log(:warning, "test warning", %{request_id: "abc"})
      [log] = LogCapture.get_logs()

      assert log.level == "warning"
      assert log.message == "test warning"
      assert log.metadata.request_id == "abc"
      assert log.source == "logger"
      assert log.timestamp
    end

    test "adds multiple logs in order" do
      LogCapture.add_log(:info, "first", %{})
      LogCapture.add_log(:info, "second", %{})
      LogCapture.add_log(:info, "third", %{})

      logs = LogCapture.get_logs()
      messages = Enum.map(logs, & &1.message)

      assert messages == ["first", "second", "third"]
    end

    test "respects max_log_entries limit" do
      # Add more logs than the limit
      Application.put_env(:durable, :log_capture, max_log_entries: 3)

      for i <- 1..10 do
        LogCapture.add_log(:info, "message #{i}", %{})
      end

      logs = LogCapture.get_logs()
      assert length(logs) == 3

      # Reset config
      Application.delete_env(:durable, :log_capture)
    end

    test "filters by log level" do
      Application.put_env(:durable, :log_capture, levels: [:warning, :error])

      LogCapture.add_log(:debug, "debug", %{})
      LogCapture.add_log(:info, "info", %{})
      LogCapture.add_log(:warning, "warning", %{})
      LogCapture.add_log(:error, "error", %{})

      logs = LogCapture.get_logs()
      levels = Enum.map(logs, & &1.level)

      assert levels == ["warning", "error"]

      # Reset config
      Application.delete_env(:durable, :log_capture)
    end

    test "truncates long messages" do
      Application.put_env(:durable, :log_capture, max_message_length: 50)

      long_message = String.duplicate("a", 100)
      LogCapture.add_log(:info, long_message, %{})

      [log] = LogCapture.get_logs()
      assert String.length(log.message) < 100
      assert String.ends_with?(log.message, "... [truncated]")

      # Reset config
      Application.delete_env(:durable, :log_capture)
    end
  end

  describe "in_workflow_context?/0" do
    test "returns false when not in workflow" do
      refute LogCapture.in_workflow_context?()
    end

    test "returns true when workflow_id is set" do
      Process.put(:durable_workflow_id, "test-id")
      assert LogCapture.in_workflow_context?()
      Process.delete(:durable_workflow_id)
    end
  end

  describe "add_io_log/1" do
    setup do
      LogCapture.start_capture()
      on_exit(fn -> LogCapture.stop_capture() end)
    end

    test "adds IO output as log entry" do
      LogCapture.add_io_log("IO output message")
      [log] = LogCapture.get_logs()

      assert log.message == "IO output message"
      assert log.source == "io"
      assert log.level == "info"
    end

    test "ignores empty strings" do
      LogCapture.add_io_log("")
      assert LogCapture.get_logs() == []
    end
  end

  describe "format_logs_for_storage/1" do
    test "converts to string keys for JSON storage" do
      Process.put(:durable_workflow_id, "test")
      LogCapture.start_capture()
      LogCapture.add_log(:info, "test", %{})
      logs = LogCapture.stop_capture()
      Process.delete(:durable_workflow_id)

      assert is_list(logs)
      [log] = logs

      # Should have string keys for JSON storage
      assert Map.has_key?(log, "timestamp")
      assert Map.has_key?(log, "level")
      assert Map.has_key?(log, "message")
      assert Map.has_key?(log, "source")
      assert Map.has_key?(log, "metadata")
    end
  end
end
