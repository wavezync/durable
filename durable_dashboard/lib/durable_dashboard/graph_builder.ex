defmodule DurableDashboard.GraphBuilder do
  @moduledoc """
  Converts a `%Durable.Definition.Workflow{}` into ReactFlow-compatible
  nodes and edges for graph visualization.

  ## Implementation note — polymorphic prev_ids

  The reduce accumulator's third element is a *list* of "tail ids" — the
  set of node ids that the *next* step's inbound edges should originate
  from. Linear steps return a one-element list. `parallel` returns the
  list of all child ids so the next step's edges fan in directly from
  every branch. `branch` returns the list of "last step in each clause"
  ids for the same reason. This is what lets us drop synthetic
  fork/join marker nodes — the n8n-style splay/converge falls out of
  the edge geometry alone.
  """

  alias Durable.Definition.{Step, Workflow}

  @doc """
  Builds a ReactFlow graph from a workflow definition.

  Returns `%{nodes: [node], edges: [edge]}`.
  """
  def build(%Workflow{steps: steps}) do
    {nodes, edges, _} =
      steps
      |> Enum.reduce({[], [], nil}, fn step, {nodes, edges, prev_ids} ->
        process_step(step, nodes, edges, prev_ids)
      end)

    %{nodes: Enum.reverse(nodes), edges: Enum.reverse(edges)}
  end

  def build(_), do: %{nodes: [], edges: []}

  @doc """
  Overlays runtime step execution status onto graph nodes.

  Takes graph data and a list of step execution maps (keyed by step_name),
  and adds status information to each node's data.
  """
  def overlay_status(graph, step_executions, opts \\ [])

  def overlay_status(%{nodes: nodes, edges: edges}, step_executions, opts) do
    step_map = index_steps(step_executions)
    by_original = index_by_original(step_executions)
    current_id = Keyword.get(opts, :current_workflow_id)
    parallel_children = Keyword.get(opts, :parallel_children_lookup, %{})

    nodes =
      Enum.map(nodes, fn node ->
        node =
          case lookup_step(node, step_map, by_original) do
            nil -> put_in(node, [:data, :status], "pending")
            step_exec -> apply_status(node, step_exec, current_id)
          end

        attach_child_workflow_id(node, parallel_children)
      end)

    matched_node_ids =
      nodes
      |> Enum.filter(&(get_in(&1, [:data, :status]) not in [nil, "pending"]))
      |> MapSet.new(& &1.id)

    running_node_ids =
      nodes
      |> Enum.filter(&(get_in(&1, [:data, :status]) == "running"))
      |> MapSet.new(& &1.id)

    edges = Enum.map(edges, &apply_edge_status(&1, matched_node_ids, running_node_ids))

    %{nodes: nodes, edges: edges}
  end

  # Conditional edges (decision :goto branches) keep their dashed style
  # regardless of runtime status — they represent possible paths, not the
  # path actually taken.
  defp apply_edge_status(%{className: "flow-edge-conditional"} = edge, _matched, _running),
    do: edge

  defp apply_edge_status(edge, matched_ids, running_ids) do
    cond do
      MapSet.member?(running_ids, edge.target) ->
        edge
        |> Map.put(:animated, true)
        |> Map.put(:className, "flow-edge-running")

      MapSet.member?(matched_ids, edge.source) and MapSet.member?(matched_ids, edge.target) ->
        Map.put(edge, :className, "flow-edge-completed")

      true ->
        Map.put(edge, :className, "flow-edge-pending")
    end
  end

  defp lookup_step(node, step_map, by_original) do
    case Map.get(step_map, node.id) do
      nil ->
        original = get_in(node, [:data, :original_name])
        if original, do: Map.get(by_original, to_string(original)), else: nil

      step_exec ->
        step_exec
    end
  end

  defp apply_status(node, step_exec, current_id) do
    node
    |> put_in([:data, :status], to_string(step_exec.status))
    |> put_in([:data, :attempt], step_exec.attempt)
    |> put_in([:data, :duration_ms], step_exec.duration_ms)
    |> put_in([:data, :started_at], iso8601(step_exec.started_at))
    |> put_in([:data, :completed_at], iso8601(step_exec.completed_at))
    |> put_in([:data, :step_execution_id], step_exec.id)
    |> put_in([:data, :workflow_execution_id], Map.get(step_exec, :workflow_id))
    |> put_in(
      [:data, :is_current],
      not is_nil(current_id) and Map.get(step_exec, :workflow_id) == current_id
    )
  end

  # When a node represents a parallel child step that ran in its own
  # `WorkflowExecution`, surface the child workflow id in node.data so
  # the FlowGraph LC can route a click to that child's detail page.
  defp attach_child_workflow_id(%{data: data} = node, lookup) when map_size(lookup) > 0 do
    case Map.get(lookup, get_in(data, [:name])) || Map.get(lookup, node.id) do
      nil -> node
      child_id -> put_in(node, [:data, :child_workflow_id], child_id)
    end
  end

  defp attach_child_workflow_id(node, _), do: node

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(other), do: other

  # ============================================================================
  # process_step/4 clauses
  #
  # Return shape: {nodes, edges, prev_ids :: [String.t()] | nil}
  # `nil` only at the start of the workflow (no inbound edges yet).
  # ============================================================================

  # Parallel/branch children are also registered as flat top-level steps
  # in the workflow definition (the DSL splices both the block AND each
  # child into @durable_current_steps). The block's `process_step/4`
  # clause already emits child nodes — re-emitting here would duplicate
  # IDs and create stray edges.
  defp process_step(%Step{type: :step, opts: %{parallel_id: _}}, nodes, edges, prev_ids),
    do: {nodes, edges, prev_ids}

  defp process_step(%Step{type: :step, opts: %{branch_id: _}}, nodes, edges, prev_ids),
    do: {nodes, edges, prev_ids}

  # Regular top-level step
  defp process_step(%Step{type: :step} = step, nodes, edges, prev_ids) do
    id = to_string(step.name)
    display_name = step.opts[:original_name] || step.name

    node = %{
      id: id,
      type: "step",
      data: %{
        label: to_string(display_name),
        step_type: "step",
        name: to_string(step.name),
        original_name: to_string(display_name)
      }
    }

    edges = add_edges(edges, prev_ids, id)
    {[node | nodes], edges, [id]}
  end

  # Decision step — single node, plus dashed conditional edges to every
  # `{:goto, atom_target, _}` extracted from the body AST at compile
  # time (`opts[:branches]`). The fall-through edge to the source-order
  # next step is added by the *next* step's prev_ids handling.
  defp process_step(%Step{type: :decision} = step, nodes, edges, prev_ids) do
    id = to_string(step.name)

    node = %{
      id: id,
      type: "decision",
      data: %{
        label: to_string(step.name),
        step_type: "decision",
        name: to_string(step.name)
      }
    }

    edges =
      edges
      |> add_edges(prev_ids, id)
      |> prepend_branch_edges(id, step.opts[:branches] || [])

    {[node | nodes], edges, [id]}
  end

  # Branch step — N clauses, each a sub-pipeline. No fork/join markers;
  # the previous step's prev_ids fan out to the first step of each
  # clause, and the last step of each clause becomes a tail returned to
  # the next step.
  defp process_step(%Step{type: :branch} = step, nodes, edges, prev_ids) do
    clauses = step.opts[:clauses] || %{}

    {clause_nodes, clause_edges, clause_tails} =
      Enum.reduce(clauses, {[], [], []}, fn {{clause_key, _idx}, step_names}, {cn, ce, tails} ->
        build_clause_path(prev_ids, clause_key, step_names, cn, ce, tails)
      end)

    nodes = Enum.reverse(clause_nodes) ++ nodes
    edges = Enum.reverse(clause_edges) ++ edges

    # No clauses → branch is a passthrough; the next step's edges come
    # straight from the same prev_ids.
    new_prev = if clause_tails == [], do: prev_ids, else: Enum.reverse(clause_tails)
    {nodes, edges, new_prev}
  end

  # Parallel step — N children running concurrently. No fork/join
  # markers; previous step's prev_ids fan out to every child, and every
  # child becomes a tail returned to the next step.
  defp process_step(%Step{type: :parallel} = step, nodes, edges, prev_ids) do
    child_steps = step.opts[:steps] || step.opts[:all_steps] || []

    {child_nodes, child_edges, child_ids} =
      Enum.reduce(child_steps, {[], [], []}, fn child_name, {cn, ce, ids} ->
        child_id = to_string(child_name)
        display = extract_display_name(child_name, "parallel")

        child_node = %{
          id: child_id,
          type: "step",
          data: %{
            label: display,
            step_type: "step",
            name: child_id,
            parallel: true,
            original_name: display
          }
        }

        ce = add_edges(ce, prev_ids, child_id)
        {[child_node | cn], ce, [child_id | ids]}
      end)

    nodes = Enum.reverse(child_nodes) ++ nodes
    edges = Enum.reverse(child_edges) ++ edges
    {nodes, edges, Enum.reverse(child_ids)}
  end

  # Fallback for unknown types
  defp process_step(%Step{} = step, nodes, edges, prev_ids) do
    id = to_string(step.name)

    node = %{
      id: id,
      type: "step",
      data: %{
        label: to_string(step.name),
        step_type: to_string(step.type),
        name: to_string(step.name)
      }
    }

    edges = add_edges(edges, prev_ids, id)
    {[node | nodes], edges, [id]}
  end

  # ============================================================================
  # Edge / branch helpers
  # ============================================================================

  defp build_clause_path(prev_ids, clause_key, step_names, nodes, edges, tails) do
    clause_label = format_clause_key(clause_key)

    case step_names do
      [] ->
        # Empty clause is a passthrough — its prev_ids contribute
        # directly to the branch's returned tails. No nodes, no edges
        # added; the clause label is dropped (rare, and labelless edges
        # to the next step still convey the path).
        case prev_ids do
          nil -> {nodes, edges, tails}
          ids -> {nodes, edges, Enum.reverse(ids) ++ tails}
        end

      [first_name | _] = names ->
        first_id = to_string(first_name)
        last_id = to_string(List.last(names))

        # Fan-in to first step in clause; tag this edge with the clause
        # label so operators see which path led here.
        fan_in =
          for src <- prev_ids || [] do
            %{
              id: "e-#{src}-#{first_id}",
              source: src,
              target: first_id,
              animated: false,
              style: %{},
              label: clause_label
            }
          end

        # Sequential nodes for each step in the clause.
        {clause_nodes, clause_edges, _} =
          Enum.reduce(names, {[], [], nil}, fn name, {cn, ce, prev} ->
            id = to_string(name)
            display = extract_display_name(name, "branch")

            node = %{
              id: id,
              type: "step",
              data: %{
                label: display,
                step_type: "step",
                name: id,
                clause: clause_label,
                original_name: display
              }
            }

            ce = if prev, do: add_edges(ce, [prev], id), else: ce
            {[node | cn], ce, id}
          end)

        nodes = Enum.reverse(clause_nodes) ++ nodes
        edges = Enum.reverse(clause_edges) ++ Enum.reverse(fan_in) ++ edges
        {nodes, edges, [last_id | tails]}
    end
  end

  defp prepend_branch_edges(edges, _source, []), do: edges

  defp prepend_branch_edges(edges, source, branches) do
    branch_edges =
      for target <- branches do
        target_str = to_string(target)

        %{
          id: "e-#{source}-#{target_str}-goto",
          source: source,
          target: target_str,
          animated: false,
          style: %{},
          label: "goto :#{target_str}",
          className: "flow-edge-conditional"
        }
      end

    Enum.reverse(branch_edges) ++ edges
  end

  defp add_edges(edges, nil, _target), do: edges
  defp add_edges(edges, [], _target), do: edges

  defp add_edges(edges, prev_ids, target) when is_list(prev_ids) do
    Enum.reduce(prev_ids, edges, fn src, acc ->
      [build_edge(src, target) | acc]
    end)
  end

  defp build_edge(source, target) do
    %{
      id: "e-#{source}-#{target}",
      source: source,
      target: target,
      animated: false,
      style: %{}
    }
  end

  defp extract_display_name(name, prefix) when is_atom(name) do
    extract_display_name(Atom.to_string(name), prefix)
  end

  defp extract_display_name(name, prefix) when is_binary(name) do
    # "prefix_123__clause__step_name" or "prefix_123__step_name"
    case String.split(name, "__") do
      [_prefix_id, _clause, step_name] -> step_name
      [_prefix_id, step_name] -> step_name
      _ -> String.replace_prefix(name, "#{prefix}_", "")
    end
  end

  defp format_clause_key(:default), do: "default"
  defp format_clause_key(key) when is_atom(key), do: Atom.to_string(key)
  defp format_clause_key(key) when is_binary(key), do: key
  defp format_clause_key(key), do: inspect(key)

  # Secondary index keyed by the unprefixed step name. Used as a fallback
  # when the qualified parallel/branch id in the persisted step_name has
  # drifted from the currently-compiled definition (the DSL mints those
  # via :erlang.unique_integer/1 at macro-expansion time).
  defp index_by_original(step_executions) do
    Enum.reduce(step_executions, %{}, fn step, acc ->
      key = strip_qualifier(step.step_name)
      if key == nil, do: acc, else: stash_more_recent(acc, key, step)
    end)
  end

  defp stash_more_recent(acc, key, step) do
    case Map.get(acc, key) do
      nil -> Map.put(acc, key, step)
      existing -> if step_more_recent?(step, existing), do: Map.put(acc, key, step), else: acc
    end
  end

  defp strip_qualifier(nil), do: nil

  defp strip_qualifier(step_name) when is_binary(step_name) do
    case String.split(step_name, "__") do
      [_prefix, _clause, name] -> name
      [_prefix, name] -> name
      _ -> nil
    end
  end

  defp index_steps(step_executions) do
    Enum.reduce(step_executions, %{}, fn step, acc ->
      key = step.step_name

      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, step)

        existing ->
          if step_more_recent?(step, existing), do: Map.put(acc, key, step), else: acc
      end
    end)
  end

  defp step_more_recent?(a, b) do
    cond do
      a.attempt > b.attempt -> true
      a.attempt < b.attempt -> false
      true -> DateTime.compare(a.inserted_at, b.inserted_at) != :lt
    end
  end
end
