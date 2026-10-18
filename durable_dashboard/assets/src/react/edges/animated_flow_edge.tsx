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
  const [path, midX, midY] = getSmoothStepPath({
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

  // Labels sit on the edge's last run into its target, where each target has
  // its own row, rather than at the midpoint, where a gateway's edges share
  // one vertical trunk and their labels would stack.
  const forward = targetX > sourceX;
  const labelX = forward ? targetX - Math.max(28, (targetX - sourceX) / 4) : midX;
  const labelY = forward ? targetY : midY;

  return (
    <>
      <BaseEdge id={id} path={path} markerEnd={markerEnd} />

      {label ? (
        <EdgeLabelRenderer>
          <div
            className={[
              "nodrag nopan absolute pointer-events-none",
              "rounded-[4px] border border-border bg-card px-1.5 py-px",
              "font-mono text-[10px] text-subtle-foreground",
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
