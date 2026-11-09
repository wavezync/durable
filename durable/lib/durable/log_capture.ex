defmodule Durable.LogCapture do
  @moduledoc """
  Captures Logger output and IO operations during workflow step execution.

  Uses process dictionary key `:durable_logs` for buffering log entries.
  Optionally replaces group_leader for IO.puts/IO.inspect capture.

  Lines are written to the step's row when the step ends, so a step that's
  killed or still running has none saved. The console is the copy of those.

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
          levels: [:warning, :error],
          io_capture: true,
          io_passthrough: false,
          max_log_entries: 1000,
          max_message_length: 10_000,
          metadata_filter: :all,
          console: true
        ]

    * `:levels` - which levels to save; every level by default.
    * `:metadata_filter` - which Logger metadata keys to save with each line:
      `:all` (the default) or a list of keys. Anything in Logger metadata is
      stored until the run is pruned, so narrow this if yours can hold secrets.
    * `:console` - set to `false` to keep the lines a step saves off the
      console. Takes effect when Durable starts.

  ## What's saved

  Each line is a map with `"timestamp"`, `"level"`, `"severity_number"`
  (OpenTelemetry's), `"message"`, `"source"`, `"metadata"`, `"trace_id"` (the
  top run's id) and `"span_id"` (from the attempt's row id).
  """

  alias Durable.LogCapture.IOServer

  require Logger

  # Process-dict flag: track whether we've already emitted the M-6
  # "metadata stringified" warning during the current step. Cleared in
  # start_capture/0.
  @warn_flag :durable_log_capture_warned

  @severity %{
    debug: 5,
    info: 9,
    notice: 10,
    warning: 13,
    error: 17,
    critical: 18,
    alert: 19,
    emergency: 21
  }

  # Logger's own fields and what a line stores at its top level.
  @internal_keys [
    :source,
    :gl,
    :pid,
    :time,
    :mfa,
    :file,
    :domain,
    :erl_level,
    :application,
    :crash_reason,
    :initial_call,
    :registered_name,
    :callers,
    :ancestors,
    :report_cb,
    :error_logger,
    :durable_internal,
    :durable_logged_at,
    :otel_trace_id,
    :otel_span_id,
    :otel_trace_flags
  ]

  @logs_key :durable_logs
  @owner_key :durable_log_owner
  @ids_key :durable_log_ids
  @step_body_key :durable_log_step_body
  @default_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
  @original_gl_key :durable_original_group_leader
  @io_server_key :durable_io_capture_pid

  @doc """
  Starts log capture for the current process.

  Initializes the log buffer in the process dictionary and optionally
  starts IO capture by replacing the group_leader.

  This should be called before step execution begins. `ids` holds the
  `:trace_id` and `:span_id` saved with each line.
  """
  @spec start_capture(map()) :: :ok
  def start_capture(ids \\ %{}) do
    config = get_config()

    if Keyword.get(config, :enabled, true) do
      # Initialize log buffer
      Process.put(@logs_key, [])
      Process.put(@owner_key, {self(), make_ref()})
      Process.put(@ids_key, ids)
      # Reset the per-step "warned about non-JSON metadata" flag so the
      # warning fires at most once per step (Bug M-6).
      Process.delete(@warn_flag)

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
      drain_task_logs(config)

      # Stop IO capture if it was started
      stop_io_capture()

      # Get and format logs
      logs = get_logs()
      clear_logs()

      logs |> Enum.sort_by(& &1.timestamp) |> format_logs_for_storage()
    else
      []
    end
  end

  @doc """
  Adds an IO output entry to the log buffer.

  Called when processing IO log messages from the IO server.
  """
  @spec add_io_log(String.t(), DateTime.t()) :: :ok
  def add_io_log(output, logged_at \\ DateTime.utc_now())

  def add_io_log(output, logged_at) when is_binary(output) and byte_size(output) > 0 do
    metadata = Map.merge(process_metadata(), %{source: :io, durable_logged_at: logged_at})
    add_log(:info, output, metadata)
  end

  def add_io_log(_output, _logged_at), do: :ok

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

    # Check if this level should be captured
    if level in levels(config) do
      record(build_log_entry(level, message, metadata, config), config)
    end

    :ok
  end

  # A bound Task's lines go to the step's process, which holds the buffer.
  defp record(entry, config) do
    case Process.get(@owner_key) do
      {owner, capture} when owner != self() -> send(owner, {:durable_task_log, capture, entry})
      _this_process -> append(entry, config)
    end

    :ok
  end

  defp append(entry, config) do
    if room?(config), do: Process.put(@logs_key, [entry | Process.get(@logs_key, [])])
  end

  defp room?(config) do
    length(Process.get(@logs_key, [])) < Keyword.get(config, :max_log_entries, 1000)
  end

  # Set on a step before it runs, so its printed lines carry the same details.
  defp process_metadata do
    case :logger.get_process_metadata() do
      :undefined -> %{}
      metadata -> metadata
    end
  end

  defp levels(config), do: Keyword.get(config, :levels, @default_levels)

  @doc false
  # Whether a line at this level, logged by the calling process, gets saved.
  @spec saves?(Logger.level()) :: boolean()
  def saves?(level) do
    config = get_config()

    case Process.get(@owner_key) do
      nil -> false
      {owner, _} when owner == self() -> level in levels(config) and room?(config)
      # A bound Task may outlive its step, so only its parent can say.
      _other_process -> Process.get(@step_body_key, false) and level in levels(config)
    end
  end

  @doc false
  # A step's body under a time limit runs in its own Task, but the step waits
  # for it, so unlike a bound Task its lines are sure to be saved.
  @spec mark_step_body() :: :ok
  def mark_step_body do
    Process.put(@step_body_key, true)
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
    Process.delete(@owner_key)
    Process.delete(@ids_key)
    Process.delete(@step_body_key)
    :ok
  end

  # Private functions

  defp start_io_capture(config) do
    original_leader = Process.group_leader()
    Process.put(@original_gl_key, original_leader)

    passthrough = Keyword.get(config, :io_passthrough, false)

    {:ok, io_server} =
      IOServer.start_link(
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
        IOServer.stop(io_server)
        Process.delete(@io_server_key)
    end

    :ok
  end

  defp drain_io_logs(config) do
    # Process any pending IO log messages from the IO server
    receive do
      {:durable_io_log, output, logged_at} ->
        add_io_log(output, logged_at)
        drain_io_logs(config)
    after
      0 -> :ok
    end
  end

  # A Task's line goes on the buffer of the attempt that bound it, not a later one.
  defp drain_task_logs(config) do
    {_owner, capture} = Process.get(@owner_key, {nil, nil})

    receive do
      {:durable_task_log, ^capture, entry} ->
        append(entry, config)
        drain_task_logs(config)

      {:durable_task_log, _earlier_attempt, _entry} ->
        drain_task_logs(config)
    after
      0 -> :ok
    end
  end

  defp build_log_entry(level, message, metadata, config) do
    max_message_length = Keyword.get(config, :max_message_length, 10_000)
    source = Map.get(metadata, :source, :logger)
    ids = Process.get(@ids_key, %{})

    %{
      timestamp:
        metadata |> Map.get(:durable_logged_at, DateTime.utc_now()) |> DateTime.to_iso8601(),
      level: Atom.to_string(level),
      severity_number: Map.get(@severity, level),
      message: truncate_message(message, max_message_length),
      source: source_name(source),
      metadata: filter_metadata(metadata, config),
      trace_id: Map.get(ids, :trace_id),
      span_id: Map.get(ids, :span_id)
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

  defp source_name(source) when is_atom(source) or is_binary(source), do: to_string(source)
  defp source_name(source), do: inspect(source)

  # Each value is held to the same limit as a message: without one, a few huge
  # values could make the row too big for Postgres and cost the step's result.
  defp filter_metadata(metadata, config) do
    max_length = Keyword.get(config, :max_message_length, 10_000)

    metadata
    |> Map.drop(@internal_keys)
    |> keep_keys(Keyword.get(config, :metadata_filter, :all))
    |> Map.new(fn {k, v} -> {k, limit_value(serialize_value(v), max_length)} end)
  end

  defp limit_value(value, max_length) when is_binary(value),
    do: truncate_message(value, max_length)

  defp limit_value(value, _max_length), do: value

  defp keep_keys(metadata, :all), do: metadata
  defp keep_keys(metadata, keys), do: Map.take(metadata, keys)

  defp serialize_value(v) when is_binary(v), do: v
  defp serialize_value(nil), do: nil
  defp serialize_value(v) when is_boolean(v), do: v
  defp serialize_value(v) when is_atom(v), do: Atom.to_string(v)
  defp serialize_value(v) when is_number(v), do: v

  defp serialize_value(v) do
    # Bug M-6: surface (once per step) when log metadata has been silently
    # stringified — devs often don't realize they passed a non-JSON-safe
    # value and end up debugging an `inspect/1` blob instead of structured
    # data. Rate-limited via a process-dict flag.
    warn_once_about_unsafe_metadata(v)
    inspect(v)
  end

  defp warn_once_about_unsafe_metadata(v) do
    case Process.get(@warn_flag) do
      true ->
        :ok

      _ ->
        Process.put(@warn_flag, true)

        # `durable_internal` keeps this line out of the step's own logs; it's a
        # filter, not something to print, so it isn't in the formatter config.
        # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
        Logger.debug(
          "[Durable.LogCapture] non-JSON-safe metadata value stringified " <>
            "to inspect/1 form: #{inspect(v, limit: 80)}. To preserve " <>
            "structured data, only pass binaries, atoms, numbers, booleans, " <>
            "or nil in Logger metadata.",
          durable_internal: true
        )
    end
  end

  defp format_logs_for_storage(logs) do
    # Convert string keys to atoms for consistency with schema. A line can hold
    # anything; one Postgres can't store would otherwise cost the step's result.
    Enum.map(logs, fn log ->
      Durable.Executor.sanitize_for_json(%{
        "timestamp" => log.timestamp,
        "level" => log.level,
        "severity_number" => log.severity_number,
        "message" => log.message,
        "source" => log.source,
        "metadata" => log.metadata,
        "trace_id" => log.trace_id,
        "span_id" => log.span_id
      })
    end)
  end

  defp get_config do
    Application.get_env(:durable, :log_capture, [])
  end
end
