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
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Repo
  alias Durable.Storage.Schemas.StepExecution

  import Ecto.Query, only: [from: 2]

  @type result ::
          {:ok, map()}
          | {:error, any()}
          | {:decision, atom(), map()}
          | {:sleep, keyword()}
          | {:wait_for_event, keyword()}
          | {:wait_for_input, keyword()}
          | {:wait_for_any, keyword()}
          | {:wait_for_all, keyword()}
          | {:call_workflow, keyword()}

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
    start_attempt = next_attempt(config, workflow_id, step)
    execute_with_retry(step, data, workflow_id, start_attempt, max_attempts, config)
  end

  # Seed the retry counter from durable state instead of always starting at 1.
  #
  # The retry budget must survive a worker crash / stale-lock recovery: if a
  # step is on attempt 3 of 5 when the node dies, the resumed run must continue
  # at attempt 4 — not restart at 1 and re-run the side effect up to 5 more
  # times (the previous behaviour silently exceeded max_attempts globally and
  # contradicted the "durable/resumable" contract).
  #
  # We count `:failed` step_executions for (workflow_id, step_name), NOT the max
  # attempt number: a `:waiting` row is a *suspension* (sleep/event), not a
  # failed attempt, so it must not advance the retry counter. Each genuine retry
  # writes exactly one `:failed` row, so `failed_count + 1` is the next attempt.
  defp next_attempt(config, workflow_id, %Step{name: name}) do
    step_name = Atom.to_string(name)

    failed_count =
      Repo.one(
        config,
        from(s in StepExecution,
          where:
            s.workflow_id == ^workflow_id and s.step_name == ^step_name and s.status == :failed,
          select: count(s.id)
        )
      )

    (failed_count || 0) + 1
  end

  defp execute_with_retry(step, data, workflow_id, attempt, max_attempts, config) do
    # Set current step for logging/observability
    Context.set_current_step(step.name)

    # Set current data in process dictionary for wait functions to access.
    # On retry attempts (attempt > 1) we MERGE rather than overwrite so that
    # put_context/2 writes from the prior failed attempt remain visible to
    # the user step body — matching the cumulative-context contract that
    # save_data_as_context/3 enforces between sequential steps.
    prior_ctx = if attempt > 1, do: Process.get(:durable_context, %{}), else: %{}
    Process.put(:durable_context, Map.merge(prior_ctx, data))

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
       when wait_type in [
              :sleep,
              :wait_for_event,
              :wait_for_input,
              :wait_for_any,
              :wait_for_all,
              :call_workflow
            ] do
    %{step_exec: step_exec, config: config} = ctx
    # A call_workflow throw carries the spawned child id — record it on this
    # step's row so step→child is queryable (the parent context map is the
    # fallback, not the source of truth).
    child_id = if wait_type == :call_workflow, do: opts[:child_id], else: nil
    {:ok, _} = update_step_execution(config, step_exec, :waiting, child_id)
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
    case step_exec
         |> StepExecution.start_changeset()
         |> Repo.update(config) do
      {:ok, updated} = ok ->
        DurablePubSub.broadcast_step(config, :step_started, step_event(updated))
        ok

      other ->
        other
    end
  end

  defp update_step_execution(config, step_exec, :waiting, child_id) do
    changes =
      if child_id, do: [status: :waiting, child_workflow_id: child_id], else: [status: :waiting]

    case step_exec
         |> Ecto.Changeset.change(changes)
         |> Repo.update(config) do
      {:ok, updated} = ok ->
        DurablePubSub.broadcast_step(config, :step_waiting, step_event(updated))
        ok

      other ->
        other
    end
  end

  defp complete_step_execution(config, step_exec, output, logs, duration_ms) do
    serializable_output = serialize_output(output)

    case step_exec
         |> StepExecution.complete_changeset(serializable_output, logs, duration_ms)
         |> Repo.update(config) do
      {:ok, updated} = ok ->
        DurablePubSub.broadcast_step(config, :step_completed, step_event(updated))
        ok

      other ->
        other
    end
  end

  defp fail_step_execution(config, step_exec, error, logs, duration_ms) do
    # Sanitize the error map — exception payloads frequently carry tuples
    # (e.g., FunctionClauseError args), PIDs, refs, and functions in the
    # stacktrace area, none of which can survive a JSONB write. Mirror the
    # defense applied to workflow-level mark_failed in lib/durable/executor.ex.
    safe_error = Durable.Executor.sanitize_for_json(error)

    case step_exec
         |> StepExecution.fail_changeset(safe_error, logs, duration_ms)
         |> Repo.update(config) do
      {:ok, updated} = ok ->
        DurablePubSub.broadcast_step(config, :step_failed, step_event(updated))
        ok

      other ->
        other
    end
  end

  defp step_event(%StepExecution{} = step_exec) do
    %{
      id: step_exec.id,
      workflow_id: step_exec.workflow_id,
      step_name: step_exec.step_name,
      step_type: step_exec.step_type,
      status: step_exec.status,
      attempt: step_exec.attempt,
      duration_ms: step_exec.duration_ms,
      started_at: step_exec.started_at,
      completed_at: step_exec.completed_at
    }
  end

  # Convert an arbitrary step output into a JSONB-safe map. The schema field
  # is `:map`, so non-map outputs are wrapped under a `:value` key. Recursive
  # sanitization handles deeply-nested tuples / PIDs / refs / functions —
  # the previous shallow implementation only flattened top-level shapes and
  # let nested tuples crash JSONB encoding.
  defp serialize_output(nil), do: nil

  defp serialize_output(output) when is_map(output) do
    Durable.Executor.sanitize_for_json(output)
  end

  defp serialize_output(output) do
    %{value: Durable.Executor.sanitize_for_json(output)}
  end

  # Normalize error to map format for database storage
  # The error field in StepExecution expects a map
  defp normalize_error_for_storage(error) when is_map(error), do: error

  defp normalize_error_for_storage(error) when is_binary(error),
    do: %{type: "error", message: error}

  defp normalize_error_for_storage(error) when is_atom(error),
    do: %{type: "error", message: Atom.to_string(error)}

  defp normalize_error_for_storage(error), do: %{type: "error", message: inspect(error)}
end
