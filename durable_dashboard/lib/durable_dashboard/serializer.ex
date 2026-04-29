defmodule DurableDashboard.Serializer do
  @moduledoc """
  Converts Elixir structs to JSON-safe maps for the React frontend.

  Strips function references, converts atoms to strings, and formats
  datetimes as ISO 8601 strings.
  """

  @doc """
  Serializes a workflow execution to a JSON-safe map.
  """
  def workflow(execution) do
    %{
      id: execution.id,
      workflow_module: execution.workflow_module,
      workflow_name: execution.workflow_name,
      status: to_string(execution.status),
      queue: execution.queue,
      priority: execution.priority,
      input: execution.input,
      context: execution.context,
      current_step: execution.current_step,
      error: execution.error,
      scheduled_at: format_datetime(execution.scheduled_at),
      started_at: format_datetime(execution.started_at),
      completed_at: format_datetime(execution.completed_at),
      inserted_at: format_datetime(execution.inserted_at),
      updated_at: format_datetime(execution.updated_at)
    }
  end

  @doc """
  Serializes a workflow execution with associated steps.
  """
  def workflow_with_steps(execution, steps) do
    execution
    |> workflow()
    |> Map.put(:steps, Enum.map(steps, &step/1))
  end

  @doc """
  Serializes a step execution to a JSON-safe map.
  """
  def step(step_execution) do
    %{
      id: step_execution.id,
      step_name: step_execution.step_name,
      step_type: step_execution.step_type,
      attempt: step_execution.attempt,
      status: to_string(step_execution.status),
      input: step_execution.input,
      output: step_execution.output,
      error: step_execution.error,
      logs: step_execution.logs || [],
      duration_ms: step_execution.duration_ms,
      started_at: format_datetime(step_execution.started_at),
      completed_at: format_datetime(step_execution.completed_at)
    }
  end

  @doc """
  Serializes a pending input to a JSON-safe map.
  """
  def pending_input(pending) do
    base = %{
      id: pending.id,
      workflow_id: pending.workflow_id,
      input_name: pending.input_name,
      step_name: pending.step_name,
      input_type: to_string(pending.input_type),
      prompt: pending.prompt,
      metadata: pending.metadata,
      fields: pending.fields,
      status: to_string(pending.status),
      timeout_at: format_datetime(pending.timeout_at),
      inserted_at: format_datetime(pending.inserted_at)
    }

    if Ecto.assoc_loaded?(pending.workflow) and pending.workflow do
      Map.put(base, :workflow, %{
        id: pending.workflow.id,
        workflow_name: pending.workflow.workflow_name,
        workflow_module: pending.workflow.workflow_module,
        status: to_string(pending.workflow.status)
      })
    else
      base
    end
  end

  @doc """
  Serializes a scheduled workflow to a JSON-safe map.
  """
  def schedule(scheduled) do
    %{
      id: scheduled.id,
      name: scheduled.name,
      workflow_module: scheduled.workflow_module,
      workflow_name: scheduled.workflow_name,
      cron_expression: scheduled.cron_expression,
      timezone: scheduled.timezone,
      input: scheduled.input,
      queue: scheduled.queue,
      enabled: scheduled.enabled,
      last_run_at: format_datetime(scheduled.last_run_at),
      next_run_at: format_datetime(scheduled.next_run_at),
      inserted_at: format_datetime(scheduled.inserted_at),
      updated_at: format_datetime(scheduled.updated_at)
    }
  end

  @doc """
  Serializes graph data (nodes and edges) for ReactFlow.
  """
  def graph(%{nodes: nodes, edges: edges}) do
    %{
      nodes: Enum.map(nodes, &graph_node/1),
      edges: Enum.map(edges, &graph_edge/1)
    }
  end

  defp graph_node(node) do
    %{
      id: to_string(node.id),
      type: to_string(node.type),
      data: stringify_keys(node.data)
    }
  end

  defp graph_edge(edge) do
    %{
      id: to_string(edge.id),
      source: to_string(edge.source),
      target: to_string(edge.target),
      animated: Map.get(edge, :animated, false),
      style: Map.get(edge, :style, %{})
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp stringify_value(v), do: v

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_datetime(other), do: to_string(other)
end
