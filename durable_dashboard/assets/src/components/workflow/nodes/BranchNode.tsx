import type { NodeProps } from "@xyflow/react";
import { Handle, Position } from "@xyflow/react";
import { memo } from "react";

interface BranchNodeData {
  label: string;
  step_type: string;
  name: string;
  status?: string;
  attempt?: number;
  duration_ms?: number;
  clause?: string;
  parallel?: boolean;
}

function BranchNodeComponent({ data }: NodeProps) {
  const nodeData = data as unknown as BranchNodeData;
  const isJoin =
    nodeData.step_type === "branch_join" || nodeData.label.toLowerCase().includes("join");

  return (
    <div className="relative flex h-[60px] w-[60px] items-center justify-center">
      <Handle
        type="target"
        position={Position.Top}
        className="!z-10 !h-1.5 !w-1.5 !border-[var(--primary)]/40 !bg-[var(--primary)]/70"
      />
      <div className="h-[44px] w-[44px] rotate-45 border border-[var(--primary)]/50 bg-[oklch(0.17_0.01_65)] transition-colors hover:border-[var(--primary)]/80 hover:bg-[oklch(0.2_0.012_65)]" />
      <span className="pointer-events-none absolute inset-0 flex items-center justify-center font-mono text-[9px] uppercase tracking-[0.14em] text-[var(--primary)]/80">
        {isJoin ? "∧" : "∨"}
      </span>
      <Handle
        type="source"
        position={Position.Bottom}
        className="!z-10 !h-1.5 !w-1.5 !border-[var(--primary)]/40 !bg-[var(--primary)]/70"
      />
    </div>
  );
}

export const BranchNode = memo(BranchNodeComponent);
