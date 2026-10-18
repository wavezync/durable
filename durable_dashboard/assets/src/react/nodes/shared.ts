/**
 * What the graph's cards share: status tone, the status line, and the
 * tooltip (the dashboard's `data-tip` attributes — see `tooltip.ts`).
 */

import type { GraphNode } from "../../lib/types";

export type NodeData = GraphNode["data"];

export interface Tone {
  border: string;
  iconColor: string;
  iconBg: string;
}

export function toneFor(status: string | undefined): Tone {
  switch (status) {
    case "running":
      return { border: "border-primary/60", iconColor: "text-primary", iconBg: "bg-primary/10" };
    case "completed":
      return { border: "border-success/40", iconColor: "text-success", iconBg: "bg-success/10" };
    case "failed":
      return {
        border: "border-destructive/60",
        iconColor: "text-destructive",
        iconBg: "bg-destructive/10",
      };
    case "waiting":
      return { border: "border-warning/50", iconColor: "text-warning", iconBg: "bg-warning/10" };
    default:
      return { border: "border-border", iconColor: "text-muted-foreground", iconBg: "bg-muted/60" };
  }
}

export function formatMs(ms: number): string {
  if (ms < 1000) return `${ms} ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)} s`;
  const m = Math.floor(ms / 60_000);
  const s = Math.round((ms % 60_000) / 1000);
  return s ? `${m}m ${s}s` : `${m}m`;
}

const WORDS: Record<string, string> = {
  pending: "Pending",
  running: "Running",
  waiting: "Waiting",
  completed: "Completed",
  failed: "Failed",
  cancelled: "Cancelled",
};

/** The status-dot class for the dashboard's shared `st-dot` marks. */
export function dotClass(node: NodeData): string {
  return node.not_run ? "st-dot st-pending" : `st-dot st-${node.status ?? "pending"}`;
}

/** "Completed · 147 ms · 2 attempts" — or "Not run" in a finished run. */
export function statusLine(node: NodeData): string {
  if (node.not_run) return "Not run";
  const status = node.status ?? "pending";
  return [
    WORDS[status] ?? status,
    node.duration_ms != null && status !== "running" ? formatMs(node.duration_ms) : null,
    node.attempt != null && node.attempt > 1 ? `${node.attempt} attempts` : null,
  ]
    .filter(Boolean)
    .join(" · ");
}

function clock(iso: string | undefined): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  return Number.isNaN(d.getTime())
    ? null
    : d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function outcome(node: NodeData): string {
  if (node.not_run) return "Didn't run in this run";
  const took = node.duration_ms != null ? ` in ${formatMs(node.duration_ms)}` : "";
  switch (node.status) {
    case "completed":
      return `Completed${took}`;
    case "failed":
      return node.max_attempts && node.max_attempts > 1
        ? `Failed after ${node.attempt} of ${node.max_attempts} attempts`
        : "Failed · no retries set";
    case "running":
      return "Running now";
    case "waiting":
      return "Waiting · resumes on its event, input or timer";
    default:
      return "Hasn't run yet";
  }
}

/** Tooltip attributes for a step card. */
export function stepTip(node: NodeData, opensChild: boolean): Record<string, string | undefined> {
  const started = clock(node.started_at);
  const lines = [
    outcome(node),
    node.status === "running" && node.attempt && node.max_attempts && node.max_attempts > 1
      ? `Attempt ${node.attempt} of ${node.max_attempts}`
      : null,
    started ? `Started ${started}` : null,
    node.parallel ? "Runs alongside the other steps in its parallel block" : null,
    node.clause ? `On the “${node.clause}” path of a branch` : null,
    // A parallel child's execution belongs to the child run; a step that
    // called a workflow ran here and started one.
    opensChild
      ? node.workflow_execution_id === node.child_workflow_id
        ? "Ran as its own child run"
        : "Started a child run"
      : null,
    node.step_execution_id ? "Click to inspect its input, output, logs and attempts" : null,
  ].filter(Boolean);

  return {
    "data-tip-title": node.label,
    "data-tip": lines.join("\n"),
    "data-tip-meta": node.error ?? (node.name !== node.label ? node.name : undefined),
  };
}
