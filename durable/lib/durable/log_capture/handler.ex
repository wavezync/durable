defmodule Durable.LogCapture.Handler do
  @moduledoc """
  Logger handler for capturing workflow step logs.

  Implements the Erlang `:logger` handler behavior (OTP 21+, Elixir 1.15+).
  This handler intercepts log events and routes them to the process dictionary
  buffer when the current process is executing a workflow step.

  ## Handler Registration

  The handler is registered at application startup:

      # In Durable.Application.start/2
      :ok = Durable.LogCapture.Handler.attach()

  ## How It Works

  1. When a log event occurs, the `log/2` callback is invoked
  2. The handler checks if `:durable_workflow_id` is set in the process dictionary
  3. If in workflow context, the log is added to the `:durable_logs` buffer
  4. If not in workflow context, the log is ignored (passes through to other handlers)

  This design ensures:
  - No impact on logging outside of workflow execution
  - Each step's logs are captured in isolation
  - Concurrent workflow executions don't interfere with each other
  """

  @handler_id :durable_log_capture
  @console_filter :durable_step_lines

  @doc """
  Attaches the log capture handler to the Logger.

  Called from the application's start callback during application startup.
  Returns `:ok` on success.

  If the handler is already attached, this is a no-op.
  """
  @spec attach() :: :ok | {:error, term()}
  def attach do
    filter_console(Keyword.get(Application.get_env(:durable, :log_capture, []), :console, true))

    config = %{
      level: :all,
      filter_default: :log
    }

    case :logger.add_handler(@handler_id, __MODULE__, config) do
      :ok ->
        :ok

      {:error, {:already_exist, @handler_id}} ->
        # Handler already attached, this is fine
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # On the console's handler alone: Durable's own and any others see every line.
  # Either call may find nothing to do, which is fine.
  defp filter_console(true), do: :logger.remove_handler_filter(:default, @console_filter)

  defp filter_console(false) do
    :logger.add_handler_filter(:default, @console_filter, {&__MODULE__.console_filter/2, []})
  end

  @doc false
  # Only lines that get saved are held back, so nothing is lost altogether.
  def console_filter(%{level: level, meta: meta}, _arg) do
    if Durable.LogCapture.saves?(level) and not Map.get(meta, :durable_internal, false),
      do: :stop,
      else: :ignore
  end

  @doc """
  Detaches the log capture handler from the Logger.

  Useful for testing or when the application is shutting down.
  """
  @spec detach() :: :ok | {:error, term()}
  def detach do
    case :logger.remove_handler(@handler_id) do
      :ok -> :ok
      {:error, {:not_found, @handler_id}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns whether the handler is currently attached.
  """
  @spec attached?() :: boolean()
  def attached? do
    handlers = :logger.get_handler_ids()
    @handler_id in handlers
  end

  # Logger handler callbacks

  @doc false
  def adding_handler(config) do
    {:ok, config}
  end

  @doc false
  def removing_handler(_config) do
    :ok
  end

  @doc false
  def changing_config(_action, old_config, _new_config) do
    {:ok, old_config}
  end

  @doc false
  # `:logger` removes a handler that raises, which would end capture for the
  # whole node over one line. A line that can't be read just isn't saved.
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    # Only capture logs when in workflow context, and not Durable's own lines
    # (its default telemetry logger runs in the step's process).
    if Durable.LogCapture.in_workflow_context?() and not Map.get(meta, :durable_internal, false) do
      formatted_message = format_message(msg)
      metadata = format_metadata(meta)
      Durable.LogCapture.add_log(level, formatted_message, metadata)
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  # Message formatting

  defp format_message({:string, msg}) do
    IO.chardata_to_string(msg)
  end

  defp format_message({:report, report}) when is_map(report) do
    inspect(report)
  end

  defp format_message({:report, report}) when is_list(report) do
    inspect(report)
  end

  defp format_message(msg) when is_binary(msg) do
    msg
  end

  defp format_message(msg) when is_list(msg) do
    IO.chardata_to_string(msg)
  end

  defp format_message(msg) do
    inspect(msg)
  end

  # Metadata formatting

  defp format_metadata(meta) do
    # Convert known keys to atoms for consistent handling
    meta
    |> Map.new(fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {Durable.Context.known_key(k), v}
      {k, v} -> {k, v}
    end)
  end
end
