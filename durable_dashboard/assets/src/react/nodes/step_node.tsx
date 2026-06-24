/**
 * Step node — a horizontal status card (200×56) in the spirit of Argo /
 * Dagster / GitHub Actions run graphs: a status-tinted icon tile, the step
 * name, a mono meta line, and a trailing status dot. Calm + neutral by
 * default so saturated status color stays scarce and legible; the running
 * dot pulses via the shared `led-dot` keyframe.
 *
 * Click → dispatches `durable:step-clicked` so the FlowGraph LC opens its
 * inspector sheet (or navigates when the node is a parallel-child workflow).
 */

import { Handle, type NodeProps, Position } from "@xyflow/react";
import { Box, ChevronRight } from "lucide-react";
import { memo, useCallback } from "react";

interface StepNodeData {
  label: string;
  step_type: string;
  name: string;
  status?: string;
  attempt?: number;
  duration_ms?: number;
  started_at?: string;
  completed_at?: string;
  step_execution_id?: string;
  is_current?: boolean;
  child_workflow_id?: string;
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

// Near-invisible read-only handles — the graph isn't user-editable, so the
// ports just anchor the edges to the card's left/right faces.
const HANDLE_CLASS = "!h-1 !w-1 !min-w-0 !border-0 !bg-muted-foreground/40";

function metaLine(node: StepNodeData): string {
  return [
    node.status || node.step_type,
    node.duration_ms != null && node.status !== "running" ? formatMs(node.duration_ms) : null,
    node.attempt != null && node.attempt > 1 ? `×${node.attempt}` : null,
  ]
    .filter(Boolean)
    .join(" · ");
}

function StepNodeComponent({ data }: NodeProps) {
  const node = data as unknown as StepNodeData;
  const tone = toneFor(node.status);

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

  const isCurrent = Boolean(node.is_current);
  const isDrillIn = Boolean(node.child_workflow_id);

  const tooltip = [
    node.label,
    node.status ? node.status.toUpperCase() : null,
    node.duration_ms != null ? formatMs(node.duration_ms) : null,
    node.attempt != null && node.attempt > 1 ? `attempt ×${node.attempt}` : null,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <div className="group relative">
      <Handle type="target" position={Position.Left} className={HANDLE_CLASS} />

      <div
        className={[
          "nopan flex h-14 w-[200px] cursor-pointer items-center gap-2.5 rounded-lg border bg-card px-2.5 shadow-sm",
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
        aria-label={node.label}
        title={tooltip}
      >
        <div
          className={[
            "flex size-7 shrink-0 items-center justify-center rounded-md",
            tone.iconBg,
          ].join(" ")}
        >
          <Box className={["size-4", tone.iconColor].join(" ")} aria-hidden="true" />
        </div>

        <div className="flex min-w-0 flex-1 flex-col">
          <span className="truncate text-[13px] font-medium leading-tight text-foreground">
            {node.label}
          </span>
          <span className="truncate font-mono text-[10px] uppercase tracking-wide text-muted-foreground">
            {metaLine(node)}
          </span>
        </div>

        {isDrillIn ? (
          <ChevronRight className="size-3.5 shrink-0 text-primary/70" aria-hidden="true" />
        ) : null}

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

export const StepNode = memo(StepNodeComponent);
