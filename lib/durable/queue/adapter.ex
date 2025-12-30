defmodule Durable.Queue.Adapter do
  @moduledoc """
  Behaviour for queue adapters.

  The queue adapter is responsible for:
  - Fetching and claiming jobs atomically
  - Acknowledging completed jobs
  - Handling failed jobs (nack)
  - Rescheduling jobs for later execution
  - Recovering stale locks from crashed workers
  - Providing queue statistics
  """

  @type job_id :: String.t()
  @type queue_name :: String.t()
  @type job :: %{
          id: job_id(),
          workflow_module: String.t(),
          workflow_name: String.t(),
          queue: queue_name(),
          priority: integer(),
          input: map(),
          context: map(),
          scheduled_at: DateTime.t() | nil,
          current_step: String.t() | nil
        }

  @doc """
  Fetches and atomically claims jobs from a queue.

  Jobs are locked to prevent duplicate processing. Returns a list of
  claimed jobs up to the specified limit.

  ## Parameters

  - `queue` - The queue name to fetch from
  - `limit` - Maximum number of jobs to claim
  - `node_id` - Unique identifier for this node (used for locking)

  ## Returns

  A list of job maps that have been claimed.
  """
  @callback fetch_jobs(queue :: queue_name(), limit :: pos_integer(), node_id :: String.t()) ::
              [job()]

  @doc """
  Acknowledges successful job completion.

  Called when a workflow execution completes successfully.
  Clears the lock fields on the workflow execution.
  """
  @callback ack(job_id :: job_id()) :: :ok | {:error, term()}

  @doc """
  Negatively acknowledges a job (failure).

  Called when a workflow execution fails after all retries.
  Marks the job as failed and clears the lock.
  """
  @callback nack(job_id :: job_id(), reason :: term()) :: :ok | {:error, term()}

  @doc """
  Reschedules a job for future execution.

  Used for sleep and wait primitives. Sets the job back to pending
  status with a new scheduled_at time.
  """
  @callback reschedule(job_id :: job_id(), run_at :: DateTime.t()) :: :ok | {:error, term()}

  @doc """
  Recovers stale locks from crashed workers.

  Jobs locked longer than the timeout are released back to pending status.
  Returns the count of recovered jobs.
  """
  @callback recover_stale_locks(timeout_seconds :: pos_integer()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Returns statistics for a queue.

  Returns a map with counts by status and other metrics.
  """
  @callback get_stats(queue :: queue_name()) :: map()

  @doc """
  Updates the lock timestamp to indicate the worker is still alive.

  Called periodically by workers to prevent stale lock recovery
  from releasing jobs that are still being processed.
  """
  @callback heartbeat(job_id :: job_id()) :: :ok | {:error, term()}

  @doc """
  Returns the configured adapter module.
  """
  @spec adapter() :: module()
  def adapter do
    Application.get_env(:durable, :queue_adapter, Durable.Queue.Adapters.Postgres)
  end
end
