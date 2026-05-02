import type { NodeProps } from "@xyflow/react";
import { Handle, Position } from "@xyflow/react";
import { memo } from "react";

interface ParallelNodeData {
  label: string;
  step_type: string;
  name: string;
  status?: string;
  attempt?: number;
  duration_ms?: number;
  clause?: string;
  parallel?: boolean;
}

function ParallelNodeComponent({ data }: NodeProps) {
  const nodeData = data as unknown as ParallelNodeData;
  const isJoin =
    nodeData.step_type === "parallel_join" || nodeData.label.toLowerCase().includes("join");

  return (
    <div className="relative flex h-[32px] w-[140px] items-center justify-center">
      <Handle
        type="target"
        position={Position.Top}
        className="!z-10 !h-1.5 !w-1.5 !border-[var(--primary)]/40 !bg-[var(--primary)]/70"
      />
      <div className="relative flex h-full w-full items-center justify-center border-y-2 border-[var(--primary)]/60 bg-[oklch(0.17_0.01_65)]">
        <span className="pointer-events-none absolute left-2 top-1/2 h-[7px] w-[7px] -translate-y-1/2 rounded-full bg-[var(--primary)]/30" />
        <span className="pointer-events-none absolute right-2 top-1/2 h-[7px] w-[7px] -translate-y-1/2 rounded-full bg-[var(--primary)]/30" />
        <span className="font-mono text-[9px] uppercase tracking-[0.22em] text-[var(--primary)]/90">
          {isJoin ? "Join" : "Fork"}
        </span>
      </div>
      <Handle
        type="source"
        position={Position.Bottom}
        className="!z-10 !h-1.5 !w-1.5 !border-[var(--primary)]/40 !bg-[var(--primary)]/70"
      />
    </div>
  );
}

export const ParallelNode = memo(ParallelNodeComponent);
