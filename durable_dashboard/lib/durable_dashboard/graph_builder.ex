defmodule DurableDashboard.GraphBuilder do
  @moduledoc """
  Converts a `%Durable.Definition.Workflow{}` into ReactFlow-compatible
  nodes and edges for graph visualization.

  ## Shape

  The reduce accumulator's third element is a *list* of "tail ids" — the
  node ids the *next* step's inbound edges start from. A linear step returns
  itself. A `parallel` block fans out from the previous step to every child
  and joins them in a small `join` node ("all 3 done"), which is its one
  tail. A `branch` is a `branch` gateway node with one labelled, dashed edge
  per clause; the last step of each clause is a tail.

  Without the join and the gateway, a parallel block followed by a branch
  wired every child to every clause — N × M labelled edges for what is one
  join and one choice.

  `overlay_status/3` then marks what ran: step statuses from their
  executions, the join from its members, the branch from the clause whose
  first step ran (`taken`), and — once the run has finished — the steps
  that never ran (`not_run`).
  """

  alias Durable.Definition.{Step, Workflow}
  alias DurableDashboard.Trace

  # Run statuses after which a step without an execution never ran.
  @finished [:completed, :failed, :cancelled, :compensated, :compensation_failed]

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

    by_name = Map.new(steps, &{to_string(&1.name), &1})

    %{
      nodes: nodes |> Enum.reverse() |> Enum.map(&put_max_attempts(&1, by_name)),
      edges: Enum.reverse(edges)
    }
  end

  def build(_), do: %{nodes: [], edges: []}

  # Retry budget from the step's definition, for "attempt 2 of 3".
  defp put_max_attempts(%{data: %{name: name}} = node, by_name) do
    case by_name[name] do
      %Step{opts: %{retry: %{max_attempts: max}}} -> put_in(node, [:data, :max_attempts], max)
      %Step{type: :step} -> put_in(node, [:data, :max_attempts], 1)
      _ -> node
    end
  end

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
    finished? = Keyword.get(opts, :run_status) in @finished

    nodes =
      Enum.map(nodes, fn node ->
        node =
          case lookup_step(node, step_map, by_original) do
            nil -> put_in(node, [:data, :status], "pending")
            step_exec -> apply_status(node, step_exec, current_id)
          end

        attach_child_workflow_id(node, parallel_children)
      end)

    statuses = Map.new(nodes, &{&1.id, &1.data.status})

    nodes =
      Enum.map(nodes, fn node ->
        node
        |> derive_block_status(statuses)
        |> mark_not_run(finished?)
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

  # A join is done when every member is; a branch has run once the first
  # step of one of its clauses has (that clause is `taken`).
  defp derive_block_status(%{type: "join", data: %{members: members}} = node, statuses) do
    member_statuses = Enum.map(members, &statuses[&1])

    status =
      cond do
        "failed" in member_statuses -> "failed"
        Enum.any?(member_statuses, &(&1 in ["running", "waiting"])) -> "running"
        Enum.all?(member_statuses, &(&1 == "completed")) -> "completed"
        true -> "pending"
      end

    node
    |> put_in([:data, :status], status)
    |> put_in([:data, :done], Enum.count(member_statuses, &(&1 == "completed")))
  end

  defp derive_block_status(%{type: "branch", data: %{paths: paths}} = node, statuses) do
    taken = Enum.find(paths, &(&1.first && statuses[&1.first] not in [nil, "pending"]))

    node
    |> put_in([:data, :status], if(taken, do: "completed", else: "pending"))
    |> put_in([:data, :taken], taken && taken.clause)
  end

  defp derive_block_status(node, _statuses), do: node

  # In a finished run, a step with no execution never ran — say so, rather
  # than "pending", which reads as "about to".
  defp mark_not_run(%{data: %{status: "pending"}} = node, true),
    do: put_in(node, [:data, :not_run], true)

  defp mark_not_run(node, _finished?), do: node

  # Conditional edges (branch clauses, decision :goto targets): the taken one
  # repaints as the run's path; untaken ones stay dashed as
  # `flow-edge-conditional` — the paths this run didn't take.
  defp apply_edge_status(%{className: "flow-edge-conditional"} = edge, matched, running) do
    cond do
      MapSet.member?(running, edge.target) ->
        edge
        |> Map.put(:animated, true)
        |> Map.put(:className, "flow-edge-running")

      MapSet.member?(matched, edge.source) and MapSet.member?(matched, edge.target) ->
        Map.put(edge, :className, "flow-edge-completed")

      true ->
        # Untaken — leave the dashed conditional styling alone.
        edge
    end
  end

  defp apply_edge_status(edge, matched_ids, running_ids) do
    cond do
      MapSet.member?(running_ids, edge.target) ->
        edge
        |> Map.put(:animated, true)
        |> Map.put(:className, "flow-edge-running")

      MapSet.member?(matched_ids, edge.source) and MapSet.member?(matched_ids, edge.target) ->
        # Linear-flow completed edges stay static — only running and
        # taken-goto edges animate, otherwise a long workflow becomes
        # visually noisy with everything dashing simultaneously.
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
    |> put_in([:data, :input_preview], preview(Map.get(step_exec, :input)))
    |> put_in([:data, :output_preview], preview(Trace.returned(Map.get(step_exec, :output))))
    |> put_in([:data, :has_error], not is_nil(Map.get(step_exec, :error)))
    |> put_in([:data, :error], error_line(Map.get(step_exec, :error)))
    |> maybe_link_child(step_exec)
    |> maybe_ran_in_child(step_exec, current_id)
  end

  defp error_line(%{} = error) do
    type = error["type"] || error[:type]
    message = error["message"] || error[:message]
    [type, message] |> Enum.reject(&is_nil/1) |> Enum.join(": ") |> truncate(160)
  end

  defp error_line(_error), do: nil

  # A parallel child that ran as its own run: its execution belongs to that
  # run, not this one. Open it from the card.
  defp maybe_ran_in_child(%{data: %{child_workflow_id: id}} = node, _step_exec, _current)
       when is_binary(id),
       do: node

  defp maybe_ran_in_child(node, %{workflow_id: run_id}, current_id)
       when is_binary(run_id) and is_binary(current_id) and run_id != current_id do
    node
    |> put_in([:data, :child_workflow_id], run_id)
    |> Map.put(:type, "child_workflow")
  end

  defp maybe_ran_in_child(node, _step_exec, _current_id), do: node

  # Prefer the queryable `step_executions.child_workflow_id` link (recorded by
  # the executor when a step calls call_workflow/start_workflow) over parsing
  # the parent's mutable `__call_children` context. When present, flip the node
  # to the `child_workflow` type (same cell footprint, stacked-sheet drill-in).
  defp maybe_link_child(node, step_exec) do
    case Map.get(step_exec, :child_workflow_id) do
      child_id when is_binary(child_id) ->
        node
        |> put_in([:data, :child_workflow_id], child_id)
        |> Map.put(:type, "child_workflow")

      _ ->
        node
    end
  end

  # Single-line preview of an input/output blob, suitable for an n8n-style
  # card. Full data lives on the StepExecution row and is fetched on demand
  # when the user opens the drawer — keeps the graph payload lean.
  @preview_max 80
  defp preview(nil), do: nil
  defp preview(value) when value == %{}, do: nil

  defp preview(value) do
    case Jason.encode(value) do
      {:ok, json} -> truncate(json, @preview_max)
      _ -> nil
    end
  end

  defp truncate(s, max) when is_binary(s) do
    if String.length(s) > max do
      String.slice(s, 0, max - 1) <> "…"
    else
      s
    end
  end

  # When a node represents a parallel child step that ran in its own
  # `WorkflowExecution`, surface the child workflow id in node.data AND
  # flip the node type to `child_workflow` so the React side renders the
  # drill-in variant (the step card with a stacked sheet behind it).
  defp attach_child_workflow_id(%{data: data} = node, lookup) when map_size(lookup) > 0 do
    cond do
      # Already linked via the queryable step_executions.child_workflow_id
      # column (call_workflow children) — don't second-guess it.
      get_in(data, [:child_workflow_id]) ->
        node

      child_id = Map.get(lookup, get_in(data, [:name])) || Map.get(lookup, node.id) ->
        node
        |> put_in([:data, :child_workflow_id], child_id)
        |> Map.put(:type, "child_workflow")

      true ->
        node
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

  # Branch step — a gateway node, then one labelled conditional edge to the
  # first step of each clause (in the order they're written). The last step
  # of each clause is a tail; an empty clause makes the gateway itself one.
  defp process_step(%Step{type: :branch} = step, nodes, edges, prev_ids) do
    clauses = step.opts[:clauses] || %{}

    if clauses == %{} do
      {nodes, edges, prev_ids}
    else
      id = to_string(step.name)
      ordered = Enum.sort_by(clauses, fn {{_key, idx}, _names} -> idx end)

      paths =
        for {{key, _idx}, names} <- ordered,
            do: %{clause: format_clause_key(key), first: names |> List.first() |> to_str()}

      gateway = %{
        id: id,
        type: "branch",
        data: %{label: "branch", step_type: "branch", name: id, paths: paths}
      }

      {clause_nodes, clause_edges, clause_tails} =
        Enum.reduce(ordered, {[], [], []}, fn {{clause_key, _idx}, step_names}, {cn, ce, tails} ->
          build_clause_path([id], clause_key, step_names, cn, ce, tails)
        end)

      nodes = Enum.reverse(clause_nodes) ++ [gateway | nodes]
      edges = Enum.reverse(clause_edges) ++ add_edges(edges, prev_ids, id)
      {nodes, edges, Enum.reverse(clause_tails)}
    end
  end

  # Parallel step — N children running concurrently. The previous step fans
  # out to every child; the children meet in a `join` node, the block's one
  # tail.
  defp process_step(%Step{type: :parallel} = step, nodes, edges, prev_ids) do
    case step.opts[:steps] || step.opts[:all_steps] || [] do
      [] -> {nodes, edges, prev_ids}
      child_steps -> parallel_block(step, child_steps, nodes, edges, prev_ids)
    end
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

  defp parallel_block(step, child_steps, nodes, edges, prev_ids) do
    join_id = "#{step.name}__join"

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

    child_ids = Enum.reverse(child_ids)

    join = %{
      id: join_id,
      type: "join",
      data: %{label: "join", step_type: "join", name: join_id, members: child_ids}
    }

    join_edges = Enum.reduce(child_ids, [], &[build_edge(&1, join_id) | &2])

    nodes = [join | Enum.reverse(child_nodes)] ++ nodes
    edges = join_edges ++ Enum.reverse(child_edges) ++ edges
    {nodes, edges, [join_id]}
  end

  defp to_str(nil), do: nil
  defp to_str(name), do: to_string(name)

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

        # The gateway's edge into the clause, labelled with its value and
        # dashed until the run takes it.
        fan_in =
          for src <- prev_ids || [] do
            %{
              id: "e-#{src}-#{first_id}",
              source: src,
              target: first_id,
              animated: false,
              style: %{},
              label: clause_label,
              className: "flow-edge-conditional"
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

  defp format_clause_key(key) when key in [:default, :_], do: "otherwise"
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
