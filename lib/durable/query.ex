defmodule Durable.Query do
  @moduledoc """
  Query functions for workflow executions.
  """

  import Ecto.Query

  alias Durable.Repo
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  @doc """
  Gets a workflow execution by ID.

  ## Options

  - `:include_steps` - Include step executions (default: false)
  - `:include_logs` - Include logs in step executions (default: false)

  """
  @spec get_execution(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def get_execution(workflow_id, opts \\ []) do
    include_steps = Keyword.get(opts, :include_steps, false)
    include_logs = Keyword.get(opts, :include_logs, false)

    query = from(w in WorkflowExecution, where: w.id == ^workflow_id)

    query =
      if include_steps do
        from(w in query, preload: [:step_executions])
      else
        query
      end

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      execution ->
        result = execution_to_map(execution, include_steps, include_logs)
        {:ok, result}
    end
  end

  @doc """
  Lists workflow executions with optional filters.

  ## Filters

  - `:workflow` - Filter by workflow module
  - `:workflow_name` - Filter by workflow name
  - `:status` - Filter by status
  - `:queue` - Filter by queue
  - `:limit` - Maximum results (default: 50)
  - `:offset` - Offset for pagination (default: 0)

  """
  @spec list_executions(keyword()) :: [map()]
  def list_executions(filters \\ []) do
    limit = Keyword.get(filters, :limit, 50)
    offset = Keyword.get(filters, :offset, 0)

    query =
      from(w in WorkflowExecution,
        order_by: [desc: w.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    query = apply_filters(query, filters)

    Repo.all(query)
    |> Enum.map(&execution_to_map(&1, false, false))
  end

  @doc """
  Counts workflow executions matching filters.
  """
  @spec count_executions(keyword()) :: non_neg_integer()
  def count_executions(filters \\ []) do
    query = from(w in WorkflowExecution, select: count(w.id))
    query = apply_filters(query, filters)
    Repo.one(query)
  end

  @doc """
  Gets step executions for a workflow.
  """
  @spec get_step_executions(String.t()) :: [map()]
  def get_step_executions(workflow_id) do
    query =
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id,
        order_by: [asc: s.inserted_at]
      )

    Repo.all(query)
    |> Enum.map(&step_to_map/1)
  end

  @doc """
  Gets logs for a specific step.
  """
  @spec get_step_logs(String.t(), atom() | String.t()) :: {:ok, [map()]} | {:error, :not_found}
  def get_step_logs(workflow_id, step_name) do
    step_name_str =
      if is_atom(step_name), do: Atom.to_string(step_name), else: step_name

    query =
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id and s.step_name == ^step_name_str,
        order_by: [desc: s.attempt],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      step -> {:ok, step.logs || []}
    end
  end

  # Private functions

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:workflow, module}, q when is_atom(module) ->
        module_str = inspect(module)
        from(w in q, where: w.workflow_module == ^module_str)

      {:workflow_name, name}, q ->
        from(w in q, where: w.workflow_name == ^name)

      {:status, status}, q when is_atom(status) ->
        from(w in q, where: w.status == ^status)

      {:queue, queue}, q ->
        queue_str = to_string(queue)
        from(w in q, where: w.queue == ^queue_str)

      {:from, from_date}, q ->
        from(w in q, where: w.inserted_at >= ^from_date)

      {:to, to_date}, q ->
        from(w in q, where: w.inserted_at <= ^to_date)

      _, q ->
        q
    end)
  end

  defp execution_to_map(execution, include_steps, include_logs) do
    base = %{
      id: execution.id,
      workflow_module: execution.workflow_module,
      workflow_name: execution.workflow_name,
      status: execution.status,
      queue: execution.queue,
      priority: execution.priority,
      input: execution.input,
      context: execution.context,
      current_step: execution.current_step,
      error: execution.error,
      scheduled_at: execution.scheduled_at,
      started_at: execution.started_at,
      completed_at: execution.completed_at,
      inserted_at: execution.inserted_at,
      updated_at: execution.updated_at
    }

    if include_steps && Ecto.assoc_loaded?(execution.step_executions) do
      steps =
        execution.step_executions
        |> Enum.map(&step_to_map(&1, include_logs))

      Map.put(base, :steps, steps)
    else
      base
    end
  end

  defp step_to_map(step, include_logs \\ true) do
    base = %{
      id: step.id,
      step_name: step.step_name,
      step_type: step.step_type,
      attempt: step.attempt,
      status: step.status,
      input: step.input,
      output: step.output,
      error: step.error,
      duration_ms: step.duration_ms,
      started_at: step.started_at,
      completed_at: step.completed_at
    }

    if include_logs do
      Map.put(base, :logs, step.logs || [])
    else
      base
    end
  end
end
