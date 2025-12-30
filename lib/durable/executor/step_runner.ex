defmodule Durable.Executor.StepRunner do
  @moduledoc """
  Executes individual workflow steps with retry logic and log capture.
  """

  alias Durable.Context
  alias Durable.Definition.Step
  alias Durable.Executor.Backoff
  alias Durable.Repo
  alias Durable.Storage.Schemas.StepExecution

  require Logger

  @type result :: {:ok, any()} | {:error, any()}

  @doc """
  Executes a step with retry logic.

  Returns `{:ok, output}` on success or `{:error, reason}` after all retries exhausted.
  """
  @spec execute(Step.t(), String.t()) :: result()
  def execute(%Step{} = step, workflow_id) do
    max_attempts = get_max_attempts(step)
    execute_with_retry(step, workflow_id, 1, max_attempts)
  end

  defp execute_with_retry(step, workflow_id, attempt, max_attempts) do
    # Set current step in context
    Context.set_current_step(step.name)

    # Create step execution record
    {:ok, step_exec} = create_step_execution(workflow_id, step, attempt)

    # Mark as running
    {:ok, step_exec} = update_step_execution(step_exec, :running)

    # Execute the step body
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        output = Step.execute(step, Context.context())
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
        :throw, value ->
          {:throw, value}

        kind, reason ->
          {:error, %{type: "#{kind}", message: inspect(reason)}}
      end

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    # Get captured logs (to be implemented with log capture backend)
    logs = []

    case result do
      {:ok, output} ->
        # Success - complete the step
        {:ok, _} = complete_step_execution(step_exec, output, logs, duration_ms)
        {:ok, output}

      {:throw, {:sleep, opts}} ->
        # Sleep signal - workflow should suspend
        {:ok, _} = update_step_execution(step_exec, :waiting)
        {:sleep, opts}

      {:throw, {:wait_for_event, opts}} ->
        # Wait for event signal
        {:ok, _} = update_step_execution(step_exec, :waiting)
        {:wait_for_event, opts}

      {:throw, {:wait_for_input, opts}} ->
        # Wait for input signal
        {:ok, _} = update_step_execution(step_exec, :waiting)
        {:wait_for_input, opts}

      {:error, error} ->
        # Failure - check if we should retry
        if attempt < max_attempts do
          # Mark this attempt as failed
          {:ok, _} = fail_step_execution(step_exec, error, logs, duration_ms)

          # Calculate backoff and sleep
          retry_opts = get_retry_opts(step)
          backoff_strategy = Map.get(retry_opts, :backoff, :exponential)
          Backoff.sleep(backoff_strategy, attempt, retry_opts)

          # Retry
          execute_with_retry(step, workflow_id, attempt + 1, max_attempts)
        else
          # All retries exhausted
          {:ok, _} = fail_step_execution(step_exec, error, logs, duration_ms)
          {:error, error}
        end
    end
  end

  defp get_max_attempts(%Step{opts: opts}) do
    case Map.get(opts, :retry) do
      nil -> 1
      retry_opts when is_map(retry_opts) -> Map.get(retry_opts, :max_attempts, 1)
      _ -> 1
    end
  end

  defp get_retry_opts(%Step{opts: opts}) do
    case Map.get(opts, :retry) do
      nil -> %{}
      retry_opts when is_map(retry_opts) -> retry_opts
      _ -> %{}
    end
  end

  defp create_step_execution(workflow_id, step, attempt) do
    attrs = %{
      workflow_id: workflow_id,
      step_name: Atom.to_string(step.name),
      step_type: Atom.to_string(step.type),
      attempt: attempt,
      status: :pending
    }

    %StepExecution{}
    |> StepExecution.changeset(attrs)
    |> Repo.insert()
  end

  defp update_step_execution(step_exec, :running) do
    step_exec
    |> StepExecution.start_changeset()
    |> Repo.update()
  end

  defp update_step_execution(step_exec, :waiting) do
    step_exec
    |> Ecto.Changeset.change(status: :waiting)
    |> Repo.update()
  end

  defp complete_step_execution(step_exec, output, logs, duration_ms) do
    serializable_output = serialize_output(output)

    step_exec
    |> StepExecution.complete_changeset(serializable_output, logs, duration_ms)
    |> Repo.update()
  end

  defp fail_step_execution(step_exec, error, logs, duration_ms) do
    step_exec
    |> StepExecution.fail_changeset(error, logs, duration_ms)
    |> Repo.update()
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
