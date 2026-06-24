defmodule Durable.Wait.SleepWaker do
  @moduledoc """
  Background worker that revives workflows whose `sleep/1` or
  `schedule_at/1` wait has elapsed.

  When a step body calls `sleep` or `schedule_at`, the executor flips the
  workflow to `:waiting` and stamps `scheduled_at`. This worker
  periodically asks the queue adapter to flip any such row back to
  `:pending` once `scheduled_at <= NOW()`, so the queue poller can
  re-claim it. The adapter also merges a `:__sleep_satisfied__` marker
  into the workflow's context so the step body's next sleep call
  returns immediately rather than re-throwing.

  Polls every `:sleep_waker_interval` milliseconds (default 1_000) and
  wakes up to `:sleep_waker_batch_size` workflows per tick (default
  100) — both configurable via `Durable.Config`.
  """

  use GenServer

  require Logger

  alias Durable.Queue.Adapter

  defstruct [:config, :interval, :batch_size]

  @doc """
  Starts the sleep waker.

  ## Options

  - `:config` - The Durable config (required)
  - `:interval` - Override the config's `:sleep_waker_interval` (optional)
  - `:batch_size` - Override the config's `:sleep_waker_batch_size` (optional)
  """
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    interval = Keyword.get(opts, :interval, config.sleep_waker_interval)
    batch_size = Keyword.get(opts, :batch_size, config.sleep_waker_batch_size)

    GenServer.start_link(
      __MODULE__,
      %__MODULE__{config: config, interval: interval, batch_size: batch_size},
      name: worker_name(config.name)
    )
  end

  @doc """
  Returns the process name for a given Durable instance.
  """
  def worker_name(durable_name) do
    Module.concat([durable_name, Wait, SleepWaker])
  end

  @doc """
  Manually triggers a sweep, returning `{:ok, woken_count}`.

  Useful in tests and operational tooling — the periodic timer keeps
  ticking independently.
  """
  def wake_now(durable_name \\ Durable) do
    GenServer.call(worker_name(durable_name), :wake_now)
  end

  # GenServer callbacks

  @impl true
  def init(state) do
    schedule_tick(state.interval)

    Logger.info(
      "[Durable] sleep waker started for #{inspect(state.config.name)}, " <>
        "interval=#{state.interval}ms, batch_size=#{state.batch_size}"
    )

    {:ok, state}
  end

  @impl true
  def handle_call(:wake_now, _from, state) do
    {:reply, do_wake(state), state}
  end

  @impl true
  def handle_info(:tick, state) do
    do_wake(state)
    schedule_tick(state.interval)
    {:noreply, state}
  end

  # Private

  defp do_wake(%__MODULE__{config: config, batch_size: batch_size}) do
    adapter = Adapter.default_adapter()

    if function_exported?(adapter, :wake_sleeping_workflows, 2) do
      case adapter.wake_sleeping_workflows(config, batch_size) do
        {:ok, 0} = ok ->
          ok

        {:ok, count} = ok ->
          Logger.debug(
            "[Durable] sleep waker woke #{count} workflow(s) for #{inspect(config.name)}"
          )

          emit_telemetry(count, config.name)
          ok

        {:error, reason} = err ->
          Logger.error(
            "[Durable] sleep waker sweep failed for #{inspect(config.name)}: " <>
              inspect(reason)
          )

          err
      end
    else
      {:ok, 0}
    end
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp emit_telemetry(count, durable_name) do
    :telemetry.execute(
      [:durable, :wait, :sleep_woken],
      %{count: count},
      %{durable: durable_name}
    )
  end
end
