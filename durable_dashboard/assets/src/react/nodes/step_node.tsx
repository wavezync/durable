/**
 * Step node — a horizontal status card (220×56) in the spirit of Argo /
 * Dagster / GitHub Actions run graphs: a status-tinted icon tile, the step
 * name, and a status line with the dashboard's status dot ("● Completed ·
 * 147 ms"). In a finished run a step that never ran is dashed and dimmed and
 * says "Not run". Hovering shows the dashboard tooltip (`stepTip`).
 *
 * `ChildWorkflowNode` reuses this card for a step that ran as its own run,
 * with a stacked sheet behind it and the fork icon.
 *
 * Click → dispatches `durable:step-clicked`; the FlowGraph LC patches the
 * page to `?step=<execution id>` and the run page's inspector opens beside
 * the graph, this card ringed. A step that never ran isn't clickable.
 */

import { Handle, type NodeProps, Position } from "@xyflow/react";
import { Box, GitFork } from "lucide-react";
import { memo, useCallback } from "react";
import { dotClass, type NodeData, statusLine, stepTip, toneFor } from "./shared";

// Near-invisible read-only handles — the graph isn't user-editable, so the
// ports just anchor the edges to the card's left/right faces.
export const HANDLE_CLASS = "!h-1 !w-1 !min-w-0 !border-0 !bg-muted-foreground/40";

export function StepCard({ node, child }: { node: NodeData; child: boolean }) {
  const tone = toneFor(node.not_run ? undefined : node.status);
  const Icon = child ? GitFork : Box;
  const inspectable = Boolean(node.step_execution_id);

  const handleClick = useCallback(
    (e: React.SyntheticEvent) => {
      e.stopPropagation();
      if (!inspectable) return;
      const target = e.currentTarget as HTMLElement | null;
      const evt = new CustomEvent("durable:step-clicked", {
        bubbles: true,
        composed: true,
        detail: {
          stepName: node.name,
          stepExecutionId: node.step_execution_id ?? null,
          childWorkflowId: node.child_workflow_id ?? null,
        },
      });
      (target ?? document).dispatchEvent(evt);
    },
    [inspectable, node.name, node.step_execution_id, node.child_workflow_id],
  );

  return (
    <div
      className={[
        "nopan relative flex h-14 w-[220px] items-center gap-2.5 rounded-lg border bg-card px-2.5 shadow-sm",
        "transition-colors duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        inspectable ? "cursor-pointer hover:border-foreground/30" : "",
        tone.border,
        node.not_run ? "border-dashed opacity-60" : "",
        node.selected ? "ring-2 ring-primary ring-offset-2 ring-offset-background" : "",
      ].join(" ")}
      onClick={handleClick}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          handleClick(e);
        }
      }}
      role="button"
      tabIndex={inspectable ? 0 : -1}
      aria-disabled={!inspectable}
      aria-pressed={Boolean(node.selected)}
      aria-label={child ? `Open ${node.label}, which ran as a child run` : node.label}
      {...stepTip(node, child)}
    >
      <div
        className={[
          "flex size-7 shrink-0 items-center justify-center rounded-md",
          tone.iconBg,
        ].join(" ")}
      >
        <Icon className={["size-4", tone.iconColor].join(" ")} aria-hidden="true" />
      </div>

      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        <span className="truncate text-[13px] font-medium leading-tight text-foreground">
          {node.label}
        </span>
        <span className="flex min-w-0 items-center gap-1.5 text-[11px] text-muted-foreground">
          <span className={dotClass(node)} aria-hidden="true" />
          <span className="truncate">{statusLine(node)}</span>
        </span>
      </div>
    </div>
  );
}

function StepNodeComponent({ data }: NodeProps) {
  return (
    <div className="relative">
      <Handle type="target" position={Position.Left} className={HANDLE_CLASS} />
      <StepCard node={data as unknown as NodeData} child={false} />
      <Handle type="source" position={Position.Right} className={HANDLE_CLASS} />
    </div>
  );
}

export const StepNode = memo(StepNodeComponent);
