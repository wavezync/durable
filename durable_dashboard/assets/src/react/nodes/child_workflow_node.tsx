/**
 * Child workflow node — a step that spawned its own `WorkflowExecution`
 * (a `call_workflow` / `start_workflow` sub-workflow, or a parallel branch
 * that materialises as its own run).
 *
 * It shares the exact silhouette of `StepNode` (the same 200×56 card) so it
 * sits in the row rhythm with its siblings — the ONE difference is a
 * stacked-sheet behind the card, signalling "a whole workflow lives inside
 * here, open it". That stacked motif (plus the fork icon and the drill-in
 * chevron) is the only thing that marks it as a drill-in; status color stays
 * as scarce as on a regular step.
 *
 * Clicking dispatches the same `durable:step-clicked` event as `StepNode`;
 * the FlowGraph LC routes it (parallel child → navigate to the child's flow
 * page; in-process sub-workflow → open the inspector with the Child tab).
 *
 * Layout: 200×56, identical to the step cell. `graph-layout.ts` sizes it the
 * same; the stacked sheet peeks a few px beyond the box but never enough to
 * collide given NODESEP/RANKSEP.
 */

import { Handle, type NodeProps, Position } from "@xyflow/react";
import { ChevronRight, GitFork } from "lucide-react";
import { memo, useCallback } from "react";

interface ChildWorkflowNodeData {
  label: string;
  step_type: string;
  name: string;
  status?: string;
  attempt?: number;
  duration_ms?: number;
  child_workflow_id?: string;
  is_current?: boolean;
  step_execution_id?: string;
}

interface Tone {
  border: string;
  dotBg: string;
  pulsing: boolean;
  iconColor: string;
  iconBg: string;
}

function toneFor(status: string | undefined): Tone {
  switch (status) {
    case "running":
      return {
        border: "border-primary/60",
        dotBg: "bg-primary",
        pulsing: true,
        iconColor: "text-primary",
        iconBg: "bg-primary/10",
      };
    case "completed":
      return {
        border: "border-success/40",
        dotBg: "bg-success",
        pulsing: false,
        iconColor: "text-success",
        iconBg: "bg-success/10",
      };
    case "failed":
      return {
        border: "border-destructive/60",
        dotBg: "bg-destructive",
        pulsing: false,
        iconColor: "text-destructive",
        iconBg: "bg-destructive/10",
      };
    case "waiting":
      return {
        border: "border-warning/50",
        dotBg: "bg-warning",
        pulsing: true,
        iconColor: "text-warning",
        iconBg: "bg-warning/10",
      };
    default:
      return {
        border: "border-border",
        dotBg: "bg-muted-foreground/50",
        pulsing: false,
        iconColor: "text-muted-foreground",
        iconBg: "bg-muted/60",
      };
  }
}

function formatMs(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60_000)}m`;
}

// Near-invisible read-only handles — the graph isn't user-editable; the ports
// just anchor edges to the card's left/right faces. Matches StepNode.
const HANDLE_CLASS = "!h-1 !w-1 !min-w-0 !border-0 !bg-muted-foreground/40";

// "sub-workflow" is the meta-line lede so the card reads as a container, with
// status + duration trailing — same grammar as StepNode's meta line.
function metaLine(node: ChildWorkflowNodeData): string {
  return [
    "sub-workflow",
    node.status || null,
    node.duration_ms != null && node.status !== "running" ? formatMs(node.duration_ms) : null,
    node.attempt != null && node.attempt > 1 ? `×${node.attempt}` : null,
  ]
    .filter(Boolean)
    .join(" · ");
}

function ChildWorkflowNodeComponent({ data }: NodeProps) {
  const node = data as unknown as ChildWorkflowNodeData;
  const tone = toneFor(node.status);
  const isCurrent = Boolean(node.is_current);

  const handleClick = useCallback(
    (e: React.SyntheticEvent) => {
      e.stopPropagation();
      const target = e.currentTarget as HTMLElement | null;
      const evt = new CustomEvent("durable:step-clicked", {
        bubbles: true,
        composed: true,
        detail: {
          stepName: node.name,
          stepExecutionId: node.step_execution_id ?? null,
          childWorkflowId: node.child_workflow_id ?? null,
        },
      });
      (target ?? document).dispatchEvent(evt);
    },
    [node.name, node.step_execution_id, node.child_workflow_id],
  );

  const tooltip = [
    `Open ${node.label}`,
    node.status ? node.status.toUpperCase() : null,
    node.duration_ms != null ? formatMs(node.duration_ms) : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <div className="group relative">
      <Handle type="target" position={Position.Left} className={HANDLE_CLASS} />

      {/* Stacked sheet — the signature. A second card peeking behind the top
          edge says "a whole workflow is nested in here". Kept neutral so the
          status color stays carried by the front card alone. */}
      <div
        aria-hidden="true"
        className="absolute -top-1.5 left-1.5 h-14 w-[200px] rounded-lg border border-border/55 bg-card/70 shadow-sm transition-transform duration-150 group-hover:-translate-y-0.5"
      />

      <div
        className={[
          "nopan relative flex h-14 w-[200px] cursor-pointer items-center gap-2.5 rounded-lg border bg-card px-2.5 shadow-sm",
          "transition-colors duration-150 hover:border-foreground/30",
          tone.border,
          isCurrent ? "ring-2 ring-primary/60 ring-offset-2 ring-offset-background" : "",
        ].join(" ")}
        onClick={handleClick}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            handleClick(e);
          }
        }}
        role="button"
        tabIndex={0}
        aria-label={`Open child workflow ${node.label}`}
        title={tooltip}
      >
        <div
          className={[
            "flex size-7 shrink-0 items-center justify-center rounded-md",
            tone.iconBg,
          ].join(" ")}
        >
          <GitFork className={["size-4", tone.iconColor].join(" ")} aria-hidden="true" />
        </div>

        <div className="flex min-w-0 flex-1 flex-col">
          <span className="truncate text-[13px] font-medium leading-tight text-foreground">
            {node.label}
          </span>
          <span className="truncate font-mono text-[10px] uppercase tracking-wide text-muted-foreground">
            {metaLine(node)}
          </span>
        </div>

        {/* Drill-in chevron — the click target opens the nested run. */}
        <ChevronRight className="size-3.5 shrink-0 text-primary/70" aria-hidden="true" />

        <span
          className={[
            "size-1.5 shrink-0 self-start rounded-full",
            tone.dotBg,
            tone.pulsing ? "led-dot" : "",
          ].join(" ")}
        />
      </div>

      <Handle type="source" position={Position.Right} className={HANDLE_CLASS} />
    </div>
  );
}

export const ChildWorkflowNode = memo(ChildWorkflowNodeComponent);
