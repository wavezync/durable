# M01: Graph Visualization

**Status:** Not Started
**Priority:** Medium
**Effort:** 1 week
**Dependencies:** None

## Motivation

Complex workflows with branches, parallel blocks, and compensation edges are hard to reason about from code alone. Graph visualization provides a structural view of workflow definitions and, with execution state overlay, lets developers debug running/failed workflows visually. This also feeds into M06 (Phoenix Dashboard) as the primary workflow visualization component.

## Scope

### In Scope

- Graph data structure (`%Graph{nodes, edges}`) from workflow definitions
- Builder that walks `Durable.Definition` structs
- Export to DOT (Graphviz), Mermaid, and Cytoscape.js JSON formats
- Execution state overlay (join graph nodes with `step_executions` data)
- Support for all node types: step, decision, branch, parallel (fork/join), compensation

### Out of Scope

- Live/real-time graph updates (deferred to M05/M06 — needs message bus)
- Visual layout engine (consumers handle layout — DOT/Mermaid/Cytoscape all have their own)
- Phoenix LiveView rendering (M06)
- WebSocket streaming (M06)

## Architecture & Design

### Module Layout

```
lib/durable/graph.ex                    # Public API: generate/2, with_execution_state/3
lib/durable/graph/builder.ex            # Walks Definition structs → %Graph{}
lib/durable/graph/export/dot.ex         # DOT format export
lib/durable/graph/export/mermaid.ex     # Mermaid format export
lib/durable/graph/export/cytoscape.ex   # Cytoscape.js JSON export
```

### Data Structures

```elixir
defmodule Durable.Graph do
  defstruct [:workflow_name, :workflow_module, nodes: [], edges: []]

  defmodule Node do
    defstruct [:id, :type, :label, :metadata]
    # type: :start | :end | :step | :decision | :branch_fork | :branch_join
    #       | :parallel_fork | :parallel_join | :compensation
  end

  defmodule Edge do
    defstruct [:from, :to, :label, :type]
    # type: :normal | :branch | :compensation | :parallel
  end
end
```

### Builder Logic

The builder walks the list of `%Durable.Definition.Step{}` structs returned by `Module.__workflow_definition__/1`:

1. Add `:start` node
2. Iterate steps in order:
   - **Regular step** → add node + edge from previous
   - **Decision** → add diamond node, edges for each `{:goto, target}`
   - **Branch** → add fork node, walk each branch's steps, add join node
   - **Parallel** → add fork node, one edge per parallel step, add join node
   - **Step with `compensate:`** → add dashed compensation edge back to compensate target
3. Add `:end` node

### Execution State Overlay

```elixir
Durable.Graph.with_execution_state(graph, workflow_id, opts)
```

Queries `step_executions` via `Durable.Query` and merges status/timing into node metadata:

```elixir
%Node{
  id: :charge_payment,
  type: :step,
  metadata: %{
    execution: %{
      status: :completed,
      attempt: 2,
      duration_ms: 1234,
      started_at: ~U[...],
      completed_at: ~U[...]
    }
  }
}
```

### Export Format Details

**DOT**: Standard Graphviz digraph. Nodes styled by type (diamonds for decisions, boxes for steps, etc.). Execution state colors: green=completed, blue=running, red=failed, gray=pending.

**Mermaid**: `flowchart TD` format. Branch/parallel rendered as subgraphs. Compatible with GitHub markdown rendering.

**Cytoscape.js**: JSON elements array with `{ data: { id, label, type, ... } }` for nodes and `{ data: { source, target, label } }` for edges. Ready for frontend consumption.

## Implementation Plan

1. **Graph struct & public API** — `lib/durable/graph.ex`
   - Define `%Graph{}`, `%Node{}`, `%Edge{}` structs
   - Public functions: `generate/2`, `with_execution_state/3`
   - Delegate to builder/query internally

2. **Graph builder** — `lib/durable/graph/builder.ex`
   - `build/1` takes a workflow module, returns `%Graph{}`
   - Walk `__workflow_definition__/1` step list
   - Handle each step type (step, decision, branch, parallel, compensation)
   - Pure function — no side effects, no DB access

3. **DOT exporter** — `lib/durable/graph/export/dot.ex`
   - `to_dot/1` takes `%Graph{}`, returns DOT string
   - Node shape mapping: step→box, decision→diamond, start/end→circle
   - Optional execution state coloring

4. **Mermaid exporter** — `lib/durable/graph/export/mermaid.ex`
   - `to_mermaid/1` takes `%Graph{}`, returns Mermaid string
   - Use `flowchart TD` direction
   - Subgraphs for parallel blocks

5. **Cytoscape exporter** — `lib/durable/graph/export/cytoscape.ex`
   - `to_cytoscape/1` takes `%Graph{}`, returns JSON-encodable map
   - Standard Cytoscape elements format

6. **Execution overlay** — integrate into `lib/durable/graph.ex`
   - Query step executions for a workflow_id
   - Merge execution data into node metadata

## Testing Strategy

- `test/durable/graph/builder_test.exs` — test graph generation for each workflow pattern:
  - Linear steps
  - Decision with goto
  - Branch with multiple paths
  - Parallel block
  - Compensation edges
  - Mixed (branch + parallel + compensation)
- `test/durable/graph/export/dot_test.exs` — validate DOT output format
- `test/durable/graph/export/mermaid_test.exs` — validate Mermaid output format
- `test/durable/graph/export/cytoscape_test.exs` — validate Cytoscape JSON structure
- `test/durable/graph/execution_state_test.exs` — test overlay with DB fixtures (use DataCase)
- Define test workflow modules in `test/support/` for predictable graph structures

## Acceptance Criteria

- [ ] `Durable.Graph.generate(MyWorkflow)` returns `%Graph{}` with correct nodes/edges
- [ ] All step types produce expected graph structures (step, decision, branch, parallel, compensation)
- [ ] DOT export produces valid Graphviz syntax (verify with `dot -Tsvg` if available)
- [ ] Mermaid export produces valid Mermaid syntax
- [ ] Cytoscape export produces valid JSON elements
- [ ] Execution state overlay merges step status into node metadata
- [ ] All exports handle execution state coloring/annotation
- [ ] No duplicated nodes or edges for converging branches
- [ ] `mix credo --strict` passes
- [ ] All new tests pass

## Open Questions

- Should `generate/2` accept a workflow name filter for modules with multiple workflows?
- Should execution overlay include step logs summary (log count, last error)?
- Do we need a `to_ascii/1` exporter for terminal output in mix tasks (M02)?

## References

- `agents/arch.md` — "Graph Visualization" section for target API and data structures
- `lib/durable/definition.ex` — `%Step{}` struct that builder walks
- `lib/durable/query.ex` — query functions for execution state overlay
- `lib/durable/executor.ex` — understanding of step type handling
