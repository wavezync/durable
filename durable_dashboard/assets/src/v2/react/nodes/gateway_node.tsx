/**
 * Gateway node — used for `decision` and `branch_fork` step types. Same
 * 64×64 icon-first square as StepNode, but with the GitBranch glyph and
 * three right-side handles so the dagre layout can fan branch arms out
 * cleanly without overlapping connectors.
 *
 * Edge labels (clause names) are rendered by `AnimatedFlowEdge`.
 */

import { Handle, type NodeProps, Position } from "@xyflow/react";
import { GitBranch } from "lucide-react";
import { memo } from "react";

interface GatewayNodeData {
  label: string;
  step_type: string;
  name: string;
  status?: string;
}

interface Tone {
  border: string;
  dotBg: string;
  iconColor: string;
}

function toneFor(status: string | undefined): Tone {
  switch (status) {
    case "running":
      return { border: "border-primary/60", dotBg: "bg-primary", iconColor: "text-primary" };
    case "completed":
      return { border: "border-success/40", dotBg: "bg-success", iconColor: "text-success" };
    case "failed":
      return {
        border: "border-destructive/60",
        dotBg: "bg-destructive",
        iconColor: "text-destructive",
      };
    default:
      return {
        border: "border-border",
        dotBg: "bg-muted-foreground/50",
        iconColor: "text-muted-foreground",
      };
  }
}

function GatewayNodeComponent({ data, type }: NodeProps) {
  const node = data as unknown as GatewayNodeData;
  const tone = toneFor(node.status);
  const eyebrow = type === "branch_fork" ? "branch" : "decide";

  return (
    <div className="relative flex w-[88px] flex-col items-center">
      <Handle
        type="target"
        position={Position.Left}
        className="!h-1.5 !w-1.5 !border-border !bg-muted-foreground/50"
      />

      <div
        className={[
          "relative flex size-16 items-center justify-center",
          "rounded-md border bg-card shadow-sm",
          tone.border,
        ].join(" ")}
      >
        <GitBranch className={["size-6", tone.iconColor].join(" ")} aria-hidden="true" />
        <span
          className={[
            "pointer-events-none absolute top-1.5 right-1.5 size-1.5 rounded-full",
            tone.dotBg,
          ].join(" ")}
        />
      </div>

      {/* Three source handles → distinct y offsets so dagre routes 1–3
          branches without connectors stacking. */}
      <Handle
        id="top"
        type="source"
        position={Position.Right}
        style={{ top: "30%" }}
        className="!h-1.5 !w-1.5 !border-border !bg-muted-foreground/50"
      />
      <Handle
        id="middle"
        type="source"
        position={Position.Right}
        style={{ top: "50%" }}
        className="!h-1.5 !w-1.5 !border-border !bg-muted-foreground/50"
      />
      <Handle
        id="bottom"
        type="source"
        position={Position.Right}
        style={{ top: "70%" }}
        className="!h-1.5 !w-1.5 !border-border !bg-muted-foreground/50"
      />

      <div className="mt-1.5 flex w-full flex-col items-center text-center leading-tight">
        <span className="font-mono text-[9px] uppercase tracking-widest text-muted-foreground">
          {eyebrow}
        </span>
        <span className="line-clamp-2 text-[11px] font-medium text-foreground">{node.label}</span>
      </div>
    </div>
  );
}

export const GatewayNode = memo(GatewayNodeComponent);
