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

  alias Durable.Queue.Adapter
  alias Durable.Queue.Worker

  defstruct [
    :queue_name,
    :concurrency,
    :poll_interval,
    :worker_supervisor,
    :node_id,
    :active_jobs,
    :worker_refs,
    :paused,
    :timer_ref
  ]

  @type t :: %__MODULE__{
          queue_name: String.t(),
          concurrency: pos_integer(),
          poll_interval: pos_integer(),
          worker_supervisor: atom() | pid(),
          node_id: String.t(),
          active_jobs: MapSet.t(String.t()),
          worker_refs: %{reference() => String.t()},
          paused: boolean(),
          timer_ref: reference() | nil
        }

  @default_concurrency 10
  @default_poll_interval 1000

  # Client API

  @doc """
  Starts the poller process.

  ## Options

  - `:queue_name` - The name of the queue to poll (required)
  - `:concurrency` - Maximum concurrent workers (default: 10)
  - `:poll_interval` - Milliseconds between polls (default: 1000)
  - `:worker_supervisor` - The DynamicSupervisor for workers (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    queue_name = Keyword.fetch!(opts, :queue_name)
    name = opts[:name] || via_tuple(queue_name)
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
    queue_name = Keyword.fetch!(opts, :queue_name)
    worker_supervisor = Keyword.fetch!(opts, :worker_supervisor)

    state = %__MODULE__{
      queue_name: queue_name,
      concurrency: Keyword.get(opts, :concurrency, @default_concurrency),
      poll_interval: Keyword.get(opts, :poll_interval, @default_poll_interval),
      worker_supervisor: worker_supervisor,
      node_id: generate_node_id(),
      active_jobs: MapSet.new(),
      worker_refs: %{},
      paused: false,
      timer_ref: nil
    }

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

    if MapSet.size(state.active_jobs) == 0 do
      {:reply, :ok, state}
    else
      # Wait for jobs to complete
      Process.send_after(self(), {:drain_check, from, timeout, System.monotonic_time(:millisecond)}, 100)
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      queue_name: state.queue_name,
      concurrency: state.concurrency,
      poll_interval: state.poll_interval,
      active_jobs: MapSet.size(state.active_jobs),
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

  @impl true
  def handle_info({:job_complete, job_id, result, duration_ms}, state) do
    Logger.debug("Job #{job_id} completed with result=#{inspect(result)} duration=#{duration_ms}ms")

    state = handle_job_completion(state, job_id, result)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.worker_refs, ref) do
      nil ->
        {:noreply, state}

      job_id ->
        Logger.warning("Worker for job #{job_id} crashed: #{inspect(reason)}")
        # Job remains locked in DB, will be recovered by stale lock recovery
        state = %{state |
          active_jobs: MapSet.delete(state.active_jobs, job_id),
          worker_refs: Map.delete(state.worker_refs, ref)
        }
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:drain_check, from, timeout, start_time}, state) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    cond do
      MapSet.size(state.active_jobs) == 0 ->
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
    available_slots = state.concurrency - MapSet.size(state.active_jobs)

    if available_slots > 0 do
      adapter = Adapter.adapter()
      jobs = adapter.fetch_jobs(state.queue_name, available_slots, state.node_id)

      emit_poll_telemetry(state.queue_name, length(jobs), available_slots)

      Enum.reduce(jobs, state, &start_worker/2)
    else
      state
    end
  end

  defp start_worker(job, state) do
    case DynamicSupervisor.start_child(
           state.worker_supervisor,
           {Worker, job: job, poller_pid: self()}
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        emit_job_claimed_telemetry(job, state.node_id)

        %{state |
          active_jobs: MapSet.put(state.active_jobs, job.id),
          worker_refs: Map.put(state.worker_refs, ref, job.id)
        }

      {:error, reason} ->
        Logger.error("Failed to start worker for job #{job.id}: #{inspect(reason)}")
        state
    end
  end

  defp handle_job_completion(state, job_id, result) do
    adapter = Adapter.adapter()

    case result do
      :ok ->
        adapter.ack(job_id)

      :waiting ->
        # Job is waiting for sleep/event/input - don't ack, leave as-is
        # The executor already updated the status to :waiting
        :ok

      {:error, reason} ->
        adapter.nack(job_id, reason)
    end

    # Find and remove the monitor ref for this job
    {ref, worker_refs} =
      Enum.find_value(state.worker_refs, {nil, state.worker_refs}, fn {ref, id} ->
        if id == job_id do
          {ref, Map.delete(state.worker_refs, ref)}
        else
          false
        end
      end)

    if ref, do: Process.demonitor(ref, [:flush])

    %{state |
      active_jobs: MapSet.delete(state.active_jobs, job_id),
      worker_refs: worker_refs
    }
  end

  defp schedule_poll(state, delay) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    timer_ref = Process.send_after(self(), :poll, delay)
    %{state | timer_ref: timer_ref}
  end

  defp generate_node_id do
    hostname =
      case :inet.gethostname() do
        {:ok, name} -> to_string(name)
        _ -> "unknown"
      end

    "#{hostname}-#{:erlang.system_info(:scheduler_id)}-#{System.unique_integer([:positive])}"
  end

  defp via_tuple(queue_name) do
    {:via, Registry, {Durable.Queue.Registry, {:poller, queue_name}}}
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
