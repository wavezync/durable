defmodule Durable.Queue.StaleJobRecovery do
  @moduledoc """
  Periodically recovers jobs with stale locks.

  Jobs can become "stuck" if a worker process crashes without releasing
  the lock. This GenServer periodically checks for such jobs and releases
  them back to pending status so they can be picked up again.
  """

  use GenServer

  require Logger

  alias Durable.Queue.Adapter

  defstruct [:interval, :timeout]

  @default_interval 60_000
  @default_timeout 300

  @doc """
  Starts the stale job recovery process.

  ## Options

  - `:interval` - Milliseconds between recovery checks (default: 60000)
  - `:timeout` - Seconds before a lock is considered stale (default: 300)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers stale lock recovery.
  """
  @spec recover_now() :: {:ok, non_neg_integer()} | {:error, term()}
  def recover_now do
    GenServer.call(__MODULE__, :recover_now)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    timeout = Application.get_env(:durable, :stale_lock_timeout, @default_timeout)

    state = %__MODULE__{
      interval: interval,
      timeout: timeout
    }

    # Schedule first recovery
    schedule_recovery(interval)

    Logger.info("Stale job recovery started, interval=#{interval}ms, timeout=#{timeout}s")

    {:ok, state}
  end

  @impl true
  def handle_call(:recover_now, _from, state) do
    result = do_recovery(state.timeout)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:recover, state) do
    do_recovery(state.timeout)
    schedule_recovery(state.interval)
    {:noreply, state}
  end

  # Private functions

  defp do_recovery(timeout) do
    adapter = Adapter.adapter()

    case adapter.recover_stale_locks(timeout) do
      {:ok, 0} ->
        {:ok, 0}

      {:ok, count} ->
        Logger.info("Recovered #{count} stale job(s)")
        emit_telemetry(count)
        {:ok, count}

      {:error, reason} = error ->
        Logger.error("Failed to recover stale locks: #{inspect(reason)}")
        error
    end
  end

  defp schedule_recovery(interval) do
    Process.send_after(self(), :recover, interval)
  end

  defp emit_telemetry(count) do
    :telemetry.execute(
      [:durable, :queue, :stale_recovered],
      %{count: count},
      %{}
    )
  end
end
