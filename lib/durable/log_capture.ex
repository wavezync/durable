defmodule Durable.LogCapture do
  @moduledoc """
  Captures Logger output and IO operations during workflow step execution.

  Uses process dictionary key `:durable_logs` for buffering log entries.
  Optionally replaces group_leader for IO.puts/IO.inspect capture.

  ## Usage

  This module is used internally by `Durable.Executor.StepRunner` to capture
  logs during step execution:

      Durable.LogCapture.start_capture()

      # Step execution happens here - Logger calls are captured
      Logger.info("Processing order")
      IO.puts("Debug output")

      logs = Durable.LogCapture.stop_capture()
      # => [%{timestamp: ..., level: "info", message: "Processing order", ...}, ...]

  ## Configuration

      config :durable,
        log_capture: [
          enabled: true,
          levels: [:debug, :info, :warning, :error],
          io_capture: true,
          io_passthrough: false,
          max_log_entries: 1000,
          max_message_length: 10_000,
          metadata_filter: [:request_id, :user_id, :module, :function, :line]
        ]
  """

  @logs_key :durable_logs
  @original_gl_key :durable_original_group_leader
  @io_server_key :durable_io_capture_pid

  @doc """
  Starts log capture for the current process.

  Initializes the log buffer in the process dictionary and optionally
  starts IO capture by replacing the group_leader.

  This should be called before step execution begins.
  """
  @spec start_capture() :: :ok
  def start_capture do
    config = get_config()

    if Keyword.get(config, :enabled, true) do
      # Initialize log buffer
      Process.put(@logs_key, [])

      # Start IO capture if enabled
      if Keyword.get(config, :io_capture, true) do
        start_io_capture(config)
      end
    end

    :ok
  end

  @doc """
  Stops log capture and returns the captured logs.

  Restores the original group_leader if IO capture was active,
  stops the IO server process, and returns the formatted logs.

  Returns an empty list if capture was not started or is disabled.
  """
  @spec stop_capture() :: list(map())
  def stop_capture do
    config = get_config()

    if Keyword.get(config, :enabled, true) do
      # Drain any pending IO log messages first
      drain_io_logs(config)

      # Stop IO capture if it was started
      stop_io_capture()

      # Get and format logs
      logs = get_logs()
      clear_logs()

      format_logs_for_storage(logs)
    else
      []
    end
  end

  @doc """
  Adds an IO output entry to the log buffer.

  Called when processing IO log messages from the IO server.
  """
  @spec add_io_log(String.t()) :: :ok
  def add_io_log(output) when is_binary(output) and byte_size(output) > 0 do
    add_log(:info, output, %{source: :io})
  end

  def add_io_log(_), do: :ok

  @doc """
  Adds a log entry to the buffer.

  Called by the Logger handler when a log event occurs in workflow context.
  Respects the `max_log_entries` configuration limit.

  ## Parameters

    * `level` - The log level atom (:debug, :info, :warning, :error)
    * `message` - The log message string
    * `metadata` - Metadata map from the Logger event

  """
  @spec add_log(atom(), String.t(), map()) :: :ok
  def add_log(level, message, metadata) do
    config = get_config()
    max_entries = Keyword.get(config, :max_log_entries, 1000)
    allowed_levels = Keyword.get(config, :levels, [:debug, :info, :warning, :error])

    # Check if this level should be captured
    if level in allowed_levels do
      logs = Process.get(@logs_key, [])

      if length(logs) < max_entries do
        entry = build_log_entry(level, message, metadata, config)
        Process.put(@logs_key, [entry | logs])
      end
    end

    :ok
  end

  @doc """
  Checks if the current process is executing within a workflow context.

  Returns `true` if `:durable_workflow_id` is set in the process dictionary,
  indicating that log capture should be active.
  """
  @spec in_workflow_context?() :: boolean()
  def in_workflow_context? do
    Process.get(:durable_workflow_id) != nil
  end

  @doc """
  Returns the current log buffer contents.

  Logs are returned in chronological order (oldest first).
  """
  @spec get_logs() :: list(map())
  def get_logs do
    Process.get(@logs_key, []) |> Enum.reverse()
  end

  @doc """
  Clears the log buffer.
  """
  @spec clear_logs() :: :ok
  def clear_logs do
    Process.delete(@logs_key)
    :ok
  end

  # Private functions

  defp start_io_capture(config) do
    original_leader = Process.group_leader()
    Process.put(@original_gl_key, original_leader)

    passthrough = Keyword.get(config, :io_passthrough, false)

    {:ok, io_server} =
      Durable.LogCapture.IOServer.start_link(
        original_leader: original_leader,
        passthrough: passthrough,
        parent_pid: self()
      )

    Process.put(@io_server_key, io_server)
    Process.group_leader(self(), io_server)

    :ok
  end

  defp stop_io_capture do
    # Restore original group leader
    case Process.get(@original_gl_key) do
      nil ->
        :ok

      original_leader ->
        Process.group_leader(self(), original_leader)
        Process.delete(@original_gl_key)
    end

    # Stop IO server
    case Process.get(@io_server_key) do
      nil ->
        :ok

      io_server ->
        Durable.LogCapture.IOServer.stop(io_server)
        Process.delete(@io_server_key)
    end

    :ok
  end

  defp drain_io_logs(config) do
    # Process any pending IO log messages from the IO server
    receive do
      {:durable_io_log, output} ->
        add_io_log(output)
        drain_io_logs(config)
    after
      0 -> :ok
    end
  end

  defp build_log_entry(level, message, metadata, config) do
    max_message_length = Keyword.get(config, :max_message_length, 10_000)
    source = Map.get(metadata, :source, :logger)

    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      level: Atom.to_string(level),
      message: truncate_message(message, max_message_length),
      source: to_string(source),
      metadata: filter_metadata(metadata, config)
    }
  end

  defp truncate_message(msg, max_length) when is_binary(msg) do
    if byte_size(msg) > max_length do
      String.slice(msg, 0, max_length) <> "... [truncated]"
    else
      msg
    end
  end

  defp truncate_message(msg, max_length) do
    truncate_message(to_string(msg), max_length)
  end

  defp filter_metadata(metadata, config) do
    allowed_keys = Keyword.get(config, :metadata_filter, [:request_id, :user_id, :module, :function, :line])

    # Remove internal keys that shouldn't be stored
    internal_keys = [:source, :gl, :pid, :time, :mfa, :file, :domain, :erl_level]

    metadata
    |> Map.drop(internal_keys)
    |> Map.take(allowed_keys)
    |> Map.new(fn {k, v} -> {k, serialize_value(v)} end)
  end

  defp serialize_value(v) when is_binary(v), do: v
  defp serialize_value(v) when is_atom(v), do: Atom.to_string(v)
  defp serialize_value(v) when is_number(v), do: v
  defp serialize_value(v) when is_boolean(v), do: v
  defp serialize_value(nil), do: nil
  defp serialize_value(v), do: inspect(v)

  defp format_logs_for_storage(logs) do
    # Convert string keys to atoms for consistency with schema
    Enum.map(logs, fn log ->
      %{
        "timestamp" => log.timestamp,
        "level" => log.level,
        "message" => log.message,
        "source" => log.source,
        "metadata" => log.metadata
      }
    end)
  end

  defp get_config do
    Application.get_env(:durable, :log_capture, [])
  end
end
