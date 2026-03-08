defmodule Durable.Executor do
  @moduledoc """
  The main workflow executor.

  Responsible for:
  - Starting new workflow executions
  - Executing workflow steps sequentially
  - Managing workflow state and context
  - Handling workflow suspension and resumption
  """

  alias Durable.Config
  alias Durable.Context
  alias Durable.Definition.Workflow
  alias Durable.Executor.CompensationRunner
  alias Durable.Executor.StepRunner
  alias Durable.Repo
  alias Durable.Storage.Schemas.PendingEvent
  alias Durable.Storage.Schemas.PendingInput
  alias Durable.Storage.Schemas.StepExecution
  alias Durable.Storage.Schemas.WaitGroup
  alias Durable.Storage.Schemas.WorkflowExecution

  import Ecto.Query

  require Logger

  @doc """
  Starts a new workflow execution.

  ## Options

  - `:workflow` - The workflow name (optional, uses default if not specified)
  - `:queue` - The queue to use (default: "default")
  - `:priority` - Priority level (default: 0)
  - `:scheduled_at` - Schedule for future execution
  - `:durable` - The Durable instance name (default: Durable)

  ## Returns

  - `{:ok, workflow_id}` on success
  - `{:error, reason}` on failure
  """
  @spec start_workflow(module(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_workflow(module, input, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)

    with {:ok, workflow_def} <- get_workflow_definition(module, opts),
         {:ok, execution} <- create_execution(config, module, workflow_def, input, opts) do
      # For inline/synchronous execution (useful for testing)
      if Keyword.get(opts, :inline, false) do
        execute_workflow(execution.id, config)
      end

      # Otherwise, the queue poller will pick up the job
      {:ok, execution.id}
    end
  end

  @doc """
  Cancels a running or pending workflow.
  """
  @spec cancel_workflow(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def cancel_workflow(workflow_id, reason \\ nil, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)

    case Repo.get(config, WorkflowExecution, workflow_id) do
      nil ->
        {:error, :not_found}

      execution when execution.status in [:pending, :running, :waiting] ->
        error = if reason, do: %{type: "cancelled", message: reason}, else: %{type: "cancelled"}

        execution
        |> WorkflowExecution.status_changeset(:cancelled, %{
          error: error,
          completed_at: DateTime.utc_now()
        })
        |> Repo.update(config)

        # Cascade cancel to child workflows
        cancel_child_workflows(config, workflow_id)

        :ok

      _execution ->
        {:error, :already_completed}
    end
  end

  @doc """
  Executes a workflow by ID.

  This is called internally by queue workers or directly for immediate execution.
  """
  @spec execute_workflow(String.t(), Config.t()) ::
          {:ok, map()} | {:waiting, map()} | {:error, term()}
  def execute_workflow(workflow_id, %Config{} = config) do
    with {:ok, execution} <- load_execution(config, workflow_id),
         {:ok, workflow_def} <- get_workflow_definition_from_execution(execution),
         {:ok, execution} <- mark_running(config, execution) do
      # Set workflow ID for logging/observability
      Context.set_workflow_id(execution.id)

      # Check if this is a single-step parallel child execution
      parallel_step_flag =
        Map.get(execution.context, "__parallel_step") ||
          Map.get(execution.context, :__parallel_step)

      if parallel_step_flag do
        result = execute_parallel_step(execution, workflow_def, config)
        Context.cleanup()
        result
      else
        # Pipeline model: start with workflow input or restored context
        initial_data =
          if execution.context && execution.context != %{} do
            atomize_keys(execution.context)
          else
            execution.input
          end

        # Execute steps with pipeline data flow
        result = execute_steps(workflow_def.steps, execution, config, initial_data)

        # Cleanup
        Context.cleanup()

        result
      end
    end
  end

  # Atomize top-level keys in map (for context restored from DB)
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  @doc """
  Resumes a waiting workflow.

  ## Options

  - `:inline` - If true, execute synchronously instead of via queue (default: false)
  - `:durable` - The Durable instance name (default: Durable)
  """
  @spec resume_workflow(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resume_workflow(workflow_id, additional_context \\ %{}, opts \\ []) do
    durable_name = Keyword.get(opts, :durable, Durable)
    config = Config.get(durable_name)

    with {:ok, execution} <- load_execution(config, workflow_id),
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
      |> Repo.update(config)

      # For inline/synchronous execution (useful for testing)
      if Keyword.get(opts, :inline, false) do
        execute_workflow(workflow_id, config)
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

  defp create_execution(config, module, %Workflow{} = workflow_def, input, opts) do
    attrs = %{
      workflow_module: Atom.to_string(module),
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
    |> Repo.insert(config)
  end

  defp load_execution(config, workflow_id) do
    case Repo.get(config, WorkflowExecution, workflow_id) do
      nil -> {:error, :not_found}
      execution -> {:ok, execution}
    end
  end

  defp mark_running(config, execution) do
    execution
    |> WorkflowExecution.status_changeset(:running, %{started_at: DateTime.utc_now()})
    |> Repo.update(config)
  end

  defp execute_steps(steps, execution, config, initial_data) do
    # Get workflow definition for compensation lookup
    {:ok, workflow_def} = get_workflow_definition_from_execution(execution)

    # Find the starting point (for resumed workflows)
    {_already_completed, steps_to_run} =
      if execution.current_step do
        # Find and skip to current step
        current_step_atom = String.to_existing_atom(execution.current_step)
        Enum.split_while(steps, fn step -> step.name != current_step_atom end)
      else
        {[], steps}
      end

    # Build step index for validation
    step_index = build_step_index(steps)

    # Execute steps with pipeline data flow
    case execute_steps_recursive(
           steps_to_run,
           execution,
           step_index,
           workflow_def,
           config,
           initial_data
         ) do
      {:ok, exec, final_data} ->
        mark_completed(config, exec, final_data)

      {:waiting, exec} ->
        {:waiting, exec}

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

  defp execute_steps_recursive([], execution, _step_index, _workflow_def, _config, data) do
    {:ok, execution, data}
  end

  defp execute_steps_recursive(
         [step | remaining_steps],
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    # Handle special step types
    case step.type do
      :branch ->
        execute_branch(step, remaining_steps, execution, step_index, workflow_def, config, data)

      :parallel ->
        execute_parallel(step, remaining_steps, execution, step_index, workflow_def, config, data)

      _ ->
        execute_regular_step(
          step,
          remaining_steps,
          execution,
          step_index,
          workflow_def,
          config,
          data
        )
    end
  end

  defp execute_regular_step(
         step,
         remaining_steps,
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    # Update current step
    {:ok, exec} = update_current_step(config, execution, step.name)

    case StepRunner.execute(step, data, exec.id, config) do
      {:ok, new_data} ->
        # Save data as context and continue to next step
        # save_data_as_context merges orchestration keys from process dict
        {:ok, exec} = save_data_as_context(config, exec, new_data)
        # Pass the DB-persisted context forward (includes orchestration keys)
        execute_steps_recursive(
          remaining_steps,
          exec,
          step_index,
          workflow_def,
          config,
          exec.context
        )

      {:decision, target_step, new_data} ->
        handle_decision_result(
          exec,
          target_step,
          new_data,
          remaining_steps,
          step,
          step_index,
          workflow_def,
          config
        )

      {wait_type, opts}
      when wait_type in [:sleep, :wait_for_event, :wait_for_input, :wait_for_any, :wait_for_all] ->
        # Save current data before waiting
        {:ok, exec} = save_data_as_context(config, exec, data)
        handle_wait_result(config, exec, wait_type, opts)

      {:call_workflow, opts} ->
        {:ok, exec} = save_data_as_context(config, exec, data)
        handle_call_workflow(config, exec, opts)

      {:error, error} ->
        handle_step_failure(exec, error, workflow_def, config)
    end
  end

  defp handle_decision_result(
         exec,
         target_step,
         data,
         remaining_steps,
         step,
         step_index,
         workflow_def,
         config
       ) do
    {:ok, exec} = save_data_as_context(config, exec, data)

    case find_jump_target(target_step, remaining_steps, step.name, step_index) do
      {:ok, target_steps} ->
        execute_steps_recursive(target_steps, exec, step_index, workflow_def, config, data)

      {:error, reason} ->
        handle_step_failure(
          exec,
          decision_error(step.name, target_step, reason),
          workflow_def,
          config
        )
    end
  end

  defp handle_wait_result(config, exec, :sleep, opts),
    do: {:waiting, handle_sleep(config, exec, opts) |> elem(1)}

  defp handle_wait_result(config, exec, :wait_for_event, opts),
    do: {:waiting, handle_wait_for_event(config, exec, opts) |> elem(1)}

  defp handle_wait_result(config, exec, :wait_for_input, opts),
    do: {:waiting, handle_wait_for_input(config, exec, opts) |> elem(1)}

  defp handle_wait_result(config, exec, :wait_for_any, opts),
    do: {:waiting, handle_wait_for_any(config, exec, opts) |> elem(1)}

  defp handle_wait_result(config, exec, :wait_for_all, opts),
    do: {:waiting, handle_wait_for_all(config, exec, opts) |> elem(1)}

  defp handle_wait_result(config, exec, :call_workflow, opts),
    do: handle_call_workflow(config, exec, opts)

  # ============================================================================
  # Workflow Orchestration (call_workflow)
  # ============================================================================

  defp handle_call_workflow(config, execution, opts) do
    child_id = Keyword.fetch!(opts, :child_id)
    event_name = Durable.Orchestration.child_event_name(child_id)
    timeout_at = calculate_timeout_at(opts)

    # Create pending event to wait for child completion
    attrs = %{
      workflow_id: execution.id,
      event_name: event_name,
      step_name: execution.current_step,
      timeout_at: timeout_at,
      timeout_value: serialize_timeout_value(Keyword.get(opts, :timeout_value, :child_timeout)),
      wait_type: :single
    }

    {:ok, _} =
      %PendingEvent{}
      |> PendingEvent.changeset(attrs)
      |> Repo.insert(config)

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting)
      |> Repo.update(config)

    {:waiting, execution}
  end

  defp execute_branch(
         branch_step,
         remaining_steps,
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    {:ok, exec} = update_current_step(config, execution, branch_step.name)

    # Get branch configuration
    opts = branch_step.opts
    # In the new DSL, the condition function is stored in body_fn
    condition_fn = branch_step.body_fn
    clauses = opts[:clauses]
    all_branch_steps = opts[:all_steps] || []

    # Evaluate the condition by calling the function with data
    condition_value =
      try do
        if is_function(condition_fn, 1) do
          condition_fn.(data)
        else
          # Legacy: fall back to opts[:condition_fn]
          legacy_fn = opts[:condition_fn]

          if is_function(legacy_fn, 1) do
            legacy_fn.(data)
          else
            apply(branch_step.module, legacy_fn, [data])
          end
        end
      rescue
        e ->
          {:error, Exception.message(e)}
      end

    case condition_value do
      {:error, error} ->
        handle_step_failure(exec, %{type: "branch_error", message: error}, workflow_def, config)

      value ->
        # Find matching clause steps
        matching_steps = find_matching_clause_steps(value, clauses)

        # Save data before executing branch steps
        {:ok, exec} = save_data_as_context(config, exec, data)

        # Execute only the matching branch's steps
        case execute_branch_steps(
               matching_steps,
               remaining_steps,
               exec,
               step_index,
               workflow_def,
               config,
               data
             ) do
          {:ok, exec, branch_data} ->
            # Skip past all branch steps in remaining and continue with updated data
            after_branch = skip_branch_steps(remaining_steps, all_branch_steps)

            execute_steps_recursive(
              after_branch,
              exec,
              step_index,
              workflow_def,
              config,
              branch_data
            )

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

  defp execute_branch_steps(
         step_names,
         remaining_steps,
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
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

    execute_branch_steps_sequential(
      ordered_steps,
      execution,
      step_index,
      workflow_def,
      config,
      data
    )
  end

  defp execute_branch_steps_sequential([], execution, _step_index, _workflow_def, _config, data) do
    {:ok, execution, data}
  end

  defp execute_branch_steps_sequential(
         [step | rest],
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    {:ok, exec} = update_current_step(config, execution, step.name)

    case StepRunner.execute(step, data, exec.id, config) do
      {:ok, new_data} ->
        {:ok, exec} = save_data_as_context(config, exec, new_data)

        execute_branch_steps_sequential(
          rest,
          exec,
          step_index,
          workflow_def,
          config,
          exec.context
        )

      {:decision, target_step, new_data} ->
        # Decisions within branches - save and return for outer handler
        {:ok, exec} = save_data_as_context(config, exec, new_data)
        {:decision, exec, target_step, new_data}

      {:sleep, opts} ->
        {:ok, exec} = save_data_as_context(config, exec, data)
        {:waiting, handle_sleep(config, exec, opts) |> elem(1)}

      {:wait_for_event, opts} ->
        {:ok, exec} = save_data_as_context(config, exec, data)
        {:waiting, handle_wait_for_event(config, exec, opts) |> elem(1)}

      {:wait_for_input, opts} ->
        {:ok, exec} = save_data_as_context(config, exec, data)
        {:waiting, handle_wait_for_input(config, exec, opts) |> elem(1)}

      {:wait_for_any, opts} ->
        {:ok, exec} = save_data_as_context(config, exec, data)
        {:waiting, handle_wait_for_any(config, exec, opts) |> elem(1)}

      {:wait_for_all, opts} ->
        {:ok, exec} = save_data_as_context(config, exec, data)
        {:waiting, handle_wait_for_all(config, exec, opts) |> elem(1)}

      {:call_workflow, opts} ->
        {:ok, exec} = save_data_as_context(config, exec, data)
        handle_call_workflow(config, exec, opts)

      {:error, error} ->
        handle_step_failure(exec, error, workflow_def, config)
    end
  end

  defp skip_branch_steps(remaining_steps, all_branch_step_names) do
    Enum.reject(remaining_steps, fn step ->
      step.name in all_branch_step_names
    end)
  end

  # ============================================================================
  # Parallel Execution
  # ============================================================================

  defp execute_parallel(
         parallel_step,
         remaining_steps,
         execution,
         step_index,
         workflow_def,
         config,
         data
       ) do
    {:ok, exec} = update_current_step(config, execution, parallel_step.name)

    # Get parallel configuration
    opts = parallel_step.opts
    parallel_step_names = opts[:steps] || []
    all_parallel_steps = opts[:all_steps] || []
    error_strategy = opts[:error_strategy] || :fail_fast
    into_fn = opts[:into_fn]

    # Find actual step definitions for parallel steps
    ordered_steps = find_ordered_steps(remaining_steps, parallel_step_names)

    # Save data before parallel execution
    {:ok, exec} = save_data_as_context(config, exec, data)

    # Check if we're resuming after fan-in (all children completed)
    # Context may have atom or string keys depending on whether it came from
    # a changeset (atom) or from DB deserialization (string)
    has_children =
      Map.get(exec.context, "__parallel_children") ||
        Map.get(exec.context, :__parallel_children)

    if has_children do
      collect_parallel_results(exec, data, into_fn, error_strategy, %{
        remaining_steps: remaining_steps,
        all_parallel_steps: all_parallel_steps,
        step_index: step_index,
        workflow_def: workflow_def,
        config: config,
        parallel_step_name: parallel_step.name
      })
    else
      # Fan-out: create child executions + WaitGroup
      fan_out_parallel(exec, ordered_steps, data, config, error_strategy)
    end
  end

  # Fan-out: create child workflow executions for each parallel step and wait
  defp fan_out_parallel(exec, ordered_steps, data, config, error_strategy) do
    parent_queue = exec.queue || "default"

    # Create child executions for each parallel step
    children_meta =
      Enum.map(ordered_steps, fn step ->
        returns_key = get_returns_key(step)
        child_queue = step.opts[:queue] || parent_queue

        {:ok, child} = create_parallel_child(exec, step, data, child_queue, config)
        {child.id, Atom.to_string(step.name), returns_key}
      end)

    # Build event names and children metadata map
    event_names = Enum.map(children_meta, fn {id, _, _} -> "__parallel_done:#{id}" end)

    children_map =
      Map.new(children_meta, fn {id, step_name, returns_key} ->
        returns_str = if is_atom(returns_key), do: Atom.to_string(returns_key), else: returns_key
        {id, %{"step_name" => step_name, "returns_key" => returns_str}}
      end)

    # Create WaitGroup + PendingEvents for all children
    {:ok, wait_group} =
      %WaitGroup{}
      |> WaitGroup.changeset(%{
        workflow_id: exec.id,
        step_name: exec.current_step,
        wait_type: :all,
        event_names: event_names
      })
      |> Repo.insert(config)

    Enum.each(event_names, fn event_name ->
      {:ok, _} =
        %PendingEvent{}
        |> PendingEvent.changeset(%{
          workflow_id: exec.id,
          event_name: event_name,
          step_name: exec.current_step,
          wait_group_id: wait_group.id,
          wait_type: :all
        })
        |> Repo.insert(config)
    end)

    # Store parallel metadata in parent context for resume
    parallel_context = %{
      "__parallel_children" => children_map,
      "__parallel_wait_group_id" => wait_group.id,
      "__parallel_error_strategy" => Atom.to_string(error_strategy)
    }

    {:ok, exec} =
      exec
      |> Ecto.Changeset.change(
        context: Map.merge(exec.context || %{}, parallel_context),
        status: :waiting
      )
      |> Repo.update(config)

    {:waiting, exec}
  end

  # Create a child workflow execution for a single parallel step
  defp create_parallel_child(parent_exec, step, data, queue, config) do
    attrs = %{
      workflow_module: parent_exec.workflow_module,
      workflow_name: parent_exec.workflow_name,
      status: :pending,
      queue: to_string(queue),
      priority: 0,
      input: data,
      context: %{"__parallel_step" => Atom.to_string(step.name)},
      parent_workflow_id: parent_exec.id,
      current_step: Atom.to_string(step.name)
    }

    %WorkflowExecution{}
    |> WorkflowExecution.changeset(attrs)
    |> Repo.insert(config)
  end

  # Execute a single parallel step (called when a child execution is picked up)
  defp execute_parallel_step(execution, workflow_def, config) do
    step_name_str =
      Map.get(execution.context, "__parallel_step") ||
        Map.get(execution.context, :__parallel_step)

    step_name = String.to_existing_atom(step_name_str)

    step_def = Enum.find(workflow_def.steps, &(&1.name == step_name))

    if is_nil(step_def) do
      mark_failed(config, execution, %{
        type: "parallel_step_not_found",
        message: "Step #{step_name} not found in workflow"
      })
    else
      # Use parent's input as the pipeline data (stored in child's input)
      data = atomize_keys(execution.input)

      case StepRunner.execute(step_def, data, execution.id, config) do
        {:ok, output_data} ->
          mark_completed(config, execution, output_data)

        {:error, error} ->
          mark_failed(config, execution, normalize_error(error))

        {wait_type, wait_opts}
        when wait_type in [:sleep, :wait_for_event, :wait_for_input, :wait_for_any, :wait_for_all] ->
          {:ok, exec} = save_data_as_context(config, execution, data)
          handle_wait_result(config, exec, wait_type, wait_opts)

        {:call_workflow, call_opts} ->
          {:ok, exec} = save_data_as_context(config, execution, data)
          handle_call_workflow(config, exec, call_opts)

        {:decision, _target, _data} ->
          mark_failed(config, execution, %{
            type: "parallel_decision_not_supported",
            message: "decisions not supported in parallel blocks"
          })
      end
    end
  end

  # Collect results from completed child executions (called when parent resumes)
  defp collect_parallel_results(exec, _base_data, into_fn, _error_strategy, opts) do
    %{
      remaining_steps: remaining_steps,
      all_parallel_steps: all_parallel_steps,
      step_index: step_index,
      workflow_def: workflow_def,
      config: config,
      parallel_step_name: parallel_step_name
    } = opts

    children_map =
      Map.get(exec.context, "__parallel_children") ||
        Map.get(exec.context, :__parallel_children)

    error_strategy_str =
      Map.get(exec.context, "__parallel_error_strategy") ||
        Map.get(exec.context, :__parallel_error_strategy) ||
        "fail_fast"

    error_strategy = String.to_existing_atom(error_strategy_str)
    # When into_fn is provided, always collect all results
    effective_strategy = if into_fn, do: :complete_all, else: error_strategy

    # Load all child executions and build results
    results = build_results_from_children(children_map, config)

    # Clean parallel metadata from context before continuing
    # Drop both string and atom keys since context may have either
    clean_ctx =
      exec.context
      |> Map.drop([
        "__parallel_children",
        "__parallel_wait_group_id",
        "__parallel_error_strategy",
        :__parallel_children,
        :__parallel_wait_group_id,
        :__parallel_error_strategy
      ])
      |> atomize_keys()

    # Check for fail_fast
    errors = Enum.filter(results, fn {_key, result} -> match?({:error, _}, result) end)

    if effective_strategy == :fail_fast && errors != [] do
      {_key, {:error, first_error}} = hd(errors)
      handle_step_failure(exec, normalize_error(first_error), workflow_def, config)
    else
      handle_parallel_completion(results, clean_ctx, into_fn, %{
        remaining_steps: remaining_steps,
        all_parallel_steps: all_parallel_steps,
        exec: exec,
        step_index: step_index,
        workflow_def: workflow_def,
        config: config,
        parallel_step_name: parallel_step_name
      })
    end
  end

  # Build results map from child workflow executions
  defp build_results_from_children(children_map, config) do
    Map.new(children_map, fn {child_id, meta} ->
      returns_key = String.to_atom(meta["returns_key"])

      case Repo.get(config, WorkflowExecution, child_id) do
        %{status: :completed, context: ctx} ->
          {returns_key, {:ok, ctx}}

        %{status: status, error: error}
        when status in [:failed, :cancelled, :compensation_failed] ->
          {returns_key, {:error, error || %{type: "child_failed", message: "#{status}"}}}

        _ ->
          {returns_key, {:error, %{type: "child_incomplete", message: "child not finished"}}}
      end
    end)
  end

  defp find_ordered_steps(remaining_steps, step_names) do
    steps_to_execute =
      Enum.filter(remaining_steps, fn step -> step.name in step_names end)

    Enum.map(step_names, fn name ->
      Enum.find(steps_to_execute, fn s -> s.name == name end)
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Handle completion of parallel block - apply into_fn or add __results__
  # Uses opts map to reduce arity below credo's limit of 8
  defp handle_parallel_completion(results, base_ctx, into_fn, opts) do
    %{
      remaining_steps: remaining_steps,
      all_parallel_steps: all_parallel_steps,
      exec: exec,
      step_index: step_index,
      workflow_def: workflow_def,
      config: config,
      parallel_step_name: parallel_step_name
    } = opts

    case apply_parallel_into(into_fn, base_ctx, results) do
      {:ok, final_ctx} ->
        {:ok, exec} = save_data_as_context(config, exec, final_ctx)
        after_parallel = skip_parallel_steps(remaining_steps, all_parallel_steps)

        execute_steps_recursive(
          after_parallel,
          exec,
          step_index,
          workflow_def,
          config,
          final_ctx
        )

      {:goto, target_step, goto_ctx} ->
        {:ok, exec} = save_data_as_context(config, exec, goto_ctx)

        case find_jump_target(target_step, remaining_steps, parallel_step_name, step_index) do
          {:ok, target_steps} ->
            execute_steps_recursive(
              target_steps,
              exec,
              step_index,
              workflow_def,
              config,
              goto_ctx
            )

          {:error, reason} ->
            handle_step_failure(
              exec,
              %{type: "parallel_goto_error", message: reason},
              workflow_def,
              config
            )
        end

      {:error, error} ->
        handle_step_failure(exec, normalize_error(error), workflow_def, config)
    end
  end

  # Apply into function or default to __results__
  defp apply_parallel_into(nil, base_ctx, results) do
    # No into function - add results to __results__ key
    # Serialize tuples to lists for JSON storage
    serialized_results = serialize_parallel_results(results)
    {:ok, Map.put(base_ctx, :__results__, serialized_results)}
  end

  defp apply_parallel_into(into_fn, base_ctx, results) when is_function(into_fn, 2) do
    into_fn.(base_ctx, results)
  rescue
    e ->
      {:error,
       %{
         type: "parallel_into_error",
         message: Exception.message(e),
         stacktrace: Exception.format_stacktrace(__STACKTRACE__)
       }}
  end

  # Serialize tagged tuples to lists for JSON storage
  # {:ok, data} -> ["ok", data], {:error, reason} -> ["error", reason]
  defp serialize_parallel_results(results) do
    Map.new(results, fn {key, value} ->
      serialized_key = if is_atom(key), do: Atom.to_string(key), else: key

      serialized_value =
        case value do
          {:ok, data} -> ["ok", data]
          {:error, reason} -> ["error", serialize_error_reason(reason)]
          other -> other
        end

      {serialized_key, serialized_value}
    end)
  end

  # Serialize error reasons that might contain atoms
  defp serialize_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp serialize_error_reason(reason) when is_map(reason), do: reason
  defp serialize_error_reason(reason) when is_binary(reason), do: reason
  defp serialize_error_reason(reason), do: inspect(reason)

  # Normalize error to map format
  defp normalize_error(error) when is_map(error), do: error
  defp normalize_error(error) when is_binary(error), do: %{type: "error", message: error}

  defp normalize_error(error) when is_atom(error),
    do: %{type: "error", message: Atom.to_string(error)}

  defp normalize_error(error), do: %{type: "error", message: inspect(error)}

  # Get the returns key from step opts (default to original_name)
  defp get_returns_key(%{opts: opts}) do
    opts[:returns] || opts[:original_name]
  end

  defp skip_parallel_steps(remaining_steps, all_parallel_step_names) do
    Enum.reject(remaining_steps, fn step ->
      step.name in all_parallel_step_names
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

  defp update_current_step(config, execution, step_name) do
    execution
    |> Ecto.Changeset.change(current_step: Atom.to_string(step_name))
    |> Repo.update(config)
  end

  # Saves data as the workflow context in DB (for persistence/resume)
  # Also merges orchestration keys from process dict to ensure child workflow
  # references are persisted through DB round-trips
  defp save_data_as_context(config, execution, data) do
    merged = merge_orchestration_context(data)

    execution
    |> Ecto.Changeset.change(context: merged)
    |> Repo.update(config)
  end

  # Merge orchestration keys (__child:*, __fire_forget:*, __child_done:*) from
  # process dict into the data to persist. These keys are set by
  # Durable.Orchestration.call_workflow/start_workflow via put_context.
  defp merge_orchestration_context(data) do
    process_ctx = Process.get(:durable_context, %{})

    orchestration_keys =
      process_ctx
      |> Enum.filter(fn {key, _} -> orchestration_key?(key) end)
      |> Map.new()

    Map.merge(data, orchestration_keys)
  end

  defp orchestration_key?(key) when is_atom(key) do
    orchestration_key?(Atom.to_string(key))
  end

  defp orchestration_key?(key) when is_binary(key) do
    String.starts_with?(key, "__child:") or
      String.starts_with?(key, "__fire_forget:") or
      String.starts_with?(key, "__child_done:")
  end

  defp orchestration_key?(_), do: false

  defp mark_completed(config, execution, final_data) do
    {:ok, execution} =
      execution
      |> WorkflowExecution.status_changeset(:completed, %{
        context: final_data,
        completed_at: DateTime.utc_now(),
        current_step: nil
      })
      |> Ecto.Changeset.change(locked_by: nil, locked_at: nil)
      |> Repo.update(config)

    maybe_notify_parent(config, execution, :completed, final_data)

    {:ok, execution}
  end

  defp mark_failed(config, execution, error) do
    {:ok, execution} =
      execution
      |> WorkflowExecution.status_changeset(:failed, %{
        error: error,
        completed_at: DateTime.utc_now()
      })
      |> Ecto.Changeset.change(locked_by: nil, locked_at: nil)
      |> Repo.update(config)

    maybe_notify_parent(config, execution, :failed, error)

    {:error, error}
  end

  # ============================================================================
  # Parent Notification (Orchestration)
  # ============================================================================

  defp maybe_notify_parent(_config, %{parent_workflow_id: nil}, _status, _data), do: :ok

  defp maybe_notify_parent(config, execution, status, data) do
    # Check for parallel child notification first (uses __parallel_done: events)
    parallel_event_name = "__parallel_done:#{execution.id}"

    parallel_pending =
      Repo.one(
        config,
        from(p in PendingEvent,
          where:
            p.workflow_id == ^execution.parent_workflow_id and
              p.event_name == ^parallel_event_name and
              p.status == :pending
        )
      )

    if parallel_pending do
      notify_parallel_parent(config, execution, parallel_pending, status, data)
    else
      notify_orchestration_parent(config, execution, status, data)
    end
  end

  # Notify parent via WaitGroup (parallel child completion)
  defp notify_parallel_parent(config, execution, pending_event, status, data) do
    payload = Durable.Orchestration.build_result_payload(status, data)

    # Fulfill the pending event
    {:ok, _} =
      pending_event
      |> PendingEvent.receive_changeset(payload)
      |> Repo.update(config)

    # Update the WaitGroup and resume parent if all children are done
    maybe_complete_wait_group(config, pending_event, payload, execution.parent_workflow_id)

    :ok
  end

  defp maybe_complete_wait_group(_config, %{wait_group_id: nil}, _payload, _parent_id), do: :ok

  defp maybe_complete_wait_group(config, pending_event, payload, parent_id) do
    wait_group = Repo.get(config, WaitGroup, pending_event.wait_group_id)

    if wait_group && wait_group.status == :pending do
      {:ok, updated_group} =
        wait_group
        |> WaitGroup.add_event_changeset(pending_event.event_name, payload)
        |> Repo.update(config)

      if updated_group.status == :completed do
        resume_workflow(parent_id)
      end
    end
  end

  # Notify parent via orchestration (call_workflow child completion)
  defp notify_orchestration_parent(config, execution, status, data) do
    event_name = Durable.Orchestration.child_event_name(execution.id)
    payload = Durable.Orchestration.build_result_payload(status, data)

    # Find and fulfill the pending event on the parent workflow
    query =
      from(p in PendingEvent,
        where:
          p.workflow_id == ^execution.parent_workflow_id and
            p.event_name == ^event_name and
            p.status == :pending
      )

    case Repo.one(config, query) do
      nil ->
        # Parent not waiting (fire-and-forget case, or already timed out)
        :ok

      pending_event ->
        # Fulfill the pending event
        {:ok, _} =
          pending_event
          |> PendingEvent.receive_changeset(payload)
          |> Repo.update(config)

        # Find the child ref from parent's context to store result under the right key
        parent = Repo.get(config, WorkflowExecution, execution.parent_workflow_id)
        result_context = build_parent_result_context(parent, execution.id, payload)

        # Resume the parent workflow
        resume_workflow(execution.parent_workflow_id, result_context)
    end
  end

  # Build context update for parent with child result stored under the right key
  defp build_parent_result_context(parent, child_id, payload) do
    parent_context = parent.context || %{}

    # Find which ref this child belongs to by looking for __child:ref = child_id
    ref =
      Enum.find_value(parent_context, fn
        {"__child:" <> ref_str, ^child_id} -> ref_str
        _ -> nil
      end)

    if ref do
      %{
        "__child_done:#{ref}" => payload,
        Durable.Orchestration.child_event_name(child_id) => payload
      }
    else
      %{Durable.Orchestration.child_event_name(child_id) => payload}
    end
  end

  # ============================================================================
  # Cascade Cancellation (Orchestration)
  # ============================================================================

  defp cancel_child_workflows(config, parent_id) do
    query =
      from(w in WorkflowExecution,
        where: w.parent_workflow_id == ^parent_id,
        where: w.status in [:pending, :running, :waiting]
      )

    children = Repo.all(config, query)

    Enum.each(children, fn child ->
      cancel_workflow(child.id, "parent_cancelled", durable: config.name)
    end)
  end

  # ============================================================================
  # Compensation/Saga Support
  # ============================================================================

  # Handles step failure by running compensations if needed
  defp handle_step_failure(execution, error, workflow_def, config) do
    # Get the compensation stack from completed steps
    compensation_stack = build_compensation_stack(execution.id, workflow_def, config)

    if compensation_stack == [] do
      # No compensations to run - just mark as failed
      mark_failed(config, execution, error)
    else
      # Run compensations
      run_compensations(execution, error, compensation_stack, workflow_def, config)
    end
  end

  # Builds the compensation stack from completed steps in reverse order
  defp build_compensation_stack(workflow_id, workflow_def, config) do
    # Get completed non-compensation steps
    query =
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id,
        where: s.status == :completed,
        where: s.is_compensation == false,
        order_by: [desc: s.completed_at],
        select: s.step_name
      )

    completed_steps = Repo.all(config, query)

    # Map to steps that have compensations
    completed_steps
    |> Enum.map(&String.to_atom/1)
    |> Enum.flat_map(&find_step_compensation(&1, workflow_def))
  end

  defp find_step_compensation(step_name, workflow_def) do
    step_def = Enum.find(workflow_def.steps, &(&1.name == step_name))
    get_compensation_for_step(step_name, step_def, workflow_def.compensations)
  end

  defp get_compensation_for_step(step_name, %{opts: %{compensate: comp_name}}, compensations)
       when not is_nil(comp_name) do
    case Map.get(compensations, comp_name) do
      nil -> []
      compensation -> [{step_name, compensation}]
    end
  end

  defp get_compensation_for_step(_step_name, _step_def, _compensations), do: []

  # Runs compensations in order and handles results
  defp run_compensations(execution, original_error, compensation_stack, _workflow_def, config) do
    # Mark workflow as compensating
    {:ok, exec} =
      execution
      |> WorkflowExecution.compensating_changeset()
      |> Repo.update(config)

    # Run each compensation, collecting results
    results =
      Enum.map(compensation_stack, fn {step_name, compensation} ->
        result = CompensationRunner.execute(compensation, exec.id, step_name, config)

        %{
          step: Atom.to_string(step_name),
          compensation: Atom.to_string(compensation.name),
          result: format_compensation_result(result)
        }
      end)

    # Check if any compensations failed
    failed_count = Enum.count(results, &(&1.result.status == "failed"))

    if failed_count > 0 do
      # Some compensations failed
      {:ok, _exec} =
        exec
        |> WorkflowExecution.compensation_failed_changeset(results, original_error)
        |> Ecto.Changeset.change(locked_by: nil, locked_at: nil)
        |> Repo.update(config)

      {:error, original_error}
    else
      # All compensations succeeded
      {:ok, _exec} =
        exec
        |> WorkflowExecution.compensated_changeset(results)
        |> Ecto.Changeset.change(locked_by: nil, locked_at: nil, error: original_error)
        |> Repo.update(config)

      {:error, original_error}
    end
  end

  defp format_compensation_result({:ok, _output}), do: %{status: "completed"}
  defp format_compensation_result({:error, error}), do: %{status: "failed", error: error}

  defp handle_sleep(config, execution, opts) do
    wake_at = calculate_wake_time(opts)

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting, scheduled_at: wake_at)
      |> Repo.update(config)

    {:waiting, execution}
  end

  defp handle_wait_for_event(config, execution, opts) do
    event_name = Keyword.fetch!(opts, :event_name)
    timeout_at = calculate_timeout_at(opts)

    # Create pending event record
    attrs = %{
      workflow_id: execution.id,
      event_name: event_name,
      step_name: execution.current_step,
      timeout_at: timeout_at,
      timeout_value: serialize_timeout_value(Keyword.get(opts, :timeout_value)),
      wait_type: :single
    }

    {:ok, _pending_event} =
      %PendingEvent{}
      |> PendingEvent.changeset(attrs)
      |> Repo.insert(config)

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting)
      |> Repo.update(config)

    {:waiting, execution}
  end

  defp handle_wait_for_input(config, execution, opts) do
    input_name = Keyword.fetch!(opts, :input_name)
    timeout_at = calculate_timeout_at(opts)

    # Create pending input record
    attrs = %{
      workflow_id: execution.id,
      input_name: input_name,
      step_name: execution.current_step,
      input_type: Keyword.get(opts, :type, :free_text),
      prompt: Keyword.get(opts, :prompt),
      fields: Keyword.get(opts, :fields),
      metadata: Keyword.get(opts, :metadata),
      timeout_at: timeout_at,
      timeout_value: serialize_timeout_value(Keyword.get(opts, :timeout_value)),
      on_timeout: Keyword.get(opts, :on_timeout, :resume)
    }

    {:ok, _pending_input} =
      %PendingInput{}
      |> PendingInput.changeset(attrs)
      |> Repo.insert(config)

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting)
      |> Repo.update(config)

    {:waiting, execution}
  end

  defp handle_wait_for_any(config, execution, opts) do
    handle_wait_group(config, execution, opts, :any)
  end

  defp handle_wait_for_all(config, execution, opts) do
    handle_wait_group(config, execution, opts, :all)
  end

  defp handle_wait_group(config, execution, opts, wait_type) do
    event_names = Keyword.fetch!(opts, :event_names)
    timeout_at = calculate_timeout_at(opts)

    # Create wait group record
    group_attrs = %{
      workflow_id: execution.id,
      step_name: execution.current_step,
      wait_type: wait_type,
      event_names: event_names,
      timeout_at: timeout_at,
      timeout_value: serialize_timeout_value(Keyword.get(opts, :timeout_value))
    }

    {:ok, wait_group} =
      %WaitGroup{}
      |> WaitGroup.changeset(group_attrs)
      |> Repo.insert(config)

    # Create pending event records for each event in the group
    Enum.each(event_names, fn event_name ->
      event_attrs = %{
        workflow_id: execution.id,
        event_name: event_name,
        step_name: execution.current_step,
        wait_group_id: wait_group.id,
        wait_type: wait_type,
        timeout_at: timeout_at,
        timeout_value: serialize_timeout_value(Keyword.get(opts, :timeout_value))
      }

      {:ok, _} =
        %PendingEvent{}
        |> PendingEvent.changeset(event_attrs)
        |> Repo.insert(config)
    end)

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting)
      |> Repo.update(config)

    {:waiting, execution}
  end

  defp calculate_wake_time(opts) do
    cond do
      Keyword.has_key?(opts, :until) ->
        opts[:until]

      Keyword.has_key?(opts, :duration_ms) ->
        DateTime.add(DateTime.utc_now(), opts[:duration_ms], :millisecond)

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

  defp calculate_timeout_at(opts) do
    case Keyword.get(opts, :timeout) do
      nil ->
        nil

      timeout_ms when is_integer(timeout_ms) ->
        DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond)
    end
  end

  defp serialize_timeout_value(nil), do: nil
  defp serialize_timeout_value(value) when is_map(value), do: value

  defp serialize_timeout_value(value) when is_atom(value),
    do: %{"__atom__" => Atom.to_string(value)}

  defp serialize_timeout_value(value), do: %{"__value__" => value}
end
