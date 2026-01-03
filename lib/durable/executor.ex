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
    repo = config.repo

    with {:ok, workflow_def} <- get_workflow_definition(module, opts),
         {:ok, execution} <- create_execution(repo, module, workflow_def, input, opts) do
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
    repo = Config.repo(durable_name)

    case repo.get(WorkflowExecution, workflow_id) do
      nil ->
        {:error, :not_found}

      execution when execution.status in [:pending, :running, :waiting] ->
        error = if reason, do: %{type: "cancelled", message: reason}, else: %{type: "cancelled"}

        execution
        |> WorkflowExecution.status_changeset(:cancelled, %{
          error: error,
          completed_at: DateTime.utc_now()
        })
        |> repo.update()

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
    repo = config.repo

    with {:ok, execution} <- load_execution(repo, workflow_id),
         {:ok, workflow_def} <- get_workflow_definition_from_execution(execution),
         {:ok, execution} <- mark_running(repo, execution) do
      # Initialize context
      Context.restore_context(execution.context, execution.input, execution.id)

      # Execute steps
      result = execute_steps(workflow_def.steps, execution, config)

      # Cleanup context
      Context.cleanup()

      result
    end
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
    repo = config.repo

    with {:ok, execution} <- load_execution(repo, workflow_id),
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
      |> repo.update()

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

  defp create_execution(repo, module, %Workflow{} = workflow_def, input, opts) do
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
    |> repo.insert()
  end

  defp load_execution(repo, workflow_id) do
    case repo.get(WorkflowExecution, workflow_id) do
      nil -> {:error, :not_found}
      execution -> {:ok, execution}
    end
  end

  defp mark_running(repo, execution) do
    execution
    |> WorkflowExecution.status_changeset(:running, %{started_at: DateTime.utc_now()})
    |> repo.update()
  end

  defp execute_steps(steps, execution, config) do
    repo = config.repo

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

    # Execute steps with decision support
    case execute_steps_recursive(steps_to_run, execution, step_index, workflow_def, config) do
      {:ok, exec} ->
        mark_completed(repo, exec)

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

  defp execute_steps_recursive([], execution, _step_index, _workflow_def, _config) do
    {:ok, execution}
  end

  defp execute_steps_recursive(
         [step | remaining_steps],
         execution,
         step_index,
         workflow_def,
         config
       ) do
    # Handle special step types
    case step.type do
      :branch ->
        execute_branch(step, remaining_steps, execution, step_index, workflow_def, config)

      :parallel ->
        execute_parallel(step, remaining_steps, execution, step_index, workflow_def, config)

      :foreach ->
        execute_foreach(step, remaining_steps, execution, step_index, workflow_def, config)

      _ ->
        execute_regular_step(step, remaining_steps, execution, step_index, workflow_def, config)
    end
  end

  defp execute_regular_step(step, remaining_steps, execution, step_index, workflow_def, config) do
    repo = config.repo

    # Update current step
    {:ok, exec} = update_current_step(repo, execution, step.name)

    case StepRunner.execute(step, exec.id, config) do
      {:ok, _output} ->
        # Save context and continue to next step
        {:ok, exec} = save_context(repo, exec)
        execute_steps_recursive(remaining_steps, exec, step_index, workflow_def, config)

      {:decision, target_step} ->
        # Decision step wants to jump - find target in remaining steps
        {:ok, exec} = save_context(repo, exec)

        case find_jump_target(target_step, remaining_steps, step.name, step_index) do
          {:ok, target_steps} ->
            execute_steps_recursive(target_steps, exec, step_index, workflow_def, config)

          {:error, reason} ->
            handle_step_failure(
              exec,
              decision_error(step.name, target_step, reason),
              workflow_def,
              config
            )
        end

      {:sleep, opts} ->
        {:waiting, handle_sleep(repo, exec, opts) |> elem(1)}

      {:wait_for_event, opts} ->
        {:waiting, handle_wait_for_event(repo, exec, opts) |> elem(1)}

      {:wait_for_input, opts} ->
        {:waiting, handle_wait_for_input(repo, exec, opts) |> elem(1)}

      {:wait_for_any, opts} ->
        {:waiting, handle_wait_for_any(repo, exec, opts) |> elem(1)}

      {:wait_for_all, opts} ->
        {:waiting, handle_wait_for_all(repo, exec, opts) |> elem(1)}

      {:error, error} ->
        handle_step_failure(exec, error, workflow_def, config)
    end
  end

  defp execute_branch(branch_step, remaining_steps, execution, step_index, workflow_def, config) do
    repo = config.repo
    {:ok, exec} = update_current_step(repo, execution, branch_step.name)

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
        handle_step_failure(exec, %{type: "branch_error", message: error}, workflow_def, config)

      value ->
        # Find matching clause steps
        matching_steps = find_matching_clause_steps(value, clauses)

        # Save context before executing branch steps
        {:ok, exec} = save_context(repo, exec)

        # Execute only the matching branch's steps
        case execute_branch_steps(
               matching_steps,
               remaining_steps,
               exec,
               step_index,
               workflow_def,
               config
             ) do
          {:ok, exec} ->
            # Skip past all branch steps in remaining and continue
            after_branch = skip_branch_steps(remaining_steps, all_branch_steps)
            execute_steps_recursive(after_branch, exec, step_index, workflow_def, config)

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
         config
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

    execute_branch_steps_sequential(ordered_steps, execution, step_index, workflow_def, config)
  end

  defp execute_branch_steps_sequential([], execution, _step_index, _workflow_def, _config) do
    {:ok, execution}
  end

  defp execute_branch_steps_sequential([step | rest], execution, step_index, workflow_def, config) do
    repo = config.repo
    {:ok, exec} = update_current_step(repo, execution, step.name)

    case StepRunner.execute(step, exec.id, config) do
      {:ok, _output} ->
        {:ok, exec} = save_context(repo, exec)
        execute_branch_steps_sequential(rest, exec, step_index, workflow_def, config)

      {:sleep, opts} ->
        {:waiting, handle_sleep(repo, exec, opts) |> elem(1)}

      {:wait_for_event, opts} ->
        {:waiting, handle_wait_for_event(repo, exec, opts) |> elem(1)}

      {:wait_for_input, opts} ->
        {:waiting, handle_wait_for_input(repo, exec, opts) |> elem(1)}

      {:wait_for_any, opts} ->
        {:waiting, handle_wait_for_any(repo, exec, opts) |> elem(1)}

      {:wait_for_all, opts} ->
        {:waiting, handle_wait_for_all(repo, exec, opts) |> elem(1)}

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
         config
       ) do
    repo = config.repo
    {:ok, exec} = update_current_step(repo, execution, parallel_step.name)

    # Get parallel configuration
    opts = parallel_step.opts
    parallel_step_names = opts[:steps] || []
    all_parallel_steps = opts[:all_steps] || []
    merge_strategy = opts[:merge_strategy] || :deep_merge
    error_strategy = opts[:error_strategy] || :fail_fast

    # Find actual step definitions for parallel steps
    steps_to_execute =
      Enum.filter(remaining_steps, fn step ->
        step.name in parallel_step_names
      end)

    # Order steps according to step_names
    ordered_steps =
      Enum.map(parallel_step_names, fn name ->
        Enum.find(steps_to_execute, fn s -> s.name == name end)
      end)
      |> Enum.reject(&is_nil/1)

    # Save context before parallel execution
    {:ok, exec} = save_context(repo, exec)
    base_context = Context.get_current_context()
    input = Context.input()

    # DURABILITY: Check which parallel steps already completed (for resume)
    {completed_names, completed_contexts} =
      get_completed_parallel_steps_with_context(exec.id, parallel_step_names, config)

    # Merge contexts from completed steps into base context
    base_context_with_completed =
      Enum.reduce(completed_contexts, base_context, &deep_merge(&2, &1))

    # Filter to only incomplete steps
    incomplete_steps = Enum.reject(ordered_steps, &(&1.name in completed_names))

    # If all steps already completed, skip execution
    if incomplete_steps == [] do
      Context.restore_context(base_context_with_completed, input, exec.id)
      {:ok, exec} = save_context(repo, exec)
      after_parallel = skip_parallel_steps(remaining_steps, all_parallel_steps)
      execute_steps_recursive(after_parallel, exec, step_index, workflow_def, config)
    else
      # Execute only incomplete steps in parallel
      case execute_parallel_steps(
             incomplete_steps,
             exec,
             config,
             base_context_with_completed,
             input,
             merge_strategy,
             error_strategy
           ) do
        {:ok, merged_context} ->
          # Restore merged context and continue
          Context.restore_context(merged_context, input, exec.id)
          {:ok, exec} = save_context(repo, exec)

          # Skip past all parallel steps and continue
          after_parallel = skip_parallel_steps(remaining_steps, all_parallel_steps)
          execute_steps_recursive(after_parallel, exec, step_index, workflow_def, config)

        {:error, error} ->
          handle_step_failure(exec, error, workflow_def, config)
      end
    end
  end

  defp execute_parallel_steps(
         steps,
         execution,
         config,
         base_context,
         input,
         merge_strategy,
         error_strategy
       ) do
    task_sup = Config.task_supervisor(config.name)
    task_opts = %{context: base_context, input: input, execution_id: execution.id, config: config}

    tasks =
      Enum.map(steps, fn step ->
        Task.Supervisor.async(task_sup, fn ->
          run_parallel_step_task(step, task_opts)
        end)
      end)

    results = await_parallel_tasks(tasks, error_strategy)
    process_parallel_results(results, base_context, merge_strategy)
  end

  defp run_parallel_step_task(step, task_opts) do
    %{context: ctx, input: input, execution_id: exec_id, config: config} = task_opts
    Context.restore_context(ctx, input, exec_id)

    result = StepRunner.execute(step, exec_id, config)
    handle_parallel_step_result(result, step.name)
  end

  defp handle_parallel_step_result({:ok, _output}, step_name) do
    {:ok, step_name, Context.get_current_context()}
  end

  defp handle_parallel_step_result({:error, error}, step_name) do
    {:error, step_name, error}
  end

  defp handle_parallel_step_result({:sleep, _opts}, step_name) do
    {:error, step_name,
     %{type: "parallel_wait_not_supported", message: "sleep not supported in parallel blocks yet"}}
  end

  defp handle_parallel_step_result({:wait_for_event, _opts}, step_name) do
    {:error, step_name,
     %{
       type: "parallel_wait_not_supported",
       message: "wait_for_event not supported in parallel blocks yet"
     }}
  end

  defp handle_parallel_step_result({:wait_for_input, _opts}, step_name) do
    {:error, step_name,
     %{
       type: "parallel_wait_not_supported",
       message: "wait_for_input not supported in parallel blocks yet"
     }}
  end

  defp await_parallel_tasks(tasks, :fail_fast), do: await_tasks_fail_fast(tasks)
  defp await_parallel_tasks(tasks, :complete_all), do: await_tasks_complete_all(tasks)
  defp await_parallel_tasks(tasks, _), do: await_tasks_complete_all(tasks)

  defp await_tasks_fail_fast(tasks) do
    # Await all - in a real fail_fast we'd cancel on first error
    # For now, just await all and return results
    Enum.map(tasks, fn task ->
      case Task.await(task, :infinity) do
        result -> result
      end
    end)
  end

  defp await_tasks_complete_all(tasks) do
    Task.await_many(tasks, :infinity)
  end

  defp process_parallel_results(results, base_context, merge_strategy) do
    errors = Enum.filter(results, &match?({:error, _, _}, &1))
    successes = Enum.filter(results, &match?({:ok, _, _}, &1))

    if errors != [] do
      # Any errors -> fail
      error_details =
        Enum.map(errors, fn {:error, step, err} ->
          %{step: step, error: err}
        end)

      {:error,
       %{
         type: "parallel_error",
         message: "One or more parallel steps failed",
         errors: error_details
       }}
    else
      # All succeeded -> merge contexts
      contexts = Enum.map(successes, fn {:ok, step_name, ctx} -> {step_name, ctx} end)
      merged = merge_parallel_contexts(contexts, base_context, merge_strategy)
      {:ok, merged}
    end
  end

  defp merge_parallel_contexts(step_contexts, base_context, :deep_merge) do
    Enum.reduce(step_contexts, base_context, fn {_step_name, ctx}, acc ->
      deep_merge(acc, ctx)
    end)
  end

  defp merge_parallel_contexts(step_contexts, _base_context, :last_wins) do
    case List.last(step_contexts) do
      nil -> %{}
      {_step_name, ctx} -> ctx
    end
  end

  defp merge_parallel_contexts(step_contexts, base_context, :collect) do
    collected =
      Enum.into(step_contexts, %{}, fn {step_name, ctx} ->
        # Extract only the changes from base_context
        changes = Map.drop(ctx, Map.keys(base_context))
        {Atom.to_string(step_name), changes}
      end)

    Map.put(base_context, "__parallel_results__", collected)
  end

  defp merge_parallel_contexts(step_contexts, base_context, _unknown) do
    merge_parallel_contexts(step_contexts, base_context, :deep_merge)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r -> deep_merge(l, r) end)
  end

  defp deep_merge(_left, right), do: right

  defp skip_parallel_steps(remaining_steps, all_parallel_step_names) do
    Enum.reject(remaining_steps, fn step ->
      step.name in all_parallel_step_names
    end)
  end

  # Get completed parallel steps with their stored contexts for durability
  defp get_completed_parallel_steps_with_context(workflow_id, step_names, config) do
    repo = config.repo
    step_name_strings = Enum.map(step_names, &Atom.to_string/1)

    completed =
      repo.all(
        from(s in StepExecution,
          where: s.workflow_id == ^workflow_id,
          where: s.step_name in ^step_name_strings,
          where: s.status == :completed,
          select: {s.step_name, s.output}
        )
      )

    names =
      Enum.map(completed, fn {name, _} ->
        String.to_existing_atom(name)
      end)

    contexts =
      Enum.map(completed, fn {_, output} ->
        # Extract context from stored output (parallel steps store it under "__context__")
        (output || %{})["__context__"] || %{}
      end)

    {names, contexts}
  end

  # ============================================================================
  # ForEach Execution
  # ============================================================================

  defp execute_foreach(foreach_step, remaining_steps, execution, step_index, workflow_def, config) do
    repo = config.repo
    {:ok, exec} = update_current_step(repo, execution, foreach_step.name)

    # Get foreach configuration
    step_opts = foreach_step.opts
    foreach_step_names = step_opts[:steps] || []
    all_foreach_steps = step_opts[:all_steps] || []
    concurrency = step_opts[:concurrency] || 1

    items = resolve_foreach_items(step_opts[:items_spec])
    steps_to_execute = Enum.filter(remaining_steps, &(&1.name in foreach_step_names))

    # Save context before foreach execution
    {:ok, exec} = save_context(repo, exec)

    # Bundle options for child functions
    foreach_opts = %{
      context: Context.get_current_context(),
      input: Context.input(),
      on_error: step_opts[:on_error] || :fail_fast,
      collect_as: step_opts[:collect_as]
    }

    result = do_execute_foreach(items, steps_to_execute, exec, config, concurrency, foreach_opts)

    handle_foreach_result(
      result,
      remaining_steps,
      all_foreach_steps,
      exec,
      step_index,
      workflow_def,
      config
    )
  end

  defp resolve_foreach_items({:context_key, key}), do: Context.get_context(key) || []
  defp resolve_foreach_items({:mfa, {mod, fun, args}}), do: apply(mod, fun, args)
  defp resolve_foreach_items(_), do: []

  defp do_execute_foreach(items, steps, execution, config, 1, opts) do
    execute_foreach_sequential(items, steps, execution, config, opts)
  end

  defp do_execute_foreach(items, steps, execution, config, concurrency, opts) do
    execute_foreach_concurrent(items, steps, execution, config, concurrency, opts)
  end

  defp handle_foreach_result(
         {:ok, ctx},
         remaining,
         all_foreach_steps,
         exec,
         idx,
         workflow_def,
         cfg
       ) do
    Context.restore_context(ctx, Context.input(), exec.id)
    {:ok, exec} = save_context(cfg.repo, exec)
    after_foreach = skip_foreach_steps(remaining, all_foreach_steps)
    execute_steps_recursive(after_foreach, exec, idx, workflow_def, cfg)
  end

  defp handle_foreach_result({:error, error}, _remaining, _all, exec, _idx, workflow_def, cfg) do
    handle_step_failure(exec, error, workflow_def, cfg)
  end

  defp execute_foreach_sequential(items, steps, execution, config, opts) do
    %{context: base_context, input: input, on_error: on_error, collect_as: collect_as} = opts
    initial_acc = %{context: base_context, results: [], errors: []}

    final_acc =
      items
      |> Enum.with_index()
      |> Enum.reduce_while(initial_acc, fn {item, index}, acc ->
        Context.restore_context(acc.context, input, execution.id)
        Context.set_foreach_item(item, index)

        result = execute_foreach_item_steps(steps, execution.id, config)
        handle_foreach_item_result(result, index, acc, on_error, collect_as)
      end)

    finalize_foreach_result(final_acc, collect_as)
  end

  defp handle_foreach_item_result({:ok, item_context}, _index, acc, _on_error, collect_as) do
    Context.clear_foreach_item()
    new_context = deep_merge(acc.context, item_context)
    new_results = maybe_collect_result(acc.results, item_context, acc.context, collect_as)
    {:cont, %{acc | context: new_context, results: new_results}}
  end

  defp handle_foreach_item_result({:error, error}, index, acc, :fail_fast, _collect_as) do
    Context.clear_foreach_item()
    {:halt, %{acc | errors: [{index, error} | acc.errors]}}
  end

  defp handle_foreach_item_result({:error, error}, index, acc, :continue, _collect_as) do
    Context.clear_foreach_item()
    {:cont, %{acc | errors: [{index, error} | acc.errors]}}
  end

  defp maybe_collect_result(results, _item_context, _base_context, nil), do: results

  defp maybe_collect_result(results, item_context, base_context, _collect_as) do
    results ++ [extract_item_result(item_context, base_context)]
  end

  defp finalize_foreach_result(%{errors: [], context: ctx, results: _results}, nil) do
    {:ok, ctx}
  end

  defp finalize_foreach_result(%{errors: [], context: ctx, results: results}, collect_as) do
    {:ok, Map.put(ctx, collect_as, results)}
  end

  defp finalize_foreach_result(%{errors: errors}, _collect_as) do
    {:error,
     %{
       type: "foreach_error",
       message: "One or more foreach items failed",
       errors: format_foreach_errors(errors)
     }}
  end

  defp execute_foreach_concurrent(items, steps, execution, config, concurrency, opts) do
    %{context: base_context, input: input, on_error: on_error, collect_as: collect_as} = opts
    task_sup = Config.task_supervisor(config.name)
    task_opts = %{steps: steps, execution_id: execution.id, config: config, input: input}

    items
    |> Enum.with_index()
    |> Enum.chunk_every(concurrency)
    |> Enum.reduce_while({:ok, base_context, [], []}, fn chunk, {:ok, ctx, results, errors} ->
      tasks = spawn_foreach_chunk_tasks(chunk, ctx, task_sup, task_opts)
      task_results = Task.await_many(tasks, :infinity)

      {new_ctx, new_results, new_errors} =
        merge_chunk_results(task_results, ctx, results, errors, collect_as)

      check_chunk_continue(on_error, new_ctx, new_results, new_errors)
    end)
    |> finalize_concurrent_foreach(collect_as)
  end

  defp spawn_foreach_chunk_tasks(chunk, current_ctx, task_sup, task_opts) do
    Enum.map(chunk, fn {item, index} ->
      Task.Supervisor.async(task_sup, fn ->
        run_foreach_item_task(item, index, current_ctx, task_opts)
      end)
    end)
  end

  defp run_foreach_item_task(item, index, ctx, task_opts) do
    %{steps: steps, execution_id: exec_id, config: config, input: input} = task_opts
    Context.restore_context(ctx, input, exec_id)
    Context.set_foreach_item(item, index)

    result = execute_foreach_item_steps(steps, exec_id, config)
    Context.clear_foreach_item()

    case result do
      {:ok, item_context} -> {:ok, index, item_context}
      {:error, error} -> {:error, index, error}
    end
  end

  defp merge_chunk_results(task_results, ctx, results, errors, collect_as) do
    Enum.reduce(task_results, {ctx, results, errors}, fn
      {:ok, _index, item_ctx}, {c, r, e} ->
        merged = deep_merge(c, item_ctx)
        item_result = if collect_as, do: [extract_item_result(item_ctx, c)], else: []
        {merged, r ++ item_result, e}

      {:error, index, error}, {c, r, e} ->
        {c, r, [{index, error} | e]}
    end)
  end

  defp check_chunk_continue(:fail_fast, _ctx, _results, [_ | _] = errors) do
    {:halt, {:error, errors}}
  end

  defp check_chunk_continue(_on_error, ctx, results, errors) do
    {:cont, {:ok, ctx, results, errors}}
  end

  defp finalize_concurrent_foreach({:ok, ctx, _results, []}, nil), do: {:ok, ctx}

  defp finalize_concurrent_foreach({:ok, ctx, results, []}, collect_as),
    do: {:ok, Map.put(ctx, collect_as, results)}

  defp finalize_concurrent_foreach({:ok, _ctx, _results, errors}, _collect_as) do
    {:error,
     %{
       type: "foreach_error",
       message: "One or more foreach items failed",
       errors: format_foreach_errors(errors)
     }}
  end

  defp finalize_concurrent_foreach({:error, errors}, _collect_as) do
    {:error,
     %{
       type: "foreach_error",
       message: "One or more foreach items failed",
       errors: format_foreach_errors(errors)
     }}
  end

  defp execute_foreach_item_steps(steps, workflow_id, config) do
    # Execute each step for the current item
    Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, _acc_ctx} ->
      case StepRunner.execute(step, workflow_id, config) do
        {:ok, _output} ->
          {:cont, {:ok, Context.get_current_context()}}

        {:error, error} ->
          {:halt, {:error, error}}

        # Wait primitives not supported in foreach
        {:sleep, _opts} ->
          {:halt,
           {:error,
            %{
              type: "foreach_wait_not_supported",
              message: "sleep not supported in foreach blocks"
            }}}

        {:wait_for_event, _opts} ->
          {:halt,
           {:error,
            %{
              type: "foreach_wait_not_supported",
              message: "wait_for_event not supported in foreach blocks"
            }}}

        {:wait_for_input, _opts} ->
          {:halt,
           {:error,
            %{
              type: "foreach_wait_not_supported",
              message: "wait_for_input not supported in foreach blocks"
            }}}
      end
    end)
  end

  defp extract_item_result(item_context, base_context) do
    Map.drop(item_context, Map.keys(base_context))
  end

  defp format_foreach_errors(errors) do
    Enum.map(errors, fn {index, error} ->
      %{index: index, error: error}
    end)
  end

  defp skip_foreach_steps(remaining_steps, all_foreach_step_names) do
    Enum.reject(remaining_steps, fn step ->
      step.name in all_foreach_step_names
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

  defp update_current_step(repo, execution, step_name) do
    execution
    |> Ecto.Changeset.change(current_step: Atom.to_string(step_name))
    |> repo.update()
  end

  defp save_context(repo, execution) do
    current_context = Context.get_current_context()

    execution
    |> Ecto.Changeset.change(context: current_context)
    |> repo.update()
  end

  defp mark_completed(repo, execution) do
    current_context = Context.get_current_context()

    {:ok, execution} =
      execution
      |> WorkflowExecution.status_changeset(:completed, %{
        context: current_context,
        completed_at: DateTime.utc_now(),
        current_step: nil
      })
      |> Ecto.Changeset.change(locked_by: nil, locked_at: nil)
      |> repo.update()

    {:ok, execution}
  end

  defp mark_failed(repo, execution, error) do
    current_context = Context.get_current_context()

    execution
    |> WorkflowExecution.status_changeset(:failed, %{
      context: current_context,
      error: error,
      completed_at: DateTime.utc_now()
    })
    |> Ecto.Changeset.change(locked_by: nil, locked_at: nil)
    |> repo.update()

    {:error, error}
  end

  # ============================================================================
  # Compensation/Saga Support
  # ============================================================================

  # Handles step failure by running compensations if needed
  defp handle_step_failure(execution, error, workflow_def, config) do
    repo = config.repo

    # Get the compensation stack from completed steps
    compensation_stack = build_compensation_stack(execution.id, workflow_def, config)

    if compensation_stack == [] do
      # No compensations to run - just mark as failed
      mark_failed(repo, execution, error)
    else
      # Run compensations
      run_compensations(execution, error, compensation_stack, workflow_def, config)
    end
  end

  # Builds the compensation stack from completed steps in reverse order
  defp build_compensation_stack(workflow_id, workflow_def, config) do
    repo = config.repo

    # Get completed non-compensation steps
    completed_steps =
      repo.all(
        from(s in StepExecution,
          where: s.workflow_id == ^workflow_id,
          where: s.status == :completed,
          where: s.is_compensation == false,
          order_by: [desc: s.completed_at],
          select: s.step_name
        )
      )

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
    repo = config.repo

    # Mark workflow as compensating
    {:ok, exec} =
      execution
      |> WorkflowExecution.compensating_changeset()
      |> repo.update()

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
        |> repo.update()

      {:error, original_error}
    else
      # All compensations succeeded
      {:ok, _exec} =
        exec
        |> WorkflowExecution.compensated_changeset(results)
        |> Ecto.Changeset.change(locked_by: nil, locked_at: nil, error: original_error)
        |> repo.update()

      {:error, original_error}
    end
  end

  defp format_compensation_result({:ok, _output}), do: %{status: "completed"}
  defp format_compensation_result({:error, error}), do: %{status: "failed", error: error}

  defp handle_sleep(repo, execution, opts) do
    wake_at = calculate_wake_time(opts)

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting, scheduled_at: wake_at)
      |> repo.update()

    {:waiting, execution}
  end

  defp handle_wait_for_event(repo, execution, opts) do
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
      |> repo.insert()

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting)
      |> repo.update()

    {:waiting, execution}
  end

  defp handle_wait_for_input(repo, execution, opts) do
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
      |> repo.insert()

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting)
      |> repo.update()

    {:waiting, execution}
  end

  defp handle_wait_for_any(repo, execution, opts) do
    handle_wait_group(repo, execution, opts, :any)
  end

  defp handle_wait_for_all(repo, execution, opts) do
    handle_wait_group(repo, execution, opts, :all)
  end

  defp handle_wait_group(repo, execution, opts, wait_type) do
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
      |> repo.insert()

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
        |> repo.insert()
    end)

    {:ok, execution} =
      execution
      |> Ecto.Changeset.change(status: :waiting)
      |> repo.update()

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
