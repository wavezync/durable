/**
 * Workflow edge — orthogonal **smoothstep** path with an optional label chip.
 * Smoothstep (vs the old free bezier) is the load-bearing fix for "odd
 * branching": edges leave the source's right face, run straight, then step to
 * each target's Y, so fan-out/fan-in form clean parallel trunks instead of
 * overlapping swoops (the Argo/Dagster/GitHub-Actions look). Status stroke is
 * applied via the `flow-edge-{completed,running,pending,conditional}` classes
 * set by `graph_builder.overlay_status/3` (DESIGN.md §11), so the theme/status
 * can shift the stroke without a re-render.
 */

import { BaseEdge, EdgeLabelRenderer, type EdgeProps, getSmoothStepPath } from "@xyflow/react";
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
  const [path, labelX, labelY] = getSmoothStepPath({
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
    // Soft modern corners + a 20px straight run out of each handle so sibling
    // branches share a clean trunk before splaying to their lanes.
    borderRadius: 8,
    offset: 20,
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
