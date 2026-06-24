/**
 * End marker — paired with `StartNode`. A small terminal pill anchoring the
 * right edge of the workflow graph.
 */

import { Handle, Position } from "@xyflow/react";
import { Flag } from "lucide-react";
import { memo } from "react";

function EndNodeComponent() {
  return (
    <div className="relative">
      <Handle
        type="target"
        position={Position.Left}
        className="!h-1 !w-1 !min-w-0 !border-0 !bg-muted-foreground/50"
      />

      <div className="flex h-7 items-center gap-1 rounded-full border border-border bg-muted/60 pr-2 pl-1.5">
        <Flag className="size-2.5 text-muted-foreground" aria-hidden="true" />
        <span className="font-mono text-[9px] uppercase tracking-widest text-muted-foreground">
          end
        </span>
      </div>
    </div>
  );
}

export const EndNode = memo(EndNodeComponent);
