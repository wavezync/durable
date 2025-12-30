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
        |> WorkflowExecution.status_changeset(:cancelled, %{error: error, completed_at: DateTime.utc_now()})
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

    # Execute steps sequentially
    result =
      Enum.reduce_while(steps_to_run, {:ok, execution}, fn step, {:ok, exec} ->
        # Update current step
        {:ok, exec} = update_current_step(exec, step.name)

        case StepRunner.execute(step, exec.id) do
          {:ok, _output} ->
            # Save context after each step
            {:ok, exec} = save_context(exec)
            {:cont, {:ok, exec}}

          {:sleep, opts} ->
            # Workflow needs to sleep
            {:halt, handle_sleep(exec, opts)}

          {:wait_for_event, opts} ->
            # Workflow waiting for event
            {:halt, handle_wait_for_event(exec, opts)}

          {:wait_for_input, opts} ->
            # Workflow waiting for input
            {:halt, handle_wait_for_input(exec, opts)}

          {:error, error} ->
            # Step failed after all retries
            {:halt, mark_failed(exec, error)}
        end
      end)

    case result do
      {:ok, execution} ->
        # All steps completed successfully
        mark_completed(execution)

      {:waiting, execution} ->
        {:ok, execution}

      {:error, _} = error ->
        error
    end
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
