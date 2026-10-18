/**
 * Decision node — a `decision` step: it runs code that returns which step
 * comes next ({:goto, step, data}). Same 220×56 card as StepNode with the
 * GitBranch glyph and a "decide" eyebrow; its dashed edges are the `goto`
 * targets, the one taken drawn solid.
 */

import { Handle, type NodeProps, Position } from "@xyflow/react";
import { GitBranch } from "lucide-react";
import { memo } from "react";
import { dotClass, type NodeData, statusLine, toneFor } from "./shared";
import { HANDLE_CLASS } from "./step_node";

function GatewayNodeComponent({ data }: NodeProps) {
  const node = data as unknown as NodeData;
  const tone = toneFor(node.not_run ? undefined : node.status);

  return (
    <div className="relative">
      <Handle type="target" position={Position.Left} className={HANDLE_CLASS} />

      <div
        className={[
          "flex h-14 w-[220px] items-center gap-2.5 rounded-lg border bg-card px-2.5 shadow-sm",
          tone.border,
          node.not_run ? "border-dashed opacity-60" : "",
        ].join(" ")}
        data-tip-title={node.label}
        data-tip={`A decision · its code picks the next step (goto)\n${statusLine(node)}`}
        data-tip-meta={node.error}
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
          <span className="truncate text-[13px] font-medium leading-tight text-foreground">
            {node.label}
          </span>
          <span className="flex min-w-0 items-center gap-1.5 text-[11px] text-muted-foreground">
            <span className={dotClass(node)} aria-hidden="true" />
            <span className="truncate">decide · {statusLine(node)}</span>
          </span>
        </div>
      </div>

      <Handle type="source" position={Position.Right} className={HANDLE_CLASS} />
    </div>
  );
}

export const GatewayNode = memo(GatewayNodeComponent);
