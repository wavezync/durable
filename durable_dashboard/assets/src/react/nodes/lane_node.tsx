/**
 * Lane frame — drawn behind the steps of a lane of several steps in a named
 * parallel block, so the lane reads as one line of work: a dashed outline
 * tinted by how the lane did, and a tab with its name and the options
 * written on it ("optional · default · 5s"). A lane of one step carries its
 * options on that step's card instead. Laid out in `graph-layout.ts` from the
 * lanes listed on the block's join; it has no edges and takes no clicks.
 */

import type { NodeProps } from "@xyflow/react";
import { memo } from "react";
import type { LaneInfo } from "../../lib/types";
import { formatMs, laneLine } from "./shared";

export type LaneFrameData = LaneInfo & { width: number; height: number };

const FRAME_TONE: Record<string, string> = {
  running: "border-primary/50 bg-primary/[0.04]",
  completed: "border-success/40 bg-success/[0.03]",
  failed: "border-destructive/50 bg-destructive/[0.04]",
};

function LaneFrameComponent({ data }: NodeProps) {
  const lane = data as unknown as LaneFrameData;
  const tone = FRAME_TONE[lane.status ?? ""] ?? "border-border bg-muted/20";
  const options = [
    lane.optional ? "optional" : null,
    lane.default ? "default" : null,
    lane.timeout_ms ? formatMs(lane.timeout_ms) : null,
  ].filter(Boolean);

  return (
    <div
      className={["relative rounded-xl border border-dashed", tone].join(" ")}
      style={{ width: lane.width, height: lane.height }}
    >
      <div
        className="pointer-events-auto absolute -top-2.5 left-3 flex items-center gap-1 rounded-md border border-border bg-background px-1.5 text-[10px] leading-[18px] text-muted-foreground"
        data-tip-title={`Lane ${lane.name}`}
        data-tip={laneLine(lane)}
      >
        <span className="font-medium text-foreground/80">{lane.name}</span>
        {options.map((option) => (
          <span key={option} className="font-mono text-muted-foreground/80">
            · {option}
          </span>
        ))}
      </div>
    </div>
  );
}

export const LaneNode = memo(LaneFrameComponent);
