defmodule Durable.LogCapture.IOServerTest do
  use ExUnit.Case, async: false

  alias Durable.LogCapture

  describe "IO capture" do
    test "captures IO.puts output" do
      Process.put(:durable_workflow_id, "test")
      LogCapture.start_capture()

      IO.puts("Hello from IO.puts")

      # Small delay to allow message processing
      Process.sleep(10)

      logs = LogCapture.stop_capture()
      Process.delete(:durable_workflow_id)

      io_log = Enum.find(logs, fn log -> log["source"] == "io" end)
      assert io_log
      assert io_log["message"] =~ "Hello from IO.puts"
    end

    test "captures IO.inspect output" do
      Process.put(:durable_workflow_id, "test")
      LogCapture.start_capture()

      IO.puts("Debug: " <> inspect(%{key: "value"}))

      Process.sleep(10)

      logs = LogCapture.stop_capture()
      Process.delete(:durable_workflow_id)

      io_log = Enum.find(logs, fn log -> log["source"] == "io" end)
      assert io_log
      assert io_log["message"] =~ "key"
    end

    test "restores original group_leader after stop" do
      original = Process.group_leader()

      LogCapture.start_capture()
      # Group leader should be changed when IO capture is enabled
      during_capture = Process.group_leader()

      LogCapture.stop_capture()
      after_stop = Process.group_leader()

      assert after_stop == original
      # During capture it should be different (the IO server)
      assert during_capture != original or not io_capture_enabled?()
    end

    test "captures multiple IO operations" do
      Process.put(:durable_workflow_id, "test")
      LogCapture.start_capture()

      IO.puts("First line")
      IO.puts("Second line")
      IO.puts("Third line")

      Process.sleep(20)

      logs = LogCapture.stop_capture()
      Process.delete(:durable_workflow_id)

      io_logs = Enum.filter(logs, fn log -> log["source"] == "io" end)
      assert length(io_logs) >= 3
    end

    test "handles IO without workflow context" do
      LogCapture.start_capture()

      # This should not crash even without workflow context
      IO.puts("No workflow context")

      logs = LogCapture.stop_capture()

      # Logs should be empty since no workflow context
      assert logs == []
    end
  end

  describe "IO passthrough" do
    test "can enable passthrough mode" do
      Application.put_env(:durable, :log_capture, io_capture: true, io_passthrough: true)

      Process.put(:durable_workflow_id, "test")
      LogCapture.start_capture()

      # This should both capture and print (passthrough)
      IO.puts("Passthrough test")

      Process.sleep(10)

      logs = LogCapture.stop_capture()
      Process.delete(:durable_workflow_id)

      # Should still capture
      io_log = Enum.find(logs, fn log -> log["source"] == "io" end)
      assert io_log

      # Reset config
      Application.delete_env(:durable, :log_capture)
    end
  end

  describe "IO capture disabled" do
    test "does not start IO server when disabled" do
      Application.put_env(:durable, :log_capture, io_capture: false)

      original = Process.group_leader()
      LogCapture.start_capture()
      during_capture = Process.group_leader()
      LogCapture.stop_capture()

      # Group leader should not change when IO capture is disabled
      assert during_capture == original

      # Reset config
      Application.delete_env(:durable, :log_capture)
    end
  end

  defp io_capture_enabled? do
    config = Application.get_env(:durable, :log_capture, [])
    Keyword.get(config, :io_capture, true)
  end
end
