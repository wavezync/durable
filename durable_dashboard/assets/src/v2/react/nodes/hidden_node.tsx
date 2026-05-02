/**
 * Hidden node — registered in `NODE_TYPES` for legacy server-emitted
 * types (`parallel_fork`, `parallel_join`, `branch_fork`, `branch_join`)
 * that were dropped from the data model in the n8n-style refactor.
 *
 * If a stale BEAM still emits one of these types, it renders absolutely
 * nothing instead of falling through to ReactFlow's default node — which
 * would show the data.label as floating text on the canvas (DESIGN.md §11
 * notes that we have no marker nodes; this guard keeps that promise even
 * when the server is out of sync).
 *
 * Dagre still allocates a layout cell for these (they go through
 * `dimsFor()` like any other type), so edges that pass through them
 * keep their geometry. They just don't paint.
 */

import { Handle, Position } from "@xyflow/react";
import { memo } from "react";

function HiddenNodeComponent() {
  return (
    <div className="size-px opacity-0 pointer-events-none">
      <Handle type="target" position={Position.Left} className="opacity-0" />
      <Handle type="source" position={Position.Right} className="opacity-0" />
    </div>
  );
}

export const HiddenNode = memo(HiddenNodeComponent);
