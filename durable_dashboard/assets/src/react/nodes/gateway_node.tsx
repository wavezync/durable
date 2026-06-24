/**
 * Gateway node — `decision` / `branch_fork` step types. Same 200×56 horizontal
 * card as StepNode, with the GitBranch glyph and a DECIDE/BRANCH eyebrow chip.
 *
 * A single right-center source handle; smoothstep edges (offset 20) + dagre
 * sub-lane separation splay the branches into clean parallel lanes. (Per-edge
 * sourceHandle distribution is the escalation path for very wide fan-outs.)
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
  iconBg: string;
}

function toneFor(status: string | undefined): Tone {
  switch (status) {
    case "running":
      return {
        border: "border-primary/60",
        dotBg: "bg-primary",
        iconColor: "text-primary",
        iconBg: "bg-primary/10",
      };
    case "completed":
      return {
        border: "border-success/40",
        dotBg: "bg-success",
        iconColor: "text-success",
        iconBg: "bg-success/10",
      };
    case "failed":
      return {
        border: "border-destructive/60",
        dotBg: "bg-destructive",
        iconColor: "text-destructive",
        iconBg: "bg-destructive/10",
      };
    default:
      return {
        border: "border-border",
        dotBg: "bg-muted-foreground/50",
        iconColor: "text-muted-foreground",
        iconBg: "bg-muted/60",
      };
  }
}

const HANDLE_CLASS = "!h-1 !w-1 !min-w-0 !border-0 !bg-muted-foreground/40";

function GatewayNodeComponent({ data, type }: NodeProps) {
  const node = data as unknown as GatewayNodeData;
  const tone = toneFor(node.status);
  const eyebrow = type === "branch_fork" ? "branch" : "decide";

  return (
    <div className="relative">
      <Handle type="target" position={Position.Left} className={HANDLE_CLASS} />

      <div
        className={[
          "flex h-14 w-[200px] items-center gap-2.5 rounded-lg border bg-card px-2.5 shadow-sm",
          tone.border,
        ].join(" ")}
        title={node.label}
      >
        <div
          className={[
            "flex size-7 shrink-0 items-center justify-center rounded-md",
            tone.iconBg,
          ].join(" ")}
        >
          <GitBranch className={["size-4", tone.iconColor].join(" ")} aria-hidden="true" />
        </div>

        <div className="flex min-w-0 flex-1 flex-col gap-0.5">
          <span className="w-fit rounded-sm bg-primary/10 px-1 font-mono text-[9px] uppercase tracking-wider text-primary/80">
            {eyebrow}
          </span>
          <span className="truncate text-[13px] font-medium leading-tight text-foreground">
            {node.label}
          </span>
        </div>

        <span className={["size-1.5 shrink-0 self-start rounded-full", tone.dotBg].join(" ")} />
      </div>

      <Handle type="source" position={Position.Right} className={HANDLE_CLASS} />
    </div>
  );
}

export const GatewayNode = memo(GatewayNodeComponent);
