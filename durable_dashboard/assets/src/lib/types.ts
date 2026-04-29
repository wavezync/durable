// ============================================================================
// Data Types (mirror Elixir schemas)
// ============================================================================

export type WorkflowStatus =
  | "pending"
  | "running"
  | "completed"
  | "failed"
  | "waiting"
  | "cancelled"
  | "compensating"
  | "compensated"
  | "compensation_failed";

export type StepStatus = "pending" | "running" | "completed" | "failed" | "waiting";

export type InputType = "approval" | "single_choice" | "multi_choice" | "free_text" | "form";

export interface Workflow {
  id: string;
  workflow_module: string;
  workflow_name: string;
  status: WorkflowStatus;
  queue: string;
  priority: number;
  input: Record<string, unknown>;
  context: Record<string, unknown>;
  current_step: string | null;
  error: Record<string, unknown> | null;
  scheduled_at: string | null;
  started_at: string | null;
  completed_at: string | null;
  inserted_at: string;
  updated_at: string;
}

export interface StepExecution {
  id: string;
  step_name: string;
  step_type: string;
  attempt: number;
  status: StepStatus;
  input: Record<string, unknown> | null;
  output: Record<string, unknown> | null;
  error: Record<string, unknown> | null;
  logs: LogEntry[];
  duration_ms: number | null;
  started_at: string | null;
  completed_at: string | null;
}

export interface LogEntry {
  level: string;
  message: string;
  timestamp?: string;
  metadata?: Record<string, unknown>;
}

/**
 * LogEntry decorated with the step it belongs to — used by the aggregated
 * workflow-level logs view where lines from many steps are interleaved.
 * `key` is a stable string identity so React can keep DOM nodes alive across
 * PubSub-driven refreshes without breaking the LogViewer's autoscroll.
 */
export interface DisplayLogEntry extends LogEntry {
  step?: string;
  attempt?: number;
  key?: string;
}

export interface PendingInput {
  id: string;
  workflow_id: string;
  input_name: string;
  step_name: string;
  input_type: InputType;
  prompt: string | null;
  metadata: Record<string, unknown> | null;
  fields: Field[] | null;
  status: string;
  timeout_at: string | null;
  inserted_at: string;
  workflow?: {
    id: string;
    workflow_name: string;
    workflow_module: string;
    status: string;
  };
}

export interface Field {
  name: string;
  type: string;
  label?: string;
  value?: string;
  required?: boolean;
  options?: string[];
}

export interface Schedule {
  id: string;
  name: string;
  workflow_module: string;
  workflow_name: string;
  cron_expression: string;
  timezone: string;
  input: Record<string, unknown>;
  queue: string;
  enabled: boolean;
  last_run_at: string | null;
  next_run_at: string | null;
  inserted_at: string;
  updated_at: string;
}

// ============================================================================
// Graph Types (ReactFlow)
// ============================================================================

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

// ============================================================================
// API Types
// ============================================================================

export interface StatusCounts {
  [status: string]: number;
}

export interface WorkflowListResponse {
  workflows: Workflow[];
  total: number;
  counts: StatusCounts;
  page: number;
  per_page: number;
}

export interface WorkflowDetailResponse {
  workflow: Workflow;
  steps: StepExecution[];
  pending_inputs: PendingInput[];
  graph: GraphData;
  error?: string;
}

export interface OverviewResponse {
  counts: StatusCounts;
  recent: Workflow[];
}

export interface ScheduleListResponse {
  schedules: Schedule[];
  total: number;
}

export interface PendingInputListResponse {
  inputs: PendingInput[];
  total: number;
  page: number;
}

export interface MetricsResponse {
  throughput: { time: string; count: number }[];
  breakdown: Record<string, number>;
  percentiles: { p50: number; p95: number; p99: number };
  queues: Record<string, number>;
  top_failing: { name: string; count: number }[];
}

// ============================================================================
// Component Props
// ============================================================================

export type ViewName =
  | "overview"
  | "workflows"
  | "workflow_detail"
  | "schedules"
  | "inputs"
  | "settings";

export type NavigateFn = (view: ViewName, params?: Record<string, string>) => void;

export type Unsubscribe = () => void;

export interface LiveViewBridge {
  /**
   * Send an event to the LiveView process. Resolves with the reply payload
   * when the server responds via `{:reply, ...}`. Rejects with an `Error`
   * after a 10 s timeout or if the socket disconnects before the reply.
   */
  pushEvent: (event: string, payload: unknown) => Promise<unknown>;

  /**
   * Register a listener for server-pushed events. Returns an unsubscribe
   * function; always call it in a `useEffect` cleanup to avoid leaks when
   * components unmount between navigations.
   */
  subscribe: (event: string, callback: (payload: unknown) => void) => Unsubscribe;
}
