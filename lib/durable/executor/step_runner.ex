defmodule Durable.Executor.StepRunner do
  @moduledoc """
  Executes individual workflow steps with retry logic and log capture.

  ## Pipeline Model

  Steps receive data from the previous step and return `{:ok, data}` or `{:error, reason}`.
  The first step receives the workflow input.
  """

  alias Durable.Config
  alias Durable.Context
  alias Durable.Definition.Step
  alias Durable.Executor.Backoff
  alias Durable.Repo
  alias Durable.Storage.Schemas.StepExecution

  require Logger

  @type result ::
          {:ok, map()}
          | {:error, any()}
          | {:decision, atom(), map()}
          | {:sleep, keyword()}
          | {:wait_for_event, keyword()}
          | {:wait_for_input, keyword()}
          | {:wait_for_any, keyword()}
          | {:wait_for_all, keyword()}

  @doc """
  Executes a step with retry logic.

  ## Arguments

  - `step` - The step definition
  - `data` - The data to pass to the step (from previous step or workflow input)
  - `workflow_id` - The workflow execution ID
  - `config` - The Durable config

  Returns `{:ok, data}` on success or `{:error, reason}` after all retries exhausted.
  """
  @spec execute(Step.t(), map(), String.t(), Config.t()) :: result()
  def execute(%Step{} = step, data, workflow_id, %Config{} = config) do
    max_attempts = get_max_attempts(step)
    execute_with_retry(step, data, workflow_id, 1, max_attempts, config)
  end

  defp execute_with_retry(step, data, workflow_id, attempt, max_attempts, config) do
    # Set current step for logging/observability
    Context.set_current_step(step.name)

    # Set current data in process dictionary for wait functions to access
    # This is needed because wait_for_event etc. check the context for resumed data
    Process.put(:durable_context, data)

    # Create step execution record
    {:ok, step_exec} = create_step_execution(config, workflow_id, step, attempt)
    {:ok, step_exec} = update_step_execution(config, step_exec, :running)

    # Start log capture for this step
    Durable.LogCapture.start_capture()

    # Execute the step body
    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        Step.execute(step, data)
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

    # Stop log capture and get captured logs
    logs = Durable.LogCapture.stop_capture()

    # Bundle context into a map to reduce arity
    result_ctx = %{
      step: step,
      step_exec: step_exec,
      data: data,
      logs: logs,
      duration_ms: duration_ms,
      attempt: attempt,
      max_attempts: max_attempts,
      config: config
    }

    handle_result(result, result_ctx)
  end

  # Handle step result from pipeline model
  defp handle_result({:ok, new_data}, ctx) when is_map(new_data) do
    %{step: step, step_exec: step_exec, logs: logs, duration_ms: duration_ms, config: config} =
      ctx

    # For decision steps returning {:ok, data}, record decision_type: "continue"
    if step.type == :decision do
      decision_output = %{
        decision_type: "continue",
        data: new_data
      }

      {:ok, _} = complete_step_execution(config, step_exec, decision_output, logs, duration_ms)
      {:ok, new_data}
    else
      handle_step_success(config, step, step_exec, new_data, logs, duration_ms)
    end
  end

  # Handle decision with goto
  defp handle_result({:goto, target, new_data}, ctx)
       when is_atom(target) and is_map(new_data) do
    %{step_exec: step_exec, logs: logs, duration_ms: duration_ms, config: config} = ctx

    decision_output = %{
      decision_type: "goto",
      target_step: Atom.to_string(target),
      data: new_data
    }

    {:ok, _} = complete_step_execution(config, step_exec, decision_output, logs, duration_ms)
    {:decision, target, new_data}
  end

  # Handle wait primitives (throws)
  defp handle_result({:throw, {wait_type, opts}}, ctx)
       when wait_type in [:sleep, :wait_for_event, :wait_for_input, :wait_for_any, :wait_for_all] do
    %{step_exec: step_exec, config: config} = ctx
    {:ok, _} = update_step_execution(config, step_exec, :waiting)
    {wait_type, opts}
  end

  # Handle errors with retry
  defp handle_result({:error, error}, ctx) do
    %{
      step: step,
      step_exec: step_exec,
      data: data,
      logs: logs,
      duration_ms: duration_ms,
      attempt: attempt,
      max_attempts: max_attempts,
      config: config
    } = ctx

    # Normalize error to map format for database storage
    normalized_error = normalize_error_for_storage(error)

    if attempt < max_attempts do
      {:ok, _} = fail_step_execution(config, step_exec, normalized_error, logs, duration_ms)

      retry_opts = get_retry_opts(step)
      backoff_strategy = Map.get(retry_opts, :backoff, :exponential)
      Backoff.sleep(backoff_strategy, attempt, retry_opts)

      execute_with_retry(step, data, step_exec.workflow_id, attempt + 1, max_attempts, config)
    else
      {:ok, _} = fail_step_execution(config, step_exec, normalized_error, logs, duration_ms)
      {:error, error}
    end
  end

  # Handle invalid return (not {:ok, map} or {:goto, ...})
  defp handle_result(other, ctx) do
    %{step_exec: step_exec, logs: logs, duration_ms: duration_ms, config: config} = ctx

    error = %{
      type: "invalid_step_return",
      message:
        "Step must return {:ok, map} or {:goto, :step, map} or {:error, reason}, got: #{inspect(other)}"
    }

    {:ok, _} = fail_step_execution(config, step_exec, error, logs, duration_ms)
    {:error, error}
  end

  defp handle_step_success(config, step, step_exec, new_data, logs, duration_ms) do
    stored_output =
      if step.opts[:parallel_id] do
        # Include result snapshot for parallel step resumption
        # Store the raw result data for the new results-based model
        %{
          "__output__" => new_data,
          "__context__" => new_data,
          "__result__" => new_data
        }
      else
        new_data
      end

    {:ok, _} = complete_step_execution(config, step_exec, stored_output, logs, duration_ms)
    {:ok, new_data}
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

  defp create_step_execution(config, workflow_id, step, attempt) do
    attrs = %{
      workflow_id: workflow_id,
      step_name: Atom.to_string(step.name),
      step_type: Atom.to_string(step.type),
      attempt: attempt,
      status: :pending
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

  defp update_step_execution(config, step_exec, :waiting) do
    step_exec
    |> Ecto.Changeset.change(status: :waiting)
    |> Repo.update(config)
  end

  defp complete_step_execution(config, step_exec, output, logs, duration_ms) do
    serializable_output = serialize_output(output)

    step_exec
    |> StepExecution.complete_changeset(serializable_output, logs, duration_ms)
    |> Repo.update(config)
  end

  defp fail_step_execution(config, step_exec, error, logs, duration_ms) do
    step_exec
    |> StepExecution.fail_changeset(error, logs, duration_ms)
    |> Repo.update(config)
  end

  defp serialize_output(output) when is_map(output), do: output
  defp serialize_output(output) when is_list(output), do: %{value: output}
  defp serialize_output(output) when is_binary(output), do: %{value: output}
  defp serialize_output(output) when is_number(output), do: %{value: output}
  defp serialize_output(output) when is_atom(output), do: %{value: Atom.to_string(output)}
  defp serialize_output(output) when is_tuple(output), do: %{value: Tuple.to_list(output)}
  defp serialize_output(nil), do: nil
  defp serialize_output(output), do: %{value: inspect(output)}

  # Normalize error to map format for database storage
  # The error field in StepExecution expects a map
  defp normalize_error_for_storage(error) when is_map(error), do: error

  defp normalize_error_for_storage(error) when is_binary(error),
    do: %{type: "error", message: error}

  defp normalize_error_for_storage(error) when is_atom(error),
    do: %{type: "error", message: Atom.to_string(error)}

  defp normalize_error_for_storage(error), do: %{type: "error", message: inspect(error)}
end
