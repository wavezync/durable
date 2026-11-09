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
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query, only: [from: 2]

  # A date or a decimal is a map to Elixir, but JSON stores it as a scalar, and
  # a run's data has to come back as an object.
  @scalars [Date, DateTime, NaiveDateTime, Time, Decimal]
  defguardp is_run_data(term)
            when is_map(term) and
                   not (is_struct(term) and :erlang.map_get(:__struct__, term) in @scalars)

  @suspending [
    :sleep,
    :wait_for_event,
    :wait_for_input,
    :wait_for_any,
    :wait_for_all,
    :call_workflow
  ]

  # A lost worker isn't the step's doing, so it uses no attempt, but a step
  # that takes its node down has to stop somewhere.
  # ponytail: fixed at 3, make it an option if anyone needs another number
  @max_lost_workers 3

  @type result ::
          {:ok, map()}
          | {:error, any()}
          | {:cancel, String.t(), :run | :workflow | :root | nil}
          | {:park, non_neg_integer()}
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
  - `deadline` - When the run's `timeout:` runs out, if it has one. A step
    still running then is stopped, and isn't retried.

  Returns `{:ok, data}` on success or `{:error, reason}` after all retries exhausted.
  """
  @spec execute(Step.t(), map(), String.t(), Config.t(), DateTime.t() | nil) :: result()
  def execute(%Step{} = step, data, workflow_id, %Config{} = config, deadline \\ nil) do
    max_attempts = get_max_attempts(step)
    %{failed: failed, lost: lost} = attempts_used(config, workflow_id, step)
    attempt = failed + 1

    # Spent before it started only when the last attempt died or lost its
    # worker before anything could fail the run. It fails now.
    if attempt > max(max_attempts, 1) or lost >= @max_lost_workers do
      {:error, last_error(config, workflow_id, step)}
    else
      execute_with_retry(step, data, workflow_id, attempt, max_attempts, config, deadline)
    end
  end

  @doc false
  # Closes the attempts these runs left :running. A process that dies can't
  # write its own result, so whoever finds out does it. Returns how many.
  @spec close_running(Config.t(), [String.t()], atom(), map()) :: non_neg_integer()
  def close_running(_config, [], _status, _error), do: 0

  def close_running(%Config{} = config, workflow_ids, status, error) do
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        config,
        from(s in StepExecution, where: s.workflow_id in ^workflow_ids and s.status == :running),
        set: [status: status, error: error, completed_at: now, updated_at: now]
      )

    count
  end

  @doc false
  # How long to wait before retrying a step whose last attempt just died; 0
  # if that was its last, so the next claim fails the run without delay.
  @spec delay_after_death(Step.t(), String.t(), Config.t()) :: non_neg_integer()
  def delay_after_death(%Step{} = step, workflow_id, %Config{} = config) do
    %{failed: failed} = attempts_used(config, workflow_id, step)
    if failed + 1 > get_max_attempts(step), do: 0, else: backoff_ms(step, failed)
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
  # writes exactly one `:failed` row, so `failed + 1` is the next attempt.
  #
  # A `worker_lost` row is counted apart (`lost`), against @max_lost_workers.
  defp attempts_used(config, workflow_id, %Step{name: name}) do
    step_name = Atom.to_string(name)

    # Only failures since the last Durable.retry/2 count: an operator retry
    # hands the step a fresh max_attempts budget.
    Repo.one(
      config,
      from(s in StepExecution,
        join: w in WorkflowExecution,
        on: w.id == s.workflow_id,
        where:
          s.workflow_id == ^workflow_id and s.step_name == ^step_name and s.status == :failed,
        where: is_nil(w.retried_at) or s.inserted_at > w.retried_at,
        select: %{
          failed:
            filter(count(s.id), fragment("?->>'type' IS DISTINCT FROM 'worker_lost'", s.error)),
          lost: filter(count(s.id), fragment("?->>'type' = 'worker_lost'", s.error))
        }
      )
    )
  end

  defp last_error(config, workflow_id, %Step{name: name}) do
    step_name = Atom.to_string(name)

    Repo.one(
      config,
      from(s in StepExecution,
        where:
          s.workflow_id == ^workflow_id and s.step_name == ^step_name and s.status == :failed,
        order_by: [desc: s.inserted_at],
        limit: 1,
        select: s.error
      )
    )
  end

  defp backoff_ms(step, attempt) do
    retry_opts = get_retry_opts(step)
    strategy = Map.get(retry_opts, :backoff, :exponential)
    Backoff.calculate_with_jitter(strategy, attempt, retry_opts)
  end

  defp execute_with_retry(step, data, workflow_id, attempt, max_attempts, config, deadline) do
    # Set current step for logging/observability
    Context.set_current_step(step.name)
    Context.set_attempt(attempt, max_attempts)
    Context.set_instance(config.name)
    Durable.Telemetry.put_log_metadata(workflow_id, step.name, attempt, data)

    # Set current data in process dictionary for wait functions to access.
    # A retry runs after the run was parked, from a context that already holds
    # the failed attempt's put_context/2 writes.
    Process.put(:durable_context, data)

    # Create step execution record
    {:ok, step_exec} = create_step_execution(config, workflow_id, step, attempt)
    {:ok, step_exec} = update_step_execution(config, step_exec, :running)

    # Start log capture for this step
    Durable.LogCapture.start_capture()

    # Execute the step body
    start_time = System.monotonic_time(:millisecond)
    span_meta = step_span_meta(config, workflow_id, step, attempt, max_attempts)

    result =
      :telemetry.span([:durable, :step], span_meta, fn ->
        result = run_body(step, data, time_limit(step, deadline))
        {result, Map.merge(span_meta, step_outcome(result))}
      end)

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    # Stop log capture and get captured logs
    logs = Durable.LogCapture.stop_capture()

    # Bundle context into a map to reduce arity
    result_ctx = %{
      step: step,
      step_exec: step_exec,
      logs: logs,
      duration_ms: duration_ms,
      attempt: attempt,
      max_attempts: max_attempts,
      deadline: deadline,
      config: config
    }

    handle_result(result, result_ctx)
  end

  defp run_body(step, data) do
    Step.execute(step, data)
  catch
    :throw, {kind, _opts} = suspension when kind in @suspending -> {:throw, suspension}
    kind, reason -> {:error, Durable.Executor.caught_error(kind, reason, __STACKTRACE__)}
  end

  # The step's own `timeout:` or what's left until the run's deadline,
  # whichever is shorter; nil when neither applies.
  defp time_limit(step, deadline) do
    left = deadline && max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0)

    [{step.opts[:timeout], :step}, {left, :run}]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
  end

  defp past?(nil), do: false
  defp past?(deadline), do: DateTime.compare(DateTime.utc_now(), deadline) != :lt

  # Keys Task sets for itself; everything else in the dictionary is copied.
  @task_keys [:"$ancestors", :"$callers", :"$initial_call"]

  defp run_body(step, data, nil), do: run_body(step, data)
  defp run_body(step, _data, {0, limit}), do: {:error, timeout_error(step, limit)}

  # A body with a time limit runs in a task that is killed when the limit
  # passes. The task starts with a copy of this process's dictionary (context,
  # log capture, telemetry metadata) and hands its own back, so the body sees
  # no difference beyond `self()`.
  defp run_body(step, data, {ms, limit}) do
    dict = Process.get()

    task =
      Task.async(fn ->
        put_dict(dict)
        {run_body(step, data), Process.get()}
      end)

    case Task.yield(task, ms) || stop(task) do
      {:ok, {result, dict}} ->
        put_dict(dict)
        result

      {:stopped, dict} ->
        put_dict(dict)
        {:error, timeout_error(step, limit)}
    end
  end

  # Keeps what the body logged before it was stopped.
  defp stop(task) do
    {:dictionary, dict} = Process.info(task.pid, :dictionary) || {:dictionary, []}
    Task.shutdown(task, :brutal_kill) || {:stopped, dict}
  end

  defp put_dict(dict),
    do: for({key, value} <- dict, key not in @task_keys, do: Process.put(key, value))

  defp timeout_error(step, :step) do
    %{
      type: "timeout",
      message:
        "#{step.name} took longer than its " <>
          "#{Durable.Executor.format_timeout(step.opts[:timeout])} timeout"
    }
  end

  defp timeout_error(step, :run),
    do: %{type: "timeout", message: "the run passed its timeout during #{step.name}"}

  defp step_span_meta(config, workflow_id, step, attempt, max_attempts) do
    run_meta = Durable.Telemetry.run_meta()

    %{
      durable: config.name,
      workflow_id: workflow_id,
      workflow: Map.get(run_meta, :workflow),
      key: Map.get(run_meta, :key),
      tags: Map.get(run_meta, :tags),
      step: step.name,
      step_type: step.type,
      attempt: attempt,
      max_attempts: max_attempts
    }
  end

  @cancel_scopes [:run, :workflow, :root]

  defp step_outcome({:ok, data}) when is_run_data(data), do: %{result: :ok}
  defp step_outcome({:goto, _target, _data}), do: %{result: :ok}
  defp step_outcome({:throw, {kind, _opts}}) when kind in @suspending, do: %{result: :suspended}
  defp step_outcome({:error, error}), do: %{result: :error, error: error_summary(error)}
  defp step_outcome({:fail, error}), do: %{result: :error, error: error_summary(error)}
  defp step_outcome({:snooze, ms}) when is_integer(ms) and ms >= 0, do: %{result: :snoozed}

  defp step_outcome({:snooze, ms, _reason}) when is_integer(ms) and ms >= 0,
    do: %{result: :snoozed}

  defp step_outcome({:cancel, _reason}), do: %{result: :cancelled}

  defp step_outcome({:cancel, _reason, [scope: scope]}) when scope in @cancel_scopes,
    do: %{result: :cancelled}

  defp step_outcome(_other),
    do: %{result: :error, error: %{type: "invalid_return", message: "unexpected step result"}}

  defp error_summary(%{type: type, message: message}), do: %{type: type, message: message}
  defp error_summary(error), do: %{type: "error", message: inspect(error)}

  # Handle step result from pipeline model
  defp handle_result({:ok, new_data}, ctx) when is_run_data(new_data) do
    new_data = without_sleep_marker(new_data)

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
    new_data = without_sleep_marker(new_data)

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

  # An error with attempts left parks the run until the backoff has passed,
  # freeing the worker; the next claim runs the next attempt.
  defp handle_result({:error, error}, ctx) do
    %{
      step: step,
      step_exec: step_exec,
      logs: logs,
      duration_ms: duration_ms,
      attempt: attempt,
      max_attempts: max_attempts,
      deadline: deadline,
      config: config
    } = ctx

    if attempt < max_attempts and not past?(deadline) do
      {:ok, _} = fail_step_execution(config, step_exec, error, logs, duration_ms)

      backoff_ms = backoff_ms(step, attempt)

      :telemetry.execute(
        [:durable, :step, :retry],
        %{backoff_ms: backoff_ms},
        config
        |> step_span_meta(step_exec.workflow_id, step, attempt, max_attempts)
        |> Map.put(:error, error_summary(error))
      )

      {:park, backoff_ms}
    else
      give_up(error, ctx)
    end
  end

  # The step asks to run again later, without using an attempt.
  defp handle_result({:snooze, ms}, ctx) when is_integer(ms) and ms >= 0,
    do: snooze(ms, nil, ctx)

  defp handle_result({:snooze, ms, reason}, ctx) when is_integer(ms) and ms >= 0,
    do: snooze(ms, reason_text(reason), ctx)

  # The step says retrying won't help: fail now, whatever attempts are left.
  defp handle_result({:fail, error}, ctx), do: give_up(error, ctx)

  # The step says the run should stop: the executor cancels the scope's run
  # (nil = the default for where the step runs).
  defp handle_result({:cancel, reason}, ctx), do: cancel(reason, nil, ctx)

  defp handle_result({:cancel, reason, [scope: scope]}, ctx) when scope in @cancel_scopes,
    do: cancel(reason, scope, ctx)

  # Handle invalid return (not {:ok, map} or {:goto, ...})
  defp handle_result(other, ctx) do
    %{step_exec: step_exec, logs: logs, duration_ms: duration_ms, config: config} = ctx

    error = %{
      type: "invalid_step_return",
      message:
        "Step must return {:ok, map}, {:goto, :step, map}, {:error, reason}, " <>
          "{:fail, reason}, {:snooze, ms}, {:snooze, ms, reason}, {:cancel, reason} or " <>
          "{:cancel, reason, scope: :run | :workflow | :root}, " <>
          "got: #{inspect(other)}"
    }

    {:ok, _} = fail_step_execution(config, step_exec, error, logs, duration_ms)
    {:error, error}
  end

  # The marker is for the step that slept. Carried on in the data, it would
  # reach a parallel branch's input and overwrite that branch's own marker, so
  # the branch would sleep again every time it woke.
  defp without_sleep_marker(data),
    do: Map.drop(data, [:__sleep_satisfied__, "__sleep_satisfied__"])

  defp give_up(error, ctx) do
    %{step_exec: step_exec, logs: logs, duration_ms: duration_ms, config: config} = ctx
    {:ok, _} = fail_step_execution(config, step_exec, error, logs, duration_ms)
    {:error, error}
  end

  defp cancel(reason, scope, ctx) do
    %{step_exec: step_exec, logs: logs, duration_ms: duration_ms, config: config} = ctx
    reason = reason_text(reason)
    error = %{type: "cancelled", message: reason}
    {:ok, _} = fail_step_execution(config, step_exec, error, logs, duration_ms, :cancelled)
    {:cancel, reason, scope}
  end

  defp snooze(ms, reason, ctx) do
    %{step: step, step_exec: step_exec, logs: logs, duration_ms: duration_ms, config: config} =
      ctx

    %{attempt: attempt, max_attempts: max_attempts} = ctx

    error =
      if reason,
        do: %{type: "snoozed", message: reason, snooze_ms: ms},
        else: %{type: "snoozed", snooze_ms: ms}

    {:ok, _} = fail_step_execution(config, step_exec, error, logs, duration_ms, :snoozed)

    :telemetry.execute(
      [:durable, :step, :snooze],
      %{snooze_ms: ms},
      config
      |> step_span_meta(step_exec.workflow_id, step, attempt, max_attempts)
      |> Map.put(:reason, reason)
    )

    {:park, ms}
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

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
         |> Durable.Executor.cas_update!(config) do
      {:ok, updated} = ok ->
        DurablePubSub.broadcast_step(config, :step_waiting, step_event(updated))
        ok

      other ->
        other
    end
  end

  # An attempt's ending is written with cas_update!: recovery or a cancel may
  # have closed the row while the body ran, and then this attempt is over. The
  # worker stops here, as for any run that's been taken from it.
  defp complete_step_execution(config, step_exec, output, logs, duration_ms) do
    serializable_output = serialize_output(output)

    case step_exec
         |> StepExecution.complete_changeset(serializable_output, logs, duration_ms)
         |> Durable.Executor.cas_update!(config) do
      {:ok, updated} = ok ->
        DurablePubSub.broadcast_step(config, :step_completed, step_event(updated))
        ok

      other ->
        other
    end
  end

  defp fail_step_execution(config, step_exec, error, logs, duration_ms, status \\ :failed) do
    # Sanitize the error map — exception payloads frequently carry tuples
    # (e.g., FunctionClauseError args), PIDs, refs, and functions in the
    # stacktrace area, none of which can survive a JSONB write. Mirror the
    # defense applied to workflow-level mark_failed in lib/durable/executor.ex.
    safe_error = Durable.Executor.storable_error(error)

    case step_exec
         |> StepExecution.fail_changeset(safe_error, logs, duration_ms, status)
         |> Durable.Executor.cas_update!(config) do
      {:ok, updated} = ok ->
        kind = :"step_#{status}"
        DurablePubSub.broadcast_step(config, kind, step_event(updated))
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
  @doc false
  @spec serialize_output(term()) :: map() | nil
  def serialize_output(nil), do: nil

  def serialize_output(output) do
    case Durable.Executor.sanitize_for_json(output) do
      map when is_map(map) and not is_struct(map) -> map
      value -> %{value: value}
    end
  end
end
