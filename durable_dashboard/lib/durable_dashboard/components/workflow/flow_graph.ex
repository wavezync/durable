defmodule DurableDashboard.Components.Workflow.FlowGraph do
  @moduledoc """
  LiveComponent that wraps the ReactFlow island defined in
  `assets/src/react/flow_graph.tsx` (mounted by the JS hook in
  `assets/src/hooks/flow_graph.ts`).

  ## Communication contract

  - **LV → JS:** Initial graph passes through `data-graph` (JSON in the host
    element's dataset). Subsequent updates use `push_event/3`:
    `"<id>:replace"` `%{graph: %{nodes: [...], edges: [...]}}`.
  - **JS → LV:** `step-clicked` with the step's execution id. The component
    patches the run page's URL to `?step=<id>`, so the page opens the same
    step inspector the Trace view uses — one inspector, linkable, beside the
    graph. A step with no execution (it never ran) has nothing to inspect.

  `selected` (the inspected trace row, or nil) marks its card.
  """

  use Phoenix.LiveComponent

  alias DurableDashboard.Components.Core
  alias DurableDashboard.GraphBuilder
  alias DurableDashboard.Path, as: DPath

  @impl true
  def mount(socket) do
    {:ok, assign(socket, graph: %{nodes: [], edges: []}, version: 0)}
  end

  @impl true
  def update(%{kind: :flow} = assigns, socket) do
    new_graph = build_graph(assigns)
    next_version = socket.assigns.version + 1
    socket = assign(socket, Map.merge(assigns, %{graph: new_graph, version: next_version}))

    socket =
      if connected?(socket) and socket.assigns.version > 1 do
        push_event(socket, replace_event(socket.assigns.id), %{graph: new_graph})
      else
        socket
      end

    {:ok, socket}
  end

  def update(assigns, socket) do
    # Default: no graph — render the empty state.
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("step-clicked", %{"step_execution_id" => id}, socket) when is_binary(id) do
    %{base_path: base, workflow: workflow} = socket.assigns
    path = DPath.execution_tab(base, workflow.id, :graph) <> "?" <> URI.encode_query(step: id)
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("step-clicked", _payload, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <%= if @graph.nodes == [] do %>
        <Core.empty_state
          icon="exclamation-triangle"
          title="No graph available"
          description="The workflow definition isn't loaded on this node, so we can't reconstruct the graph. Make sure the workflow module is compiled into the dashboard's code path."
        />
      <% else %>
        <div
          id={@id}
          phx-hook="FlowGraph"
          phx-update="ignore"
          data-graph={Jason.encode!(@graph)}
          data-graph-version={@version}
          class="rounded-md border border-border bg-card overflow-hidden"
        >
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Graph construction
  # ============================================================================

  defp build_graph(%{kind: :flow, workflow: workflow, steps: steps} = assigns) do
    case definition_for(workflow) do
      {:ok, definition} ->
        opts = [
          current_workflow_id: workflow.id,
          run_status: Map.get(workflow, :status),
          parallel_children_lookup: parallel_children_lookup(assigns[:family])
        ]

        definition
        |> GraphBuilder.build()
        |> GraphBuilder.overlay_status(steps, opts)
        |> mark_selected(assigns[:selected])
        |> normalize()

      :error ->
        %{nodes: [], edges: []}
    end
  end

  defp build_graph(_), do: %{nodes: [], edges: []}

  defp mark_selected(graph, %{ids: ids}) do
    nodes =
      Enum.map(graph.nodes, fn node ->
        if node.data[:step_execution_id] in ids,
          do: put_in(node, [:data, :selected], true),
          else: node
      end)

    %{graph | nodes: nodes}
  end

  defp mark_selected(graph, _selected), do: graph

  # Map step_name → child_workflow_id, sourced from the family root's
  # context. Merges parallel children (`__parallel_children`, written by
  # the executor) with sub-workflow children (`__call_children`, written
  # by `Durable.Orchestration` for `call_workflow` / `start_workflow`).
  # Empty if the family is flat.
  defp parallel_children_lookup(%{root: %{context: ctx}}) when is_map(ctx) do
    parallel = extract_step_to_child(ctx, "__parallel_children")
    call = extract_step_to_child(ctx, "__call_children")
    Map.merge(parallel, call)
  end

  defp parallel_children_lookup(_), do: %{}

  defp extract_step_to_child(ctx, key) do
    case Map.get(ctx, key) do
      m when is_map(m) ->
        m
        |> Enum.map(fn {child_id, meta} ->
          step_name = meta["step_name"] || meta[:step_name]
          if step_name in [nil, ""], do: nil, else: {step_name, child_id}
        end)
        |> Enum.reject(&is_nil/1)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp definition_for(%{workflow_module: module_str, workflow_name: name}) do
    module = Module.safe_concat([module_str])

    # In dev mode modules are lazy-loaded; `function_exported?/3` returns
    # false for an existing-but-not-yet-loaded module. Load it explicitly
    # so the exports check is meaningful.
    _ = Code.ensure_loaded(module)

    cond do
      function_exported?(module, :__workflow_definition__, 1) ->
        case module.__workflow_definition__(name) do
          {:ok, definition} -> {:ok, definition}
          _ -> :error
        end

      function_exported?(module, :__default_workflow__, 0) ->
        case module.__default_workflow__() do
          {:ok, definition} -> {:ok, definition}
          _ -> :error
        end

      true ->
        :error
    end
  rescue
    _ -> :error
  end

  defp definition_for(_), do: :error

  # ReactFlow-shaped: stringify atoms in node ids, types, and data keys so
  # JSON round-trips cleanly to the JS island.
  defp normalize(%{nodes: nodes, edges: edges}) do
    %{
      nodes: Enum.map(nodes, &normalize_node/1),
      edges: Enum.map(edges, &normalize_edge/1)
    }
  end

  defp normalize_node(node) do
    %{
      id: to_string(node.id),
      type: to_string(node.type),
      data: stringify_data(node.data || %{})
    }
  end

  defp normalize_edge(edge) do
    # `className` and `label` carry ALL the runtime edge semantics:
    # `graph_builder.apply_edge_status/3` paints status via className
    # (flow-edge-running / -completed / -pending / -conditional) and
    # `build_clause_path` / `prepend_branch_edges` set the label (clause
    # names, "goto :x"). `graph-layout.ts` reads `e.className`/`e.label`
    # off each edge and forwards them to ReactFlow. Dropping them here —
    # as this function did — silently discarded every edge color, the
    # taken-vs-not-taken decision branch, conditional dashing, and all
    # clause/goto labels, so the graph never reflected execution. Always
    # emit them (nil is fine: a null className/label is a no-op client-side).
    %{
      id: to_string(edge.id),
      source: to_string(edge.source),
      target: to_string(edge.target),
      animated: Map.get(edge, :animated, false),
      style: Map.get(edge, :style, %{}),
      className: Map.get(edge, :className),
      label: Map.get(edge, :label)
    }
  end

  defp stringify_data(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp stringify_value(v), do: v

  defp replace_event(id), do: id <> ":replace"
end
