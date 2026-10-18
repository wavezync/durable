/**
 * ReactFlow island used by the dashboard's workflow detail view.
 *
 * Mount via `mountFlowIsland(el, graph)`. Returns a handle the JS hook
 * uses to feed in updates from the LiveView side. The island is the only
 * piece of React in the dashboard stack; everything else is HEEx.
 *
 * Visual treatment: themed step / decision / join / branch nodes live in
 * `./nodes/`. Background, controls and edges read from the dashboard's
 * design tokens via `assets/src/index.css` overrides; a legend names the
 * edge styles. No minimap — run graphs are small enough to fit.
 */

import {
  Background,
  Controls,
  type Edge,
  type Node,
  Panel,
  ReactFlow,
  ReactFlowProvider,
  useReactFlow,
} from "@xyflow/react";
import { useEffect, useMemo, useRef, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { graphBounds, layoutGraph } from "../lib/graph-layout";
import type { GraphData } from "../lib/types";
import { AnimatedFlowEdge } from "./edges/animated_flow_edge";
import { BranchNode, JoinNode } from "./nodes/block_nodes";
import { ChildWorkflowNode } from "./nodes/child_workflow_node";
import { EndNode } from "./nodes/end_node";
import { GatewayNode } from "./nodes/gateway_node";
import { HiddenNode } from "./nodes/hidden_node";
import { StartNode } from "./nodes/start_node";
import { StepNode } from "./nodes/step_node";

// Server-emitted node `type` strings → React components. See DESIGN.md §11.
//
// `join` closes a parallel block and `branch` is a branch's gateway.
// `child_workflow` is a step that ran as its own run. The old
// `parallel_fork` / `parallel_join` / `branch_fork` / `branch_join` markers
// map to `HiddenNode`, so a stale BEAM that still emits them doesn't surface
// as floating text (ReactFlow's default renderer for unknown types).
const NODE_TYPES = {
  step: StepNode,
  decision: GatewayNode,
  join: JoinNode,
  branch: BranchNode,
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
  // Until the first layout sizes it to the graph (see `frame`).
  if (!el.style.height) el.style.height = "420px";
  el.style.width = "100%";

  const root: Root = createRoot(el);

  const handlers = {
    setGraph: (_graph: GraphData) => {},
    patchNode: (_id: string, _patch: Record<string, unknown>) => {},
  };

  root.render(
    <ReactFlowProvider>
      <FlowIslandRoot
        host={el}
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
  host: HTMLElement;
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

// Text stays legible: never zoom out past this to fit. A wider graph opens at
// its start and pans.
const MIN_FIT_ZOOM = 0.75;
const PAD = 32;
// Room under the graph for the legend, so it never covers a card.
const LEGEND = 36;
const MIN_HEIGHT = 280;
const MAX_HEIGHT = 640;

function FlowIslandRoot({ host, initialGraph, registerHandlers }: FlowIslandRootProps) {
  const [graph, setGraphState] = useState<GraphData>(initialGraph);
  const { setViewport } = useReactFlow();

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

    // Size the canvas to the graph at the zoom it will show at, then frame
    // it above the legend: centred when it fits at a legible zoom (never
    // above 1, so a small graph isn't blown up), otherwise from its start.
    const box = graphBounds(nodes);
    const width = host.clientWidth;
    const fitZoom = (width - 2 * PAD) / box.width;
    const zoom = Math.min(1, Math.max(MIN_FIT_ZOOM, fitZoom));
    const height = Math.min(MAX_HEIGHT, Math.max(MIN_HEIGHT, box.height * zoom + 2 * PAD + LEGEND));
    host.style.height = `${Math.round(height)}px`;

    const left = fitZoom >= MIN_FIT_ZOOM ? (width - box.width * zoom) / 2 : PAD;
    const raf = requestAnimationFrame(() =>
      setViewport(
        {
          x: left - box.x * zoom,
          y: (height - LEGEND - box.height * zoom) / 2 - box.y * zoom,
          zoom,
        },
        { duration: 200 },
      ),
    );
    return () => cancelAnimationFrame(raf);
  }, [nodes, setViewport, host]);

  return (
    <ReactFlow
      nodes={nodes as Node[]}
      edges={edges as Edge[]}
      nodeTypes={NODE_TYPES}
      edgeTypes={EDGE_TYPES}
      fitViewOptions={{ padding: 0.15, maxZoom: 1 }}
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
      <Panel position="bottom-left">
        <Legend />
      </Panel>
    </ReactFlow>
  );
}

// ============================================================================
// Legend — what the edge styles mean.
// ============================================================================

function Line({ className }: { className: string }) {
  return (
    <svg width="22" height="6" aria-hidden="true" className="shrink-0">
      <line x1="0" y1="3" x2="22" y2="3" className={className} />
    </svg>
  );
}

function Legend() {
  return (
    <div className="flex items-center gap-3 rounded-md border border-border bg-card/90 px-2.5 py-1.5 text-[11px] text-muted-foreground backdrop-blur-sm">
      <span className="flex items-center gap-1.5">
        <Line className="legend-ran" /> ran
      </span>
      <span className="flex items-center gap-1.5">
        <Line className="legend-running" /> running
      </span>
      <span className="flex items-center gap-1.5">
        <Line className="legend-untaken" /> path not taken
      </span>
      <span className="flex items-center gap-1.5">
        <Line className="legend-pending" /> not reached
      </span>
    </div>
  );
}
