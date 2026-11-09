defmodule Durable.Queue.Poller do
  @moduledoc """
  GenServer that polls a queue for jobs and starts workers to execute them.

  Each poller handles a single queue and maintains:
  - A set of active job IDs being processed
  - Concurrency limits
  - Poll interval configuration

  The poller monitors workers and handles their completion messages,
  calling ack/nack on the adapter as appropriate.
  """

  use GenServer

  require Logger

  alias Durable.Config
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Queue.Adapter
  alias Durable.Queue.Worker

  defstruct [
    :config,
    :queue_name,
    :concurrency,
    :poll_interval,
    :worker_supervisor,
    :node_id,
    :workers,
    :paused,
    :timer_ref
  ]

  @type t :: %__MODULE__{
          config: Config.t(),
          queue_name: String.t(),
          concurrency: pos_integer(),
          poll_interval: pos_integer(),
          worker_supervisor: atom() | pid(),
          node_id: String.t(),
          workers: %{pid() => %{ref: reference(), job_id: String.t(), token: String.t() | nil}},
          paused: boolean(),
          timer_ref: reference() | nil
        }

  @default_concurrency 10
  @default_poll_interval 1000

  # Client API

  @doc """
  Starts the poller process.

  ## Options

  - `:config` - The Durable configuration (required)
  - `:queue_name` - The name of the queue to poll (required)
  - `:concurrency` - Maximum concurrent workers (default: 10)
  - `:poll_interval` - Milliseconds between polls (default: 1000)
  - `:worker_supervisor` - The DynamicSupervisor for workers (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Pauses the poller, stopping it from claiming new jobs.
  """
  @spec pause(GenServer.server()) :: :ok
  def pause(server) do
    GenServer.call(server, :pause)
  end

  @doc """
  Resumes the poller after being paused.
  """
  @spec resume(GenServer.server()) :: :ok
  def resume(server) do
    GenServer.call(server, :resume)
  end

  @doc """
  Drains the poller, waiting for all active jobs to complete.

  Returns `:ok` when all jobs are complete or `{:error, :timeout}` if
  the timeout is exceeded.
  """
  @spec drain(GenServer.server(), timeout()) :: :ok | {:error, :timeout}
  def drain(server, timeout \\ 30_000) do
    GenServer.call(server, {:drain, timeout}, timeout + 1000)
  end

  @doc """
  Returns the current state of the poller for debugging.
  """
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    queue_name = Keyword.fetch!(opts, :queue_name)
    worker_supervisor = Keyword.fetch!(opts, :worker_supervisor)

    state = %__MODULE__{
      config: config,
      queue_name: queue_name,
      concurrency: Keyword.get(opts, :concurrency, @default_concurrency),
      poll_interval: Keyword.get(opts, :poll_interval, @default_poll_interval),
      worker_supervisor: worker_supervisor,
      node_id: config.node_id,
      workers: %{},
      paused: false,
      timer_ref: nil
    }

    # A start or resume on this queue wakes us (Durable.PubSub.wake/2), so a
    # long poll_interval doesn't delay new work. No-op without a PubSub.
    _ = DurablePubSub.subscribe(config, DurablePubSub.queue_topic(config, queue_name))

    # Start polling
    state = schedule_poll(state, 0)

    Logger.info("Queue poller started for queue=#{queue_name} concurrency=#{state.concurrency}")

    {:ok, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    Logger.info("Pausing queue poller for #{state.queue_name}")
    {:reply, :ok, %{state | paused: true}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    Logger.info("Resuming queue poller for #{state.queue_name}")
    state = %{state | paused: false}
    state = schedule_poll(state, 0)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:drain, timeout}, from, state) do
    state = %{state | paused: true}

    if state.workers == %{} do
      {:reply, :ok, state}
    else
      # Wait for jobs to complete
      Process.send_after(
        self(),
        {:drain_check, from, timeout, System.monotonic_time(:millisecond)},
        100
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      queue_name: state.queue_name,
      concurrency: state.concurrency,
      poll_interval: state.poll_interval,
      active_jobs: map_size(state.workers),
      paused: state.paused,
      node_id: state.node_id
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = %{state | timer_ref: nil}

    state =
      if state.paused do
        state
      else
        poll_and_process(state)
      end

    # Schedule next poll
    state = schedule_poll(state, state.poll_interval)

    {:noreply, state}
  end

  # Poll now, between scheduled polls. A burst of wakes stops polling once
  # every slot is taken.
  @impl true
  def handle_info({:durable_wake, _queue}, state) do
    state = if state.paused, do: state, else: poll_and_process(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:job_complete, worker, job_id, result, duration_ms}, state) do
    Logger.debug(
      "Job #{job_id} completed with result=#{inspect(result)} duration=#{duration_ms}ms"
    )

    state = handle_job_completion(state, worker, result)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, worker, reason}, state) do
    case Map.pop(state.workers, worker) do
      {nil, _workers} ->
        {:noreply, state}

      {%{job_id: job_id}, workers} ->
        Logger.warning("Worker for job #{job_id} crashed: #{inspect(reason)}")
        # Job remains locked in DB, will be recovered by stale lock recovery
        {:noreply, %{state | workers: workers}}
    end
  end

  @impl true
  def handle_info({:drain_check, from, timeout, start_time}, state) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    cond do
      state.workers == %{} ->
        GenServer.reply(from, :ok)
        {:noreply, state}

      elapsed >= timeout ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, state}

      true ->
        Process.send_after(self(), {:drain_check, from, timeout, start_time}, 100)
        {:noreply, state}
    end
  end

  # Private functions

  defp poll_and_process(state) do
    available_slots = state.concurrency - map_size(state.workers)

    if available_slots > 0 do
      adapter = Adapter.default_adapter()
      jobs = adapter.fetch_jobs(state.config, state.queue_name, available_slots, state.node_id)

      emit_poll_telemetry(state.queue_name, length(jobs), available_slots)

      Enum.reduce(jobs, state, &start_worker/2)
    else
      state
    end
  end

  defp start_worker(job, state) do
    case DynamicSupervisor.start_child(
           state.worker_supervisor,
           {Worker, job: job, config: state.config, poller_pid: self()}
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        emit_job_claimed_telemetry(job, state.node_id)

        # Keyed by worker: a run parked a moment ago can be claimed again before
        # its last worker has reported back.
        worker = %{ref: ref, job_id: job.id, token: job[:lock_token]}
        %{state | workers: Map.put(state.workers, pid, worker)}

      {:error, reason} ->
        Logger.error("Failed to start worker for job #{job.id}: #{inspect(reason)}")
        state
    end
  end

  defp handle_job_completion(state, worker, result) do
    case Map.pop(state.workers, worker) do
      {nil, _workers} ->
        state

      {%{ref: ref, job_id: job_id, token: token}, workers} ->
        safely_settle_job(state.config, job_id, token, result)
        Process.demonitor(ref, [:flush])
        %{state | workers: workers}
    end
  end

  # A row that can't be read mustn't take the poller, and its other workers,
  # down with it. Stale-lock recovery deals with the run.
  defp safely_settle_job(config, job_id, token, result) do
    settle_job(config, job_id, token, result)
  rescue
    error -> Logger.error("Couldn't settle job #{job_id}: #{Exception.message(error)}")
  end

  defp settle_job(config, job_id, token, result) do
    adapter = Adapter.default_adapter()

    case result do
      :ok ->
        adapter.ack(config, job_id, token)

      :waiting ->
        # Job is waiting for sleep/event/input - don't ack, leave as-is
        # The executor already updated the status to :waiting
        :ok

      :fenced ->
        # The worker detected it was fenced out and aborted. The row now
        # belongs to its new owner — don't ack/nack it, just clean up locally.
        :ok

      {:error, reason} ->
        adapter.nack(config, job_id, reason, token)
    end
  end

  defp schedule_poll(state, delay) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    timer_ref = Process.send_after(self(), :poll, delay)
    %{state | timer_ref: timer_ref}
  end

  defp emit_poll_telemetry(queue_name, jobs_fetched, available_slots) do
    :telemetry.execute(
      [:durable, :queue, :poll],
      %{jobs_fetched: jobs_fetched},
      %{queue: queue_name, available_slots: available_slots}
    )
  end

  defp emit_job_claimed_telemetry(job, node_id) do
    :telemetry.execute(
      [:durable, :queue, :job_claimed],
      %{count: 1},
      %{
        job_id: job.id,
        queue: job.queue,
        workflow_module: job.workflow_module,
        workflow_name: job.workflow_name,
        node_id: node_id
      }
    )
  end
end
