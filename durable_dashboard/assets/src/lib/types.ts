// Types shared between the React FlowGraph island and its TS hooks.
//
// The dashboard is LiveView-first; only the workflow-graph view crosses
// into React, so the typed surface is intentionally narrow — anything
// extra would imply the React side is taking on responsibilities the
// LiveView already owns.

export type StepStatus = "pending" | "running" | "completed" | "failed" | "waiting";

export type NodeType =
  | "step"
  | "decision"
  | "branch_fork"
  | "branch_join"
  | "parallel_fork"
  | "parallel_join";

export interface GraphNode {
  id: string;
  type: NodeType;
  data: {
    label: string;
    step_type: string;
    name: string;
    status?: StepStatus | "pending";
    attempt?: number;
    duration_ms?: number;
    clause?: string;
    parallel?: boolean;
  };
}

export interface GraphEdge {
  id: string;
  source: string;
  target: string;
  animated: boolean;
  style: Record<string, string>;
  label?: string;
  /** Class applied by `graph_builder.overlay_status/3` — one of
   * `flow-edge-{completed,running,pending}` once the workflow has been
   * inspected. The CSS for these lives in `index.css`. See DESIGN.md §11. */
  className?: string;
}

export interface GraphData {
  nodes: GraphNode[];
  edges: GraphEdge[];
}
