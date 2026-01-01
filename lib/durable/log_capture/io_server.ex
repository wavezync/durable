defmodule Durable.LogCapture.IOServer do
  @moduledoc """
  GenServer that acts as a group_leader to capture IO operations.

  This process intercepts IO operations (IO.puts, IO.inspect, etc.) during
  workflow step execution and forwards them to the log capture buffer.

  ## How It Works

  1. The process is started and set as the group_leader for the step execution process
  2. IO operations send `:io_request` messages to the group_leader
  3. This server captures `:put_chars` operations and adds them to the log buffer
  4. Optionally, output can be passed through to the original group_leader

  ## Configuration

      config :durable,
        log_capture: [
          io_capture: true,
          io_passthrough: false  # Set to true to also print to console
        ]
  """

  use GenServer

  defstruct [:original_leader, :passthrough, :parent_pid]

  @doc """
  Starts the IO capture server.

  ## Options

    * `:original_leader` - Required. The original group_leader to restore/passthrough to.
    * `:passthrough` - Optional. If true, also sends output to original leader. Default: false.
    * `:parent_pid` - Required. The PID of the process whose IO we're capturing.

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stops the IO capture server.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal, 5000)
  catch
    :exit, _ -> :ok
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      original_leader: Keyword.fetch!(opts, :original_leader),
      passthrough: Keyword.get(opts, :passthrough, false),
      parent_pid: Keyword.fetch!(opts, :parent_pid)
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:io_request, from, reply_as, request}, state) do
    {reply, new_state} = handle_io_request(request, state)
    send(from, {:io_reply, reply_as, reply})
    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # IO request handlers

  defp handle_io_request({:put_chars, encoding, chars}, state) do
    handle_put_chars(chars, encoding, state)
  end

  defp handle_io_request({:put_chars, encoding, module, fun, args}, state) do
    # Format function call result
    try do
      chars = apply(module, fun, args)
      handle_put_chars(chars, encoding, state)
    rescue
      _ -> {:error, :format_error}
    end
  end

  defp handle_io_request({:put_chars, chars}, state) do
    handle_put_chars(chars, :unicode, state)
  end

  defp handle_io_request({:get_chars, _encoding, _prompt, _count}, state) do
    # We don't support input, forward to original leader
    {{:error, :enotsup}, state}
  end

  defp handle_io_request({:get_line, _encoding, _prompt}, state) do
    # We don't support input, forward to original leader
    {{:error, :enotsup}, state}
  end

  defp handle_io_request({:get_until, _encoding, _prompt, _module, _fun, _args}, state) do
    # We don't support input, forward to original leader
    {{:error, :enotsup}, state}
  end

  defp handle_io_request({:get_geometry, _type}, state) do
    # Forward geometry requests to original leader for proper terminal sizing
    case forward_to_original(state.original_leader, {:get_geometry, :columns}) do
      {:ok, result} -> {result, state}
      :error -> {{:error, :enotsup}, state}
    end
  end

  defp handle_io_request({:requests, requests}, state) do
    # Handle multiple requests
    {results, final_state} =
      Enum.reduce(requests, {[], state}, fn request, {acc, s} ->
        {reply, new_s} = handle_io_request(request, s)
        {[reply | acc], new_s}
      end)

    # Return :ok if all succeeded, otherwise first error
    result =
      results
      |> Enum.reverse()
      |> Enum.find(:ok, fn
        :ok -> false
        {:error, _} -> true
        _ -> false
      end)

    {result, final_state}
  end

  defp handle_io_request({:setopts, _opts}, state) do
    # Accept but ignore setopts
    {:ok, state}
  end

  defp handle_io_request({:getopts, []}, state) do
    # Return default options
    {[binary: true, encoding: :unicode], state}
  end

  defp handle_io_request(_request, state) do
    # Unknown request
    {{:error, :request}, state}
  end

  # Helper functions

  defp handle_put_chars(chars, _encoding, state) do
    output =
      try do
        IO.chardata_to_string(chars)
      rescue
        _ -> inspect(chars)
      end

    # Strip trailing newline for cleaner log entries
    output = String.trim_trailing(output, "\n")

    # Add to log buffer if we have workflow context
    if has_workflow_context?(state.parent_pid) do
      add_io_log(output, state.parent_pid)
    end

    # Optionally passthrough to original leader
    if state.passthrough do
      send(state.original_leader, {:io_request, self(), make_ref(), {:put_chars, :unicode, chars}})
    end

    {:ok, state}
  end

  defp has_workflow_context?(pid) do
    # Check if the parent process has workflow context set
    # We use Process.info to check the process dictionary
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        Keyword.has_key?(dict, :durable_workflow_id)

      nil ->
        false
    end
  end

  defp add_io_log(output, parent_pid) do
    # We need to add the log in the parent process's context
    # Since we can't directly modify another process's dictionary,
    # we send a message that the parent will handle, or we use
    # a different approach: call add_log from this process with
    # the appropriate metadata

    # For simplicity, we'll add the log directly since the parent
    # is the one that will call get_logs() and they're linked
    # The log buffer is in the parent's process dictionary

    # Actually, we need to think about this differently.
    # The IO server runs in a separate process, but we want logs
    # to appear in the parent's buffer.

    # Best approach: The parent process should add the log.
    # We can't safely modify another process's dictionary.
    # Instead, we'll have the parent check for pending IO logs
    # when stop_capture is called.

    # Alternative: Store IO logs in this server's state and
    # retrieve them when stopping.

    # For now, let's send a message to the parent to add the log
    send(parent_pid, {:durable_io_log, output})
  end

  defp forward_to_original(original_leader, request) do
    ref = make_ref()
    send(original_leader, {:io_request, self(), ref, request})

    receive do
      {:io_reply, ^ref, reply} -> {:ok, reply}
    after
      1000 -> :error
    end
  end
end
