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
  alias Durable.Storage.Schemas.StepExecution

  require Logger

  @type result :: {:ok, any()} | {:error, any()}

  @doc """
  Executes a single compensation handler with retry logic.

  Returns `{:ok, output}` on success or `{:error, reason}` after all retries exhausted.
  Compensation errors don't stop the chain - they are recorded and the process continues.
  """
  @spec execute(Compensation.t(), String.t(), atom(), Config.t()) :: result()
  def execute(%Compensation{} = compensation, workflow_id, compensating_step, %Config{} = config) do
    max_attempts = get_max_attempts(compensation)
    execute_with_retry(compensation, workflow_id, compensating_step, 1, max_attempts, config)
  end

  defp execute_with_retry(
         compensation,
         workflow_id,
         compensating_step,
         attempt,
         max_attempts,
         config
       ) do
    repo = config.repo

    # Create step execution record for compensation
    {:ok, step_exec} =
      create_compensation_execution(
        repo,
        workflow_id,
        compensation,
        compensating_step,
        attempt
      )

    # Mark as running
    {:ok, step_exec} = update_step_execution(repo, step_exec, :running)

    # Start log capture for this compensation
    Durable.LogCapture.start_capture()

    # Execute the compensation body
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        output = Compensation.execute(compensation, Context.context())
        {:ok, output}
      rescue
        e ->
          {:error,
           %{
             type: inspect(e.__struct__),
             message: Exception.message(e),
             stacktrace: Exception.format_stacktrace(__STACKTRACE__)
           }}
      catch
        kind, reason ->
          {:error, %{type: "#{kind}", message: inspect(reason)}}
      end

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    # Stop log capture and get captured logs
    logs = Durable.LogCapture.stop_capture()

    case result do
      {:ok, output} ->
        {:ok, _} = complete_step_execution(repo, step_exec, output, logs, duration_ms)
        {:ok, output}

      {:error, error} ->
        if attempt < max_attempts do
          # Mark this attempt as failed
          {:ok, _} = fail_step_execution(repo, step_exec, error, logs, duration_ms)

          # Calculate backoff and sleep
          retry_opts = get_retry_opts(compensation)
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
        else
          # All retries exhausted
          {:ok, _} = fail_step_execution(repo, step_exec, error, logs, duration_ms)
          {:error, error}
        end
    end
  end

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

  defp create_compensation_execution(repo, workflow_id, compensation, compensating_step, attempt) do
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
    |> repo.insert()
  end

  defp update_step_execution(repo, step_exec, :running) do
    step_exec
    |> StepExecution.start_changeset()
    |> repo.update()
  end

  defp complete_step_execution(repo, step_exec, output, logs, duration_ms) do
    serializable_output = serialize_output(output)

    step_exec
    |> StepExecution.complete_changeset(serializable_output, logs, duration_ms)
    |> repo.update()
  end

  defp fail_step_execution(repo, step_exec, error, logs, duration_ms) do
    step_exec
    |> StepExecution.fail_changeset(error, logs, duration_ms)
    |> repo.update()
  end

  defp serialize_output(output) when is_map(output), do: output
  defp serialize_output(output) when is_list(output), do: %{value: output}
  defp serialize_output(output) when is_binary(output), do: %{value: output}
  defp serialize_output(output) when is_number(output), do: %{value: output}
  defp serialize_output(output) when is_atom(output), do: %{value: Atom.to_string(output)}
  defp serialize_output(output) when is_tuple(output), do: %{value: Tuple.to_list(output)}
  defp serialize_output(nil), do: nil
  defp serialize_output(output), do: %{value: inspect(output)}
end
