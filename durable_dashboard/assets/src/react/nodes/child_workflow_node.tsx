/**
 * Child workflow node — a step that ran as its own `WorkflowExecution` (a
 * parallel child, or a `call_workflow` / `start_workflow` sub-workflow).
 *
 * The same card as `StepNode` with a stacked sheet peeking behind it — "a
 * whole run lives in here" — and the fork icon. Clicking inspects it like
 * any step; the inspector links to the child run.
 */

import { Handle, type NodeProps, Position } from "@xyflow/react";
import { memo } from "react";
import type { NodeData } from "./shared";
import { HANDLE_CLASS, StepCard } from "./step_node";

function ChildWorkflowNodeComponent({ data }: NodeProps) {
  return (
    <div className="group relative">
      <Handle type="target" position={Position.Left} className={HANDLE_CLASS} />
      <div
        aria-hidden="true"
        className="absolute -top-1.5 left-1.5 h-14 w-[220px] rounded-lg border border-border/55 bg-card/70 shadow-sm transition-transform duration-150 group-hover:-translate-y-0.5"
      />
      <StepCard node={data as unknown as NodeData} child />
      <Handle type="source" position={Position.Right} className={HANDLE_CLASS} />
    </div>
  );
}

export const ChildWorkflowNode = memo(ChildWorkflowNodeComponent);
