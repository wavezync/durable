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
} from "@xyflow/react";
import { useEffect, useMemo, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { layoutGraph } from "../lib/graph-layout";
import { resolveToken } from "../lib/tokens";
import type { GraphData } from "../lib/types";
import { AnimatedFlowEdge } from "./edges/animated_flow_edge";
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
const NODE_TYPES = {
  step: StepNode,
  decision: GatewayNode,
  start: StartNode,
  end: EndNode,
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

function FlowIslandRoot({ initialGraph, registerHandlers }: FlowIslandRootProps) {
  const [graph, setGraphState] = useState<GraphData>(initialGraph);

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

  const { nodes, edges } = useMemo(() => layoutGraph(graph), [graph]);

  return (
    <ReactFlow
      nodes={nodes as Node[]}
      edges={edges as Edge[]}
      nodeTypes={NODE_TYPES}
      edgeTypes={EDGE_TYPES}
      fitView
      fitViewOptions={{ padding: 0.2 }}
      proOptions={{ hideAttribution: true }}
      defaultEdgeOptions={{ type: "animated_flow" }}
      minZoom={0.2}
      maxZoom={1.5}
    >
      <Background gap={24} size={1} />
      <Controls position="bottom-right" showInteractive={false} />
      <MiniMap
        position="top-right"
        nodeStrokeWidth={1}
        pannable
        zoomable
        nodeColor={miniMapNodeColor}
        nodeStrokeColor={miniMapNodeStroke}
        maskColor={resolveToken("--background", "rgba(0,0,0,0.5)")}
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
