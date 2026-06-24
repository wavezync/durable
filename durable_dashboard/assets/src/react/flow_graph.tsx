/**
 * ReactFlow island used by the dashboard's workflow detail view.
 *
 * Mount via `mountFlowIsland(el, graph)`. Returns a handle the JS hook
 * uses to feed in updates from the LiveView side. The island is the only
 * piece of React in the dashboard stack; everything else is HEEx.
 *
 * Visual treatment: themed step / decision / parallel nodes live in
 * `./nodes/`. Background, controls, minimap, edges all read from the
 * dashboard's design tokens via `assets/src/index.css` overrides.
 */

import {
  Background,
  Controls,
  type Edge,
  MiniMap,
  type Node,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
} from "@xyflow/react";
import { useEffect, useMemo, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { layoutGraph } from "../lib/graph-layout";
import { resolveToken } from "../lib/tokens";
import type { GraphData } from "../lib/types";
import { AnimatedFlowEdge } from "./edges/animated_flow_edge";
import { ChildWorkflowNode } from "./nodes/child_workflow_node";
import { EndNode } from "./nodes/end_node";
import { GatewayNode } from "./nodes/gateway_node";
import { HiddenNode } from "./nodes/hidden_node";
import { StartNode } from "./nodes/start_node";
import { StepNode } from "./nodes/step_node";

// Server-emitted node `type` strings → React components. See DESIGN.md §11.
//
// `parallel_fork` / `parallel_join` / `branch_fork` / `branch_join` are no
// longer emitted by `graph_builder.ex` — fan-out / fan-in is expressed
// purely through edge geometry. They are still registered here as the
// `HiddenNode` fallback so a stale BEAM that still emits them doesn't
// surface as floating "Parallel" / "Join" text on the canvas (which is
// what ReactFlow's default node renderer would do for unknown types).
//
// `child_workflow` is the n8n-style wider card emitted by
// `graph_builder.attach_child_workflow_id/2` for parallel children that
// have their own WorkflowExecution row — see DESIGN.md §11.
const NODE_TYPES = {
  step: StepNode,
  decision: GatewayNode,
  start: StartNode,
  end: EndNode,
  child_workflow: ChildWorkflowNode,
  parallel_fork: HiddenNode,
  parallel_join: HiddenNode,
  branch_fork: HiddenNode,
  branch_join: HiddenNode,
} as const;

const EDGE_TYPES = {
  animated_flow: AnimatedFlowEdge,
} as const;

interface FlowIsland {
  setGraph(graph: GraphData): void;
  patchNode(id: string, patch: Record<string, unknown>): void;
  destroy(): void;
}

export function mountFlowIsland(el: HTMLElement, initialGraph: GraphData): FlowIsland {
  if (!el.style.height) el.style.height = "560px";
  el.style.width = "100%";

  const root: Root = createRoot(el);

  const handlers = {
    setGraph: (_graph: GraphData) => {},
    patchNode: (_id: string, _patch: Record<string, unknown>) => {},
  };

  root.render(
    <ReactFlowProvider>
      <FlowIslandRoot
        initialGraph={initialGraph}
        registerHandlers={(setGraph, patchNode) => {
          handlers.setGraph = setGraph;
          handlers.patchNode = patchNode;
        }}
      />
    </ReactFlowProvider>,
  );

  return {
    setGraph(graph) {
      handlers.setGraph(graph);
    },
    patchNode(id, patch) {
      handlers.patchNode(id, patch);
    },
    destroy() {
      root.unmount();
    },
  };
}

// ============================================================================
// Internal React component
// ============================================================================

interface FlowIslandRootProps {
  initialGraph: GraphData;
  registerHandlers: (
    setGraph: (graph: GraphData) => void,
    patchNode: (id: string, patch: Record<string, unknown>) => void,
  ) => void;
}

// Topology signature: node ids + types + edge ids. Status/data/className
// changes do NOT alter it. The layout (dagre) only needs to re-run when this
// changes; a realtime status tick keeps the same signature and reuses cached
// positions, so the canvas no longer reflows on every update.
function topoSignature(graph: GraphData): string {
  const nodes = graph.nodes
    .map((n) => `${n.id}:${n.type}`)
    .sort()
    .join("|");
  const edges = graph.edges
    .map((e) => e.id)
    .sort()
    .join("|");
  return `${nodes}__${edges}`;
}

function FlowIslandRoot({ initialGraph, registerHandlers }: FlowIslandRootProps) {
  const [graph, setGraphState] = useState<GraphData>(initialGraph);
  const { fitView } = useReactFlow();

  // Cache of the last layout's positions + the topology they belong to.
  const layoutRef = useRef<{
    sig: string;
    positions: Map<string, { x: number; y: number }>;
  }>({ sig: "", positions: new Map() });
  // Fit the viewport on first paint and whenever topology grows/shrinks,
  // never on a plain status tick (which would yank the viewport mid-read).
  const fitPendingRef = useRef(true);

  useEffect(() => {
    registerHandlers(
      (next) => setGraphState(next),
      (id, patch) =>
        setGraphState((prev) => ({
          ...prev,
          nodes: prev.nodes.map((n) =>
            n.id === id
              ? ({ ...n, data: { ...n.data, ...patch } } as GraphData["nodes"][number])
              : n,
          ),
        })),
    );
  }, [registerHandlers]);

  const { nodes, edges } = useMemo(() => {
    const sig = topoSignature(graph);
    const reuse = sig === layoutRef.current.sig && layoutRef.current.positions.size > 0;
    const result = layoutGraph(graph, reuse ? layoutRef.current.positions : undefined);
    layoutRef.current = { sig, positions: result.positions };
    if (!reuse) fitPendingRef.current = true;
    return { nodes: result.nodes, edges: result.edges };
  }, [graph]);

  // Re-fit only when a relayout happened (topology change / first paint).
  // requestAnimationFrame lets ReactFlow measure the new nodes first.
  useEffect(() => {
    if (!fitPendingRef.current || nodes.length === 0) return;
    fitPendingRef.current = false;
    const raf = requestAnimationFrame(() => fitView({ padding: 0.2, duration: 200 }));
    return () => cancelAnimationFrame(raf);
  }, [nodes, fitView]);

  return (
    <ReactFlow
      nodes={nodes as Node[]}
      edges={edges as Edge[]}
      nodeTypes={NODE_TYPES}
      edgeTypes={EDGE_TYPES}
      fitViewOptions={{ padding: 0.2 }}
      proOptions={{ hideAttribution: true }}
      defaultEdgeOptions={{ type: "animated_flow" }}
      minZoom={0.2}
      maxZoom={2}
      // Explicit viewport interaction props — defaults are already on
      // for these, but spelling them out makes the intent obvious and
      // guards against silent regressions. Dashboard users should be
      // able to zoom, pan, and rearrange nodes when inspecting a run.
      nodesDraggable
      nodesConnectable={false}
      panOnDrag
      zoomOnScroll
      zoomOnPinch
      panOnScroll={false}
      selectionOnDrag={false}
    >
      <Background gap={24} size={1} />
      <Controls position="bottom-right" showInteractive={false} />
      <MiniMap
        position="top-right"
        nodeStrokeWidth={1}
        nodeBorderRadius={4}
        pannable
        zoomable
        nodeColor={miniMapNodeColor}
        nodeStrokeColor={miniMapNodeStroke}
        // Translucent mask (was a solid --background that read as an all-black
        // wash hiding the nodes). A CSS color-mix string stays theme-reactive.
        maskColor="color-mix(in oklch, var(--background) 55%, transparent)"
      />
    </ReactFlow>
  );
}

// ============================================================================
// Minimap node coloring — by status, with sensible fallbacks. Token strings
// are resolved at call time from the live theme so light/dark switches don't
// require a re-render of this component.
// ============================================================================

function miniMapNodeColor(node: Node): string {
  const status = (node.data as { status?: string } | undefined)?.status;
  switch (status) {
    case "running":
    case "completed":
      return resolveToken("--success");
    case "failed":
      return resolveToken("--destructive");
    case "waiting":
      return resolveToken("--warning");
    default:
      return resolveToken("--muted-foreground");
  }
}

function miniMapNodeStroke(node: Node): string {
  const status = (node.data as { status?: string } | undefined)?.status;
  return status === "running" ? resolveToken("--success") : "transparent";
}
