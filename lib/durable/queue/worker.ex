defmodule Durable.Queue.Worker do
  @moduledoc """
  Executes a single workflow job in an isolated process.

  Each worker runs under a DynamicSupervisor with `restart: :temporary`,
  ensuring that:
  - Each workflow execution is isolated
  - A crash in one worker does not affect others
  - Workers are not automatically restarted (stale lock recovery handles retries)

  The worker spawns job execution in a separate Task, allowing the GenServer
  to send periodic heartbeats to update `locked_at` and prevent stale lock
  recovery from incorrectly reclaiming long-running jobs.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Durable.Config
  alias Durable.Queue.Adapter

  defstruct [:job, :config, :poller_pid, :started_at, :task_ref, :heartbeat_timer]

  @type t :: %__MODULE__{
          job: map(),
          config: Config.t(),
          poller_pid: pid(),
          started_at: integer(),
          task_ref: reference() | nil,
          heartbeat_timer: reference() | nil
        }

  @doc """
  Starts a worker process to execute a job.

  ## Options

  - `:job` - The job map to execute (required)
  - `:config` - The Durable configuration (required)
  - `:poller_pid` - The poller process to report completion to (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    job = Keyword.fetch!(opts, :job)
    config = Keyword.fetch!(opts, :config)
    poller_pid = Keyword.fetch!(opts, :poller_pid)

    state = %__MODULE__{
      job: job,
      config: config,
      poller_pid: poller_pid,
      started_at: System.monotonic_time(:millisecond),
      task_ref: nil,
      heartbeat_timer: nil
    }

    {:ok, state, {:continue, :start_execution}}
  end

  @impl true
  def handle_continue(:start_execution, state) do
    # Spawn job execution in a separate process so we can handle heartbeats
    task = Task.async(fn -> execute_job(state.job, state.config) end)

    # Start heartbeat timer
    timer = schedule_heartbeat(state.config.heartbeat_interval)

    {:noreply, %{state | task_ref: task.ref, heartbeat_timer: timer}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Send heartbeat to update locked_at
    adapter = Adapter.default_adapter()

    case adapter.heartbeat(state.config, state.job.id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Heartbeat failed for job #{state.job.id}: #{inspect(reason)}")
    end

    # Emit telemetry
    emit_heartbeat_telemetry(state.job)

    # Schedule next heartbeat
    timer = schedule_heartbeat(state.config.heartbeat_interval)
    {:noreply, %{state | heartbeat_timer: timer}}
  end

  # Task completed successfully
  @impl true
  def handle_info({ref, result}, %{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    cancel_heartbeat(state.heartbeat_timer)

    duration_ms = System.monotonic_time(:millisecond) - state.started_at

    # Emit telemetry
    emit_telemetry(state.job, result, duration_ms)

    # Notify poller of completion
    send(state.poller_pid, {:job_complete, state.job.id, result, duration_ms})

    {:stop, :normal, state}
  end

  # Task crashed
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    cancel_heartbeat(state.heartbeat_timer)

    Logger.error("Task crashed for job #{state.job.id}: #{inspect(reason)}")

    error = %{type: "task_crash", message: inspect(reason)}
    duration_ms = System.monotonic_time(:millisecond) - state.started_at

    # Emit telemetry
    emit_telemetry(state.job, {:error, error}, duration_ms)

    # Notify poller of failure
    send(state.poller_pid, {:job_complete, state.job.id, {:error, error}, duration_ms})

    {:stop, :normal, state}
  end

  # Private functions

  defp execute_job(job, config) do
    case Durable.Executor.execute_workflow(job.id, config) do
      {:ok, _execution} ->
        :ok

      {:waiting, _execution} ->
        # Workflow is waiting for sleep/event/input - not an error
        :waiting

      {:error, error} ->
        {:error, error}
    end
  rescue
    error ->
      Logger.error(
        "Worker crashed executing job #{job.id}: #{Exception.message(error)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:error,
       %{
         type: inspect(error.__struct__),
         message: Exception.message(error),
         stacktrace: Exception.format_stacktrace(__STACKTRACE__)
       }}
  catch
    kind, reason ->
      Logger.error("Worker caught #{kind} executing job #{job.id}: #{inspect(reason)}")

      {:error,
       %{
         type: "#{kind}",
         message: inspect(reason)
       }}
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end

  defp cancel_heartbeat(nil), do: :ok
  defp cancel_heartbeat(timer), do: Process.cancel_timer(timer)

  defp emit_telemetry(job, result, duration_ms) do
    status =
      case result do
        :ok -> :completed
        :waiting -> :waiting
        {:error, _} -> :failed
      end

    :telemetry.execute(
      [:durable, :queue, :job_completed],
      %{duration_ms: duration_ms},
      %{
        job_id: job.id,
        queue: job.queue,
        workflow_module: job.workflow_module,
        workflow_name: job.workflow_name,
        status: status
      }
    )
  end

  defp emit_heartbeat_telemetry(job) do
    :telemetry.execute(
      [:durable, :queue, :heartbeat],
      %{count: 1},
      %{
        job_id: job.id,
        queue: job.queue
      }
    )
  end
end
