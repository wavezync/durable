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

  @doc """
  Attaches the log capture handler to the Logger.

  Called from `Durable.Application.start/2` during application startup.
  Returns `:ok` on success.

  If the handler is already attached, this is a no-op.
  """
  @spec attach() :: :ok | {:error, term()}
  def attach do
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
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    # Only capture logs when in workflow context
    if Durable.LogCapture.in_workflow_context?() do
      formatted_message = format_message(msg)
      metadata = format_metadata(meta)
      Durable.LogCapture.add_log(level, formatted_message, metadata)
    end

    :ok
  end

  # Message formatting

  defp format_message({:string, msg}) do
    IO.iodata_to_binary(msg)
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
    IO.iodata_to_binary(msg)
  end

  defp format_message(msg) do
    inspect(msg)
  end

  # Metadata formatting

  defp format_metadata(meta) when is_map(meta) do
    # Convert known keys to atoms for consistent handling
    meta
    |> Map.new(fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp format_metadata(_), do: %{}
end
