import type { NodeProps } from "@xyflow/react";
import { Handle, Position } from "@xyflow/react";
import { memo } from "react";

interface StepNodeData {
  label: string;
  step_type: string;
  name: string;
  status?: string;
  attempt?: number;
  duration_ms?: number;
  clause?: string;
  parallel?: boolean;
}

type Tone = {
  border: string;
  dot: string;
  glow: string;
  dashed?: boolean;
};

function toneFor(status: string | undefined): Tone {
  switch (status) {
    case "running":
      return {
        border: "border-[var(--primary)]/70",
        dot: "bg-[var(--primary)] text-[var(--primary)]",
        glow: "shadow-[0_0_28px_-8px_oklch(0.82_0.17_82/0.8)]",
      };
    case "completed":
      return {
        border: "border-[oklch(0.82_0.17_150)]/60",
        dot: "bg-[oklch(0.82_0.17_150)]",
        glow: "",
      };
    case "failed":
      return {
        border: "border-[oklch(0.68_0.2_22)]/70",
        dot: "bg-[oklch(0.82_0.18_22)] text-[oklch(0.82_0.18_22)]",
        glow: "shadow-[0_0_24px_-10px_oklch(0.68_0.2_22/0.7)]",
      };
    case "waiting":
      return {
        border: "border-[oklch(0.78_0.13_210)]/60",
        dot: "bg-[oklch(0.78_0.13_210)] text-[oklch(0.78_0.13_210)]",
        glow: "",
      };
    default:
      return {
        border: "border-border/70",
        dot: "bg-muted-foreground/50",
        glow: "",
        dashed: true,
      };
  }
}

function StepNodeComponent({ data }: NodeProps) {
  const nodeData = data as unknown as StepNodeData;
  const tone = toneFor(nodeData.status);
  const isRunning = nodeData.status === "running";
  const isPulsing = isRunning || nodeData.status === "waiting";

  return (
    <div
      className={`group relative flex h-[52px] w-[188px] cursor-pointer items-center gap-2.5 border bg-[oklch(0.16_0.01_65)] px-3 transition-all duration-200 hover:-translate-y-px hover:bg-[oklch(0.19_0.012_65)] ${tone.border} ${tone.glow} ${tone.dashed ? "border-dashed" : ""} ${isRunning ? "node-running" : ""}`}
    >
      <Handle
        type="target"
        position={Position.Top}
        className="!h-1.5 !w-1.5 !border-[var(--primary)]/40 !bg-[var(--primary)]/70"
      />

      <span
        className={`shrink-0 rounded-full ${tone.dot} ${isPulsing ? "led-dot" : ""}`}
        style={{ width: 6, height: 6 }}
      />

      <div className="flex min-w-0 flex-1 flex-col">
        <span className="truncate text-[12px] font-medium text-foreground/95 leading-tight">
          {nodeData.label}
        </span>
        {nodeData.status && (
          <span className="truncate font-mono text-[8px] uppercase tracking-[0.16em] text-muted-foreground">
            {nodeData.status}
            {nodeData.duration_ms != null && nodeData.status !== "running"
              ? ` · ${formatMs(nodeData.duration_ms)}`
              : ""}
          </span>
        )}
      </div>

      <Handle
        type="source"
        position={Position.Bottom}
        className="!h-1.5 !w-1.5 !border-[var(--primary)]/40 !bg-[var(--primary)]/70"
      />
    </div>
  );
}

function formatMs(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60000)}m`;
}

export const StepNode = memo(StepNodeComponent);
