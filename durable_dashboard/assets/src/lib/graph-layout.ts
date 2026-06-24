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
import { type Edge, MarkerType, type Node } from "@xyflow/react";
import type { GraphData, GraphEdge } from "./types";

// ---------------------------------------------------------------------------
// Sizing — must match the React node components in `assets/src/react/nodes`.
// Horizontal status cards (Argo/Dagster/GitHub-style), uniform height so the
// LR ranks read like an execution timeline. `child_workflow` nodes share the
// step cell's exact footprint — they're the same card with a stacked sheet
// behind it (the drill-in signature), which only peeks a few px beyond the
// box and so doesn't change the dagre footprint. See DESIGN.md §11.
// ---------------------------------------------------------------------------
const CELL_WIDTH = 200;
const CELL_HEIGHT = 56;

// Start/End render as small terminal pills, not full cards.
const TERMINAL_WIDTH = 52;
const TERMINAL_HEIGHT = 28;

// Spacing chosen to keep neighbouring rows visually separate even when
// goto branches force dagre to splay nodes onto extra rows. Previous
// 40/80 was too tight (sub-row goto targets dipped *into* the main
// lane); 60/110 was an improvement but still left branch-merge
// patterns reading as "node sitting in a half-row dip." The current
// 100/120 makes a goto sub-lane read as deliberate vertical
// separation rather than misalignment.
// Cards are wider + uniform-height now, so they need less vertical splay;
// near-equal rank/node gaps read grid-like (Argo's ranksep≈nodesep insight).
const NODESEP = 70;
const RANKSEP = 110;
const MARGIN = 40;

const START_NODE_ID = "__durable_start__";
const END_NODE_ID = "__durable_end__";

const ARROW_MARKER = {
  type: MarkerType.ArrowClosed,
  width: 14,
  height: 14,
  color: "var(--muted-foreground)",
};

interface Dim {
  width: number;
  height: number;
}

function dimsFor(type: string): Dim {
  if (type === "start" || type === "end") {
    return { width: TERMINAL_WIDTH, height: TERMINAL_HEIGHT };
  }
  // child_workflow shares the step cell footprint (see sizing note above).
  return { width: CELL_WIDTH, height: CELL_HEIGHT };
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

type PositionMap = Map<string, { x: number; y: number }>;

/**
 * Lay out a graph for ReactFlow.
 *
 * `prevPositions` is the position map from a previous layout of the SAME
 * topology. When supplied and complete (covers every node we're about to
 * render, including the synthesized start/end markers), dagre is skipped
 * and the cached coordinates are reused verbatim. This is what stops the
 * canvas from re-laying-out and snapping nodes on every realtime status
 * tick during an active run — the bug that made the graph "jump around"
 * while a workflow was executing. The caller only passes `prevPositions`
 * when the topology signature (node ids + types + edge ids) is unchanged,
 * so reusing positions is always geometrically correct here.
 */
export function layoutGraph(
  graph: GraphData,
  prevPositions?: PositionMap,
): { nodes: Node[]; edges: Edge[]; positions: PositionMap } {
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

  const canReuse = prevPositions !== undefined && allNodes.every((n) => prevPositions.has(n.id));
  const positions = canReuse ? (prevPositions as PositionMap) : layoutDagre(allNodes, allEdges);

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
    // A subtle arrowhead reinforces execution direction. Neutral fill (a CSS
    // var so it tracks the theme) keeps status legible on the stroke, not the
    // marker. Suppressed into the END terminal so arrows don't pile on it.
    markerEnd: e.target === END_NODE_ID ? undefined : ARROW_MARKER,
  }));

  return { nodes, edges, positions };
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
    // `tight-tree` produces visibly cleaner layouts for branch-and-merge
    // workflows than the default `network-simplex`: it keeps merging
    // siblings on a clearly-distinct sub-lane rather than dropping them
    // into a half-row dip below the main flow. n8n's editor uses a
    // similar layered approach.
    ranker: "tight-tree",
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
