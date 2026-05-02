/**
 * Graph layout for the workflow detail FlowGraph.
 *
 * Single dagre LR run over every emitted node (DESIGN.md §11). Parallel
 * fork/join markers are first-class nodes — no bounding-rectangle group
 * container, no inner sub-layout. Branches splay between the markers
 * naturally because dagre orders them by rank.
 *
 * Adds explicit Start / End marker nodes that anchor the boundaries so
 * the flow direction reads at a glance even when panned.
 */

import dagre from "@dagrejs/dagre";
import type { Edge, Node } from "@xyflow/react";
import type { GraphData, GraphEdge } from "./types";

// ---------------------------------------------------------------------------
// Sizing — must match the React node components in `assets/src/react/nodes`.
// Every node is a uniform 88×96 cell (64×64 icon box + label region below)
// for the n8n-inspired rhythm. See DESIGN.md §11.
// ---------------------------------------------------------------------------
const CELL_WIDTH = 88;
const CELL_HEIGHT = 96;

const NODESEP = 40;
const RANKSEP = 80;
const MARGIN = 32;

const START_NODE_ID = "__durable_start__";
const END_NODE_ID = "__durable_end__";

interface Dim {
  width: number;
  height: number;
}

// Every node renders as the same 88×96 cell (64 icon + 32 label). Keeps
// the visual rhythm and makes dagre's collision math trivial.
function dimsFor(_type: string): Dim {
  return { width: CELL_WIDTH, height: CELL_HEIGHT };
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

export function layoutGraph(graph: GraphData): { nodes: Node[]; edges: Edge[] } {
  // Synthesize start/end markers wrapping the whole flow.
  const allNodes = [
    ...graph.nodes.map((n) => ({ id: n.id, type: n.type, data: n.data })),
    { id: START_NODE_ID, type: "start", data: {} as Record<string, unknown> },
    { id: END_NODE_ID, type: "end", data: {} as Record<string, unknown> },
  ];

  const { rootIds, leafIds } = computeRootsLeaves(graph.nodes, graph.edges);

  const allEdges: GraphEdge[] = [
    ...graph.edges,
    ...rootIds.map((r) => boundaryEdge(START_NODE_ID, r)),
    ...leafIds.map((l) => boundaryEdge(l, END_NODE_ID)),
  ];

  const positions = layoutDagre(allNodes, allEdges);

  const nodes: Node[] = allNodes.map((n) => {
    const pos = positions.get(n.id) || { x: 0, y: 0 };
    return {
      id: n.id,
      type: n.type,
      position: pos,
      data: (n.data ?? {}) as Record<string, unknown>,
    };
  });

  const edges: Edge[] = allEdges.map((e) => ({
    id: e.id,
    source: e.source,
    target: e.target,
    animated: e.animated || false,
    style: e.style || {},
    label: e.label,
    className: e.className,
    type: "animated_flow",
  }));

  return { nodes, edges };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function boundaryEdge(source: string, target: string): GraphEdge {
  return {
    id: `__edge_${source}_${target}__`,
    source,
    target,
    animated: false,
    style: {},
  };
}

function computeRootsLeaves(
  nodes: { id: string; type: string }[],
  edges: GraphEdge[],
): { rootIds: string[]; leafIds: string[] } {
  const inDeg = new Map<string, number>();
  const outDeg = new Map<string, number>();
  for (const n of nodes) {
    inDeg.set(n.id, 0);
    outDeg.set(n.id, 0);
  }
  for (const e of edges) {
    inDeg.set(e.target, (inDeg.get(e.target) || 0) + 1);
    outDeg.set(e.source, (outDeg.get(e.source) || 0) + 1);
  }
  const rootIds: string[] = [];
  const leafIds: string[] = [];
  for (const n of nodes) {
    if ((inDeg.get(n.id) || 0) === 0) rootIds.push(n.id);
    if ((outDeg.get(n.id) || 0) === 0) leafIds.push(n.id);
  }
  return { rootIds, leafIds };
}

function layoutDagre(
  nodes: { id: string; type: string }[],
  edges: GraphEdge[],
): Map<string, { x: number; y: number }> {
  const g = new dagre.graphlib.Graph();
  g.setDefaultEdgeLabel(() => ({}));
  g.setGraph({
    rankdir: "LR",
    nodesep: NODESEP,
    ranksep: RANKSEP,
    marginx: MARGIN,
    marginy: MARGIN,
  });

  for (const n of nodes) {
    const { width, height } = dimsFor(n.type);
    g.setNode(n.id, { width, height });
  }
  for (const e of edges) g.setEdge(e.source, e.target);
  dagre.layout(g);

  const positions = new Map<string, { x: number; y: number }>();
  for (const n of nodes) {
    const dn = g.node(n.id);
    const { width, height } = dimsFor(n.type);
    positions.set(n.id, {
      x: dn.x - width / 2,
      y: dn.y - height / 2,
    });
  }
  return positions;
}
