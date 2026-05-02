/**
 * Workflow edge — bezier path with optional label chip rendered through
 * ReactFlow's portal. Status-driven stroke styling is applied via the
 * `flow-edge-{completed,running,pending}` classes set on the edge wrapper
 * by `graph_builder.overlay_status/3` (DESIGN.md §11). This component
 * focuses on label rendering; we keep edge stroke handled by CSS so the
 * theme can shift it without a re-render.
 */

import { BaseEdge, EdgeLabelRenderer, type EdgeProps, getBezierPath } from "@xyflow/react";
import { memo } from "react";

function AnimatedFlowEdgeComponent({
  id,
  sourceX,
  sourceY,
  targetX,
  targetY,
  sourcePosition,
  targetPosition,
  label,
  markerEnd,
}: EdgeProps) {
  const [path, labelX, labelY] = getBezierPath({
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
  });

  return (
    <>
      <BaseEdge id={id} path={path} markerEnd={markerEnd} />

      {label ? (
        <EdgeLabelRenderer>
          <div
            className={[
              "nodrag nopan absolute pointer-events-none",
              "rounded-sm border border-border bg-muted px-1.5 py-0.5",
              "font-mono text-[10px] uppercase tracking-wider text-foreground/80",
            ].join(" ")}
            style={{
              transform: `translate(-50%, -50%) translate(${labelX}px, ${labelY}px)`,
            }}
          >
            {label}
          </div>
        </EdgeLabelRenderer>
      ) : null}
    </>
  );
}

export const AnimatedFlowEdge = memo(AnimatedFlowEdgeComponent);
