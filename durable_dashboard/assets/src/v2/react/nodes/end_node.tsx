/**
 * End marker — paired with `StartNode`. Anchors the right edge of the
 * workflow graph.
 */

import { Handle, Position } from "@xyflow/react";
import { Flag } from "lucide-react";
import { memo } from "react";

function EndNodeComponent() {
  return (
    <div className="relative flex w-[88px] flex-col items-center">
      <Handle
        type="target"
        position={Position.Left}
        className="!h-1.5 !w-1.5 !border-muted-foreground/40 !bg-muted-foreground/60"
      />

      <div className="relative flex size-16 items-center justify-center rounded-md border border-border bg-card shadow-sm">
        <Flag className="size-5 text-muted-foreground" aria-hidden="true" />
      </div>

      <div className="mt-1.5 flex w-full flex-col items-center text-center leading-tight">
        <span className="font-mono text-[9px] uppercase tracking-widest text-muted-foreground">
          end
        </span>
      </div>
    </div>
  );
}

export const EndNode = memo(EndNodeComponent);
