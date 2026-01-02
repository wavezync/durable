defmodule Durable.Executor do
  @moduledoc """
  The main workflow executor.

  Responsible for:
  - Starting new workflow executions
  - Executing workflow steps sequentially
  - Managing workflow state and context
  - Handling workflow suspension and resumption
  """

  alias Durable.Context
  alias Durable.Definition.Workflow
  alias Durable.Executor.StepRunner
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

  require Logger

  @doc """
  Starts a new workflow execution.

  ## Options

  - `:workflow` - The workflow name (optional, uses default if not specified)
  - `:queue` - The queue to use (default: "default")
  - `:priority` - Priority level (default: 0)
  - `:scheduled_at` - Schedule for future execution

  ## Returns

  - `{:ok, workflow_id}` on success
  - `{:error, reason}` on failure
  """
  @spec start_workflow(module(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_workflow(module, input, opts \\ []) do
    with {:ok, workflow_def} <- get_workflow_definition(module, opts),
         {:ok, execution} <- create_execution(module, workflow_def, input, opts) do
      # For inline/synchronous execution (useful for testing)
      if Keyword.get(opts, :inline, false) do
        execute_workflow(execution.id)
      end

      # Otherwise, the queue poller will pick up the job
      {:ok, execution.id}
    end
  end

  @doc """
  Cancels a running or pending workflow.
  """
  @spec cancel_workflow(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def cancel_workflow(workflow_id, reason \\ nil) do
    case Repo.get(WorkflowExecution, workflow_id) do
      nil ->
        {:error, :not_found}

      execution when execution.status in [:pending, :running, :waiting] ->
        error = if reason, do: %{type: "cancelled", message: reason}, else: %{type: "cancelled"}

        execution
        |> WorkflowExecution.status_changeset(:cancelled, %{
          error: error,
          completed_at: DateTime.utc_now()
        })
        |> Repo.update()

        :ok

      _execution ->
        {:error, :already_completed}
    end
  end

  @doc """
  Executes a workflow by ID.

  This is called internally by queue workers or directly for immediate execution.
  """
  @spec execute_workflow(String.t()) :: {:ok, map()} | {:error, term()}
  def execute_workflow(workflow_id) do
    with {:ok, execution} <- load_execution(workflow_id),
         {:ok, workflow_def} <- get_workflow_definition_from_execution(execution),
         {:ok, execution} <- mark_running(execution) do
      # Initialize context
      Context.restore_context(execution.context, execution.input, execution.id)

      # Execute steps
      result = execute_steps(workflow_def.steps, execution)

      # Cleanup context
      Context.cleanup()

      result
    end
  end

  @doc """
  Resumes a waiting workflow.

  ## Options

  - `:inline` - If true, execute synchronously instead of via queue (default: false)
  """
  @spec resume_workflow(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resume_workflow(workflow_id, additional_context \\ %{}, opts \\ []) do
    with {:ok, execution} <- load_execution(workflow_id),
         true <- execution.status == :waiting || {:error, :not_waiting} do
      # Merge additional context
      new_context = Map.merge(execution.context || %{}, additional_context)

      execution
      |> Ecto.Changeset.change(
        context: new_context,
        status: :pending,
        locked_by: nil,
        locked_at: nil
      )
      |> Repo.update()

      # For inline/synchronous execution (useful for testing)
      if Keyword.get(opts, :inline, false) do
        execute_workflow(workflow_id)
      end

      # Otherwise, the queue poller will pick up the job
      {:ok, workflow_id}
    end
  end

  # Private functions

  defp get_workflow_definition(module, opts) do
    case Keyword.get(opts, :workflow) do
      nil ->
        module.__default_workflow__()

      name ->
        module.__workflow_definition__(name)
    end
  rescue
    UndefinedFunctionError ->
      {:error, :not_a_workflow_module}
  end

  defp get_workflow_definition_from_execution(execution) do
    module = String.to_existing_atom(execution.workflow_module)
    module.__workflow_definition__(execution.workflow_name)
  rescue
    ArgumentError ->
      {:error, :module_not_found}
  end

  defp create_execution(module, %Workflow{} = workflow_def, input, opts) do
    attrs = %{
      workflow_module: inspect(module),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: Keyword.get(opts, :queue, "default") |> to_string(),
      priority: Keyword.get(opts, :priority, 0),
      input: input,
      context: %{},
      scheduled_at: Keyword.get(opts, :scheduled_at)
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> Repo.insert()
  end

  defp load_execution(workflow_id) do
    case Repo.get(WorkflowExecution, workflow_id) do
      nil -> {:error, :not_found}
      execution -> {:ok, execution}
    end
  end

  defp mark_running(execution) do
    execution
    |> WorkflowExecution.status_changeset(:running, %{started_at: DateTime.utc_now()})
    |> Repo.update()
  end

  defp execute_steps(steps, execution) do
    # Find the starting point (for resumed workflows)
    {steps_to_run, _skipped} =
      if execution.current_step do
        # Find and skip to current step
        current_step_atom = String.to_existing_atom(execution.current_step)
        Enum.split_while(steps, fn step -> step.name != current_step_atom end)
      else
        {steps, []}
      end

    # Build step index for validation
    step_index = build_step_index(steps)

    # Execute steps with decision support
    case execute_steps_recursive(steps_to_run, execution, step_index) do
      {:ok, exec} ->
        mark_completed(exec)

      {:waiting, exec} ->
        {:ok, exec}

      {:error, _} = error ->
        error
    end
  end

  defp build_step_index(steps) do
    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, idx} -> {step.name, idx} end)
    |> Map.new()
  end

  defp execute_steps_recursive([], execution, _step_index) do
    {:ok, execution}
  end

  defp execute_steps_recursive([step | remaining_steps], execution, step_index) do
    # Handle branch step type specially
    if step.type == :branch do
      execute_branch(step, remaining_steps, execution, step_index)
    else
      execute_regular_step(step, remaining_steps, execution, step_index)
    end
  end

  defp execute_regular_step(step, remaining_steps, execution, step_index) do
    # Update current step
    {:ok, exec} = update_current_step(execution, step.name)

    case StepRunner.execute(step, exec.id) do
      {:ok, _output} ->
        # Save context and continue to next step
        {:ok, exec} = save_context(exec)
        execute_steps_recursive(remaining_steps, exec, step_index)

      {:decision, target_step} ->
        # Decision step wants to jump - find target in remaining steps
        {:ok, exec} = save_context(exec)

        case find_jump_target(target_step, remaining_steps, step.name, step_index) do
          {:ok, target_steps} ->
            execute_steps_recursive(target_steps, exec, step_index)

          {:error, reason} ->
            mark_failed(exec, decision_error(step.name, target_step, reason))
        end

      {:sleep, opts} ->
        {:waiting, handle_sleep(exec, opts) |> elem(1)}

      {:wait_for_event, opts} ->
        {:waiting, handle_wait_for_event(exec, opts) |> elem(1)}

      {:wait_for_input, opts} ->
        {:waiting, handle_wait_for_input(exec, opts) |> elem(1)}

      {:error, error} ->
        mark_failed(exec, error)
    end
  end

  defp execute_branch(branch_step, remaining_steps, execution, step_index) do
    {:ok, exec} = update_current_step(execution, branch_step.name)

    # Get branch configuration
    opts = branch_step.opts
    condition_fn = opts[:condition_fn]
    clauses = opts[:clauses]
    all_branch_steps = opts[:all_steps] || []

    # Evaluate the condition by calling the module function
    condition_value =
      try do
        apply(branch_step.module, condition_fn, [])
      rescue
        e ->
          {:error, Exception.message(e)}
      end

    case condition_value do
      {:error, error} ->
        mark_failed(exec, %{type: "branch_error", message: error})

      value ->
        # Find matching clause steps
        matching_steps = find_matching_clause_steps(value, clauses)

        # Save context before executing branch steps
        {:ok, exec} = save_context(exec)

        # Execute only the matching branch's steps
        case execute_branch_steps(matching_steps, remaining_steps, exec, step_index) do
          {:ok, exec} ->
            # Skip past all branch steps in remaining and continue
            after_branch = skip_branch_steps(remaining_steps, all_branch_steps)
            execute_steps_recursive(after_branch, exec, step_index)

          {:waiting, exec} ->
            {:waiting, exec}

          {:error, _} = error ->
            error
        end
    end
  end

  defp find_matching_clause_steps(value, clauses) do
    find_exact_match(value, clauses) || find_default_clause(clauses)
  end

  defp find_exact_match(value, clauses) do
    Enum.find_value(clauses, fn {{pattern, _idx}, steps} ->
      if pattern == value, do: steps
    end)
  end

  defp find_default_clause(clauses) do
    Enum.find_value(clauses, [], fn {{pattern, _idx}, steps} ->
      if pattern == :default, do: steps
    end)
  end

  defp execute_branch_steps(step_names, remaining_steps, execution, step_index) do
    # Find the actual step definitions from remaining_steps
    steps_to_execute =
      Enum.filter(remaining_steps, fn step ->
        step.name in step_names
      end)

    # Execute them in the order they appear in step_names
    ordered_steps =
      Enum.map(step_names, fn name ->
        Enum.find(steps_to_execute, fn s -> s.name == name end)
      end)
      |> Enum.reject(&is_nil/1)

    execute_branch_steps_sequential(ordered_steps, execution, step_index)
  end

  defp execute_branch_steps_sequential([], execution, _step_index) do
    {:ok, execution}
  end

  defp execute_branch_steps_sequential([step | rest], execution, step_index) do
    {:ok, exec} = update_current_step(execution, step.name)

    case StepRunner.execute(step, exec.id) do
      {:ok, _output} ->
        {:ok, exec} = save_context(exec)
        execute_branch_steps_sequential(rest, exec, step_index)

      {:sleep, opts} ->
        {:waiting, handle_sleep(exec, opts) |> elem(1)}

      {:wait_for_event, opts} ->
        {:waiting, handle_wait_for_event(exec, opts) |> elem(1)}

      {:wait_for_input, opts} ->
        {:waiting, handle_wait_for_input(exec, opts) |> elem(1)}

      {:error, error} ->
        mark_failed(exec, error)
    end
  end

  defp skip_branch_steps(remaining_steps, all_branch_step_names) do
    Enum.reject(remaining_steps, fn step ->
      step.name in all_branch_step_names
    end)
  end

  defp find_jump_target(target_step, remaining_steps, current_step, step_index) do
    with :ok <- validate_target_exists(target_step, step_index),
         :ok <- validate_not_self(target_step, current_step),
         :ok <- validate_forward_jump(target_step, current_step, step_index) do
      find_target_in_remaining(target_step, remaining_steps)
    end
  end

  defp validate_target_exists(target_step, step_index) do
    if Map.has_key?(step_index, target_step) do
      :ok
    else
      {:error, "Target step :#{target_step} does not exist in workflow"}
    end
  end

  defp validate_not_self(target_step, current_step) do
    if target_step == current_step do
      {:error, "Cannot jump to self (:#{current_step})"}
    else
      :ok
    end
  end

  defp validate_forward_jump(target_step, current_step, step_index) do
    if Map.get(step_index, target_step) <= Map.get(step_index, current_step) do
      {:error,
       "Cannot jump backwards from :#{current_step} to :#{target_step}. " <>
         "Decision steps can only jump forward."}
    else
      :ok
    end
  end

  defp find_target_in_remaining(target_step, remaining_steps) do
    case Enum.drop_while(remaining_steps, fn s -> s.name != target_step end) do
      [] -> {:error, "Target step :#{target_step} not found in remaining steps"}
      target_steps -> {:ok, target_steps}
    end
  end

  defp decision_error(from_step, target_step, reason) do
    %{
      type: "decision_error",
      message: reason,
      from_step: Atom.to_string(from_step),
      target_step: Atom.to_string(target_step)
    }
  end

  defp update_current_step(execution, step_name) do
    execution
    |> Ecto.Changeset.change(current_step: Atom.to_string(step_name))
    |> Repo.update()
  end

  defp save_context(execution) do
    current_context = Context.get_current_context()

    execution
    |> Ecto.Changeset.change(context: current_context)
    |> Repo.update()
  end

  defp mark_completed(execution) do
    current_context = Context.get_current_context()

    {:ok, execution} =
      execution
      |> WorkflowExecution.status_changeset(:completed, %{
        context: current_context,
        completed_at: DateTime.utc_now(),
        current_step: nil
      })
      |> Ecto.Changeset.change(locked_by: nil, locked_at: nil)
      |> Repo.update()

    {:ok, execution}
  end

  defp mark_failed(execution, error) do
    current_context = Context.get_current_context()

    execution
    |> WorkflowExecution.status_changeset(:failed, %{
      context: current_context,
      error: error,
      completed_at: DateTime.utc_now()
    })
    |> Ecto.Changeset.change(locked_by: nil, locked_at: nil)
    |> Repo.update()

    {:error, error}
  end

  defp handle_sleep(execution, opts) do
    wake_at = calculate_wake_time(opts)

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting, scheduled_at: wake_at)
      |> Repo.update()

    {:waiting, execution}
  end

  defp handle_wait_for_event(execution, _opts) do
    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting)
      |> Repo.update()

    {:waiting, execution}
  end

  defp handle_wait_for_input(execution, _opts) do
    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting)
      |> Repo.update()

    {:waiting, execution}
  end

  defp calculate_wake_time(opts) do
    cond do
      Keyword.has_key?(opts, :until) ->
        opts[:until]

      Keyword.has_key?(opts, :seconds) ->
        DateTime.add(DateTime.utc_now(), opts[:seconds], :second)

      Keyword.has_key?(opts, :minutes) ->
        DateTime.add(DateTime.utc_now(), opts[:minutes] * 60, :second)

      Keyword.has_key?(opts, :hours) ->
        DateTime.add(DateTime.utc_now(), opts[:hours] * 3600, :second)

      Keyword.has_key?(opts, :days) ->
        DateTime.add(DateTime.utc_now(), opts[:days] * 86_400, :second)

      true ->
        DateTime.add(DateTime.utc_now(), 60, :second)
    end
  end
end
