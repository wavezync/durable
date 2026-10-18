// Types shared between the React FlowGraph island and its TS hooks.
//
// The dashboard is LiveView-first; only the workflow-graph view crosses
// into React, so the typed surface is intentionally narrow — anything
// extra would imply the React side is taking on responsibilities the
// LiveView already owns.

export type StepStatus = "pending" | "running" | "completed" | "failed" | "waiting" | "cancelled";

// Types the server (`graph_builder.ex`) emits. `start`/`end` are synthesized
// client-side in `graph-layout.ts`; `child_workflow` is a step that ran as
// its own run; `join` closes a parallel block and `branch` is a branch's
// gateway. The `*_fork`/`*_join` markers are a stale-BEAM fallback (mapped to
// HiddenNode).
export type NodeType =
  | "step"
  | "decision"
  | "child_workflow"
  | "join"
  | "branch"
  | "start"
  | "end"
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
    /** Set by `graph_builder.overlay_status/3` once a runtime step
     * execution has been matched to this graph node. */
    started_at?: string;
    completed_at?: string;
    step_execution_id?: string;
    workflow_execution_id?: string;
    /** Truncated 1-line JSON previews of step input/output, suitable for
     * rendering in an n8n-style card. The full payload is fetched on
     * demand when the user opens the side drawer — keeping the graph
     * over-the-wire payload lean. */
    input_preview?: string;
    output_preview?: string;
    has_error?: boolean;
    /** "Type: message" of the step's error, for its tooltip. */
    error?: string;
    /** The step's retry budget from its definition. */
    max_attempts?: number;
    /** The step open in the run page's inspector. */
    selected?: boolean;
    /** Set in a finished run on steps that never executed. */
    not_run?: boolean;
    /** `join`: the parallel children it waits for, and how many are done. */
    members?: string[];
    done?: number;
    /** `branch`: each clause and its first step; `taken` once one ran. */
    paths?: { clause: string; first: string | null }[];
    taken?: string | null;
    /** Set when this step represents a parallel child running in its own
     * `WorkflowExecution`. The card surfaces an expand/drill-in
     * affordance and the LV translates the click into a navigate. */
    child_workflow_id?: string;
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
