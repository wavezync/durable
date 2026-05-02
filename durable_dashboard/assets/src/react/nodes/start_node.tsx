/**
 * Start marker — n8n-style 64×64 boundary node anchoring the left edge
 * of a workflow graph.
 */

import { Handle, Position } from "@xyflow/react";
import { Play } from "lucide-react";
import { memo } from "react";

function StartNodeComponent() {
  return (
    <div className="relative flex w-[88px] flex-col items-center">
      <div className="relative flex size-16 items-center justify-center rounded-md border border-success/40 bg-success/5 shadow-sm">
        <Play className="size-5 fill-success text-success" aria-hidden="true" />
      </div>

      <Handle
        type="source"
        position={Position.Right}
        className="!h-1.5 !w-1.5 !border-success/40 !bg-success/60"
      />

      <div className="mt-1.5 flex w-full flex-col items-center text-center leading-tight">
        <span className="font-mono text-[9px] uppercase tracking-widest text-success">start</span>
      </div>
    </div>
  );
}

export const StartNode = memo(StartNodeComponent);
