/**
 * Start marker — a small terminal pill (not a full card) so the workflow's
 * boundary reads as a terminal, not a step.
 */

import { Handle, Position } from "@xyflow/react";
import { Play } from "lucide-react";
import { memo } from "react";

function StartNodeComponent() {
  return (
    <div className="relative">
      <div className="flex h-7 items-center gap-1 rounded-full border border-success/40 bg-success/10 pr-2 pl-1.5">
        <Play className="size-2.5 fill-success text-success" aria-hidden="true" />
        <span className="font-mono text-[9px] uppercase tracking-widest text-success">start</span>
      </div>

      <Handle
        type="source"
        position={Position.Right}
        className="!h-1 !w-1 !min-w-0 !border-0 !bg-success/60"
      />
    </div>
  );
}

export const StartNode = memo(StartNodeComponent);
