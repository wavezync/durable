import type { NodeProps } from "@xyflow/react";
import { Handle, Position } from "@xyflow/react";
import { memo } from "react";

function JoinNodeComponent(_props: NodeProps) {
  return (
    <div className="relative flex h-[32px] w-[32px] items-center justify-center">
      <Handle
        type="target"
        position={Position.Top}
        className="!z-10 !h-1.5 !w-1.5 !border-[var(--primary)]/40 !bg-[var(--primary)]/70"
      />
      <div className="h-[28px] w-[28px] rounded-full border border-[var(--primary)]/50 bg-[oklch(0.17_0.01_65)]" />
      <span className="pointer-events-none absolute inset-0 flex items-center justify-center">
        <span className="h-[7px] w-[7px] rounded-full bg-[var(--primary)]/70" />
      </span>
      <Handle
        type="source"
        position={Position.Bottom}
        className="!z-10 !h-1.5 !w-1.5 !border-[var(--primary)]/40 !bg-[var(--primary)]/70"
      />
    </div>
  );
}

export const JoinNode = memo(JoinNodeComponent);
