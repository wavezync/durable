/**
 * Step node — n8n-inspired square icon-first card with the step name
 * rendered below the box. Sized to read as a node-of-equal-rhythm next
 * to the workflow's other primitives (gateways, fork/join markers,
 * boundary markers). Status drives the box border + corner dot; running
 * additionally pulses via the shared `led-dot` keyframe.
 *
 * Click → dispatches `durable:step-clicked` so the FlowGraph LC can
 * open its inspector sheet (or push_navigate when the node represents
 * a parallel-child workflow). Hover → tiny popover with timestamps and
 * attempt count.
 */

import { Handle, type NodeProps, Position } from "@xyflow/react";
import { Box } from "lucide-react";
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
}

function toneFor(status: string | undefined): Tone {
  switch (status) {
    case "running":
      return {
        border: "border-primary/60",
        dotBg: "bg-primary",
        pulsing: true,
        iconColor: "text-primary",
      };
    case "completed":
      return {
        border: "border-success/40",
        dotBg: "bg-success",
        pulsing: false,
        iconColor: "text-success",
      };
    case "failed":
      return {
        border: "border-destructive/60",
        dotBg: "bg-destructive",
        pulsing: false,
        iconColor: "text-destructive",
      };
    case "waiting":
      return {
        border: "border-warning/50",
        dotBg: "bg-warning",
        pulsing: true,
        iconColor: "text-warning",
      };
    default:
      return {
        border: "border-border",
        dotBg: "bg-muted-foreground/50",
        pulsing: false,
        iconColor: "text-muted-foreground",
      };
  }
}

function formatMs(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60_000)}m`;
}

function formatTime(iso: string | undefined): string | null {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function StepNodeComponent({ data }: NodeProps) {
  const node = data as unknown as StepNodeData;
  const tone = toneFor(node.status);

  const handleClick = useCallback(() => {
    window.dispatchEvent(
      new CustomEvent("durable:step-clicked", {
        detail: {
          stepName: node.name,
          stepExecutionId: node.step_execution_id ?? null,
          childWorkflowId: node.child_workflow_id ?? null,
        },
      }),
    );
  }, [node.name, node.step_execution_id, node.child_workflow_id]);

  const started = formatTime(node.started_at);
  const completed = formatTime(node.completed_at);
  const isCurrent = Boolean(node.is_current);
  const isDrillIn = Boolean(node.child_workflow_id);

  return (
    <div className="group relative flex w-[88px] flex-col items-center">
      <Handle
        type="target"
        position={Position.Left}
        className="!h-1.5 !w-1.5 !border-border !bg-muted-foreground/50"
      />

      <div
        className={[
          "relative flex size-16 cursor-pointer items-center justify-center",
          "rounded-md border bg-card shadow-sm transition-colors duration-150",
          "hover:border-foreground/30 hover:bg-accent/50",
          tone.border,
          isCurrent ? "ring-2 ring-primary/60 ring-offset-2 ring-offset-background" : "",
        ].join(" ")}
        onClick={handleClick}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            handleClick();
          }
        }}
        role="button"
        tabIndex={0}
        aria-label={node.label}
      >
        <Box className={["size-6", tone.iconColor].join(" ")} aria-hidden="true" />

        {/* Status dot — top-right corner of the icon box. */}
        <span
          className={[
            "pointer-events-none absolute top-1.5 right-1.5 size-1.5 rounded-full",
            tone.dotBg,
            tone.pulsing ? "led-dot" : "",
          ].join(" ")}
        />

        {/* Drill-in arrow for parallel-child workflows. */}
        {isDrillIn ? (
          <span className="pointer-events-none absolute -right-1 -top-1 inline-flex size-4 items-center justify-center rounded-full bg-primary/20 text-primary ring-1 ring-primary/50">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.6"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-2.5"
              aria-hidden="true"
            >
              <path d="m6 4 5 4-5 4" />
            </svg>
          </span>
        ) : null}
      </div>

      <Handle
        type="source"
        position={Position.Right}
        className="!h-1.5 !w-1.5 !border-border !bg-muted-foreground/50"
      />

      {/* Label + status meta — sits inside the dagre cell so adjacent
          rows don't collide. */}
      <div className="mt-1.5 flex w-full flex-col items-center text-center leading-tight">
        <span className="line-clamp-2 text-[11px] font-medium text-foreground">{node.label}</span>
        <span className="font-mono text-[9px] uppercase tracking-wider text-muted-foreground">
          {node.status || node.step_type || "—"}
          {node.duration_ms != null && node.status !== "running"
            ? ` · ${formatMs(node.duration_ms)}`
            : ""}
          {node.attempt != null && node.attempt > 1 ? ` · ×${node.attempt}` : ""}
        </span>
      </div>

      {/* Hover popover — pure CSS, no LV round-trip. */}
      <div
        className={[
          "pointer-events-none absolute left-1/2 top-full z-30 mt-1 -translate-x-1/2",
          "min-w-[220px] rounded-md border border-border bg-popover/95 p-2.5",
          "text-popover-foreground shadow-lg backdrop-blur-sm",
          "opacity-0 translate-y-1 transition-all duration-100",
          "group-hover:pointer-events-auto group-hover:opacity-100 group-hover:translate-y-0",
        ].join(" ")}
      >
        <div className="flex items-center gap-2 border-b border-border/50 pb-1.5 mb-1.5">
          <span className={["size-1.5 rounded-full", tone.dotBg].join(" ")} />
          <span className="font-mono text-[10px] uppercase tracking-wider">
            {node.status || node.step_type || "—"}
          </span>
          {node.attempt != null && node.attempt > 1 ? (
            <span className="ml-auto font-mono text-[10px] text-muted-foreground">
              attempt ×{node.attempt}
            </span>
          ) : null}
        </div>
        <dl className="grid grid-cols-[68px_1fr] gap-x-2 gap-y-0.5 text-[11px]">
          <PopoverRow label="Step" value={node.label} mono />
          {node.duration_ms != null ? (
            <PopoverRow label="Duration" value={formatMs(node.duration_ms)} mono />
          ) : null}
          {started ? <PopoverRow label="Started" value={started} /> : null}
          {completed ? <PopoverRow label="Completed" value={completed} /> : null}
        </dl>
        <div className="mt-2 border-t border-border/50 pt-1.5 text-[9px] uppercase tracking-widest text-muted-foreground">
          {isDrillIn ? "click to open child workflow" : "click for full details"}
        </div>
      </div>
    </div>
  );
}

function PopoverRow({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <>
      <dt className="text-muted-foreground">{label}</dt>
      <dd className={mono ? "truncate font-mono text-foreground" : "truncate text-foreground"}>
        {value}
      </dd>
    </>
  );
}

export const StepNode = memo(StepNodeComponent);
