defmodule Durable.Executor.CompensationRunner do
  @moduledoc """
  Executes compensation handlers for saga pattern rollbacks.

  Compensations are executed in reverse order when a workflow step fails
  and need to undo the effects of previously completed steps.

  ## Behavior

  - Compensations run in reverse order (last completed step first)
  - Each compensation is recorded as a step_execution with `is_compensation: true`
  - Compensation failures are logged but don't stop the compensation chain
  - Retry logic is supported for individual compensations
  """

  alias Durable.Config
  alias Durable.Context
  alias Durable.Definition.Compensation
  alias Durable.Executor.Backoff
  alias Durable.Executor.StepRunner
  alias Durable.Repo
  alias Durable.Storage.Schemas.StepExecution

  @type result :: {:ok, any()} | {:error, any()}

  @doc """
  Executes a single compensation handler with retry logic.

  Returns `{:ok, output}` on success or `{:error, reason}` after all retries exhausted.
  Compensation errors don't stop the chain - they are recorded and the process continues.
  """
  @spec execute(Compensation.t(), String.t(), atom(), Config.t()) :: result()
  def execute(%Compensation{} = compensation, workflow_id, compensating_step, %Config{} = config) do
    max_attempts = get_max_attempts(compensation)

    run_meta = Durable.Telemetry.run_meta()

    meta = %{
      durable: config.name,
      workflow_id: workflow_id,
      workflow: Map.get(run_meta, :workflow),
      key: Map.get(run_meta, :key),
      tags: Map.get(run_meta, :tags),
      root_workflow_id: Map.get(run_meta, :root_workflow_id, workflow_id),
      telemetry_span_context: StepRunner.compensation_span(workflow_id, compensation.name),
      compensation: compensation.name,
      step: compensating_step
    }

    Durable.Telemetry.span([:durable, :compensation], meta, fn ->
      result =
        execute_with_retry(compensation, workflow_id, compensating_step, 1, max_attempts, config)

      {result, Map.put(meta, :result, if(match?({:ok, _}, result), do: :ok, else: :error))}
    end)
  end

  defp execute_with_retry(
         compensation,
         workflow_id,
         compensating_step,
         attempt,
         max_attempts,
         config
       ) do
    Durable.Telemetry.put_log_metadata(workflow_id, compensation.name, attempt, Context.context())

    # Create step execution record for compensation
    {:ok, step_exec} =
      create_compensation_execution(
        config,
        workflow_id,
        compensation,
        compensating_step,
        attempt
      )

    # Mark as running
    {:ok, step_exec} = update_step_execution(config, step_exec, :running)

    # Start log capture for this compensation
    Durable.LogCapture.start_capture(
      Durable.Telemetry.log_ids(
        Map.get(Durable.Telemetry.run_meta(), :root_workflow_id, workflow_id),
        step_exec.id
      )
    )

    # Execute the compensation body
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        compensation |> Compensation.execute(Context.context()) |> outcome()
      catch
        kind, reason -> {:error, Durable.Executor.caught_error(kind, reason, __STACKTRACE__)}
      end

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    # Stop log capture and get captured logs
    logs = Durable.LogCapture.stop_capture()

    case result do
      {:ok, output} ->
        {:ok, _} = complete_step_execution(config, step_exec, output, logs, duration_ms)
        {:ok, output}

      {:error, error} when attempt < max_attempts ->
        # Mark this attempt as failed
        {:ok, _} = fail_step_execution(config, step_exec, error, logs, duration_ms)

        # Calculate backoff and sleep
        # ponytail: compensations still retry in-process, holding the worker
        # and lock, so their backoff stays under stale_lock_timeout. Park
        # them like steps if long compensation backoffs are ever needed.
        retry_opts = compensation |> get_retry_opts() |> Map.put_new(:max_backoff, 30_000)
        backoff_strategy = Map.get(retry_opts, :backoff, :exponential)
        Backoff.sleep(backoff_strategy, attempt, retry_opts)

        # Retry
        execute_with_retry(
          compensation,
          workflow_id,
          compensating_step,
          attempt + 1,
          max_attempts,
          config
        )

      {_out_of_retries_or_fail, error} ->
        {:ok, _} = fail_step_execution(config, step_exec, error, logs, duration_ms)
        {:error, error}
    end
  end

  # A rollback that reports an error didn't happen. As in a step, {:error, _}
  # retries and {:fail, _} gives up now; any other return counts as done.
  defp outcome({:error, reason}), do: {:error, Durable.Executor.storable_error(reason)}
  defp outcome({:fail, reason}), do: {:fail, Durable.Executor.storable_error(reason)}
  defp outcome(output), do: {:ok, output}

  defp get_max_attempts(%Compensation{opts: opts}) do
    case Map.get(opts, :retry) do
      nil -> 1
      retry_opts when is_map(retry_opts) -> Map.get(retry_opts, :max_attempts, 1)
      _ -> 1
    end
  end

  defp get_retry_opts(%Compensation{opts: opts}) do
    case Map.get(opts, :retry) do
      nil -> %{}
      retry_opts when is_map(retry_opts) -> retry_opts
      _ -> %{}
    end
  end

  defp create_compensation_execution(
         config,
         workflow_id,
         compensation,
         compensating_step,
         attempt
       ) do
    attrs = %{
      workflow_id: workflow_id,
      step_name: "compensate_#{compensation.name}",
      step_type: "compensation",
      attempt: attempt,
      status: :pending,
      is_compensation: true,
      compensation_for: Atom.to_string(compensating_step)
    }

    %StepExecution{}
    |> StepExecution.changeset(attrs)
    |> Repo.insert(config)
  end

  defp update_step_execution(config, step_exec, :running) do
    step_exec
    |> StepExecution.start_changeset()
    |> Repo.update(config)
  end

  defp complete_step_execution(config, step_exec, output, logs, duration_ms) do
    serializable_output = StepRunner.serialize_output(output)

    step_exec
    |> StepExecution.complete_changeset(serializable_output, logs, duration_ms)
    |> Durable.Executor.finish_attempt!(config)
  end

  defp fail_step_execution(config, step_exec, error, logs, duration_ms) do
    step_exec
    |> StepExecution.fail_changeset(error, logs, duration_ms)
    |> Durable.Executor.finish_attempt!(config)
  end
end
