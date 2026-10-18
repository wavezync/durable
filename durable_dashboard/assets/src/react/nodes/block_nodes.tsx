/**
 * The two small nodes that give parallel and branch blocks their shape —
 * pills like Start / End, not cards, because they run no code of their own:
 *
 *   - JoinNode    closes a parallel block: "all 3 done" once every child has
 *   - BranchNode  a branch's gateway: "3 paths", then "→ low" once one ran
 *
 * Both carry the dashboard tooltip with what they mean for this run.
 */

import { Handle, type NodeProps, Position } from "@xyflow/react";
import { GitBranch, GitMerge } from "lucide-react";
import { memo } from "react";
import type { NodeData } from "./shared";
import { HANDLE_CLASS } from "./step_node";

const PILL =
  "flex h-7 w-[132px] items-center justify-center gap-1.5 rounded-full border px-2.5 text-[11px]";

function pillTone(status: string | undefined, notRun: boolean | undefined): string {
  if (notRun) return "border-dashed border-border text-muted-foreground opacity-60";
  switch (status) {
    case "completed":
      return "border-success/40 bg-success/10 text-success";
    case "running":
      return "border-primary/50 bg-primary/10 text-primary";
    case "failed":
      return "border-destructive/50 bg-destructive/10 text-destructive";
    default:
      return "border-border bg-card text-muted-foreground";
  }
}

function JoinNodeComponent({ data }: NodeProps) {
  const node = data as unknown as NodeData;
  const total = node.members?.length ?? 0;
  const done = node.done ?? 0;
  const label =
    node.status === "completed"
      ? `all ${total} done`
      : done > 0
        ? `${done} of ${total} done`
        : `join · ${total}`;

  return (
    <div className="relative">
      <Handle type="target" position={Position.Left} className={HANDLE_CLASS} />
      <div
        className={[PILL, pillTone(node.status, node.not_run)].join(" ")}
        data-tip-title="Join"
        data-tip={`Waits for all ${total} parallel steps before the run moves on\n${done} of ${total} done`}
      >
        <GitMerge className="size-3.5 shrink-0" aria-hidden="true" />
        <span className="truncate">{label}</span>
      </div>
      <Handle type="source" position={Position.Right} className={HANDLE_CLASS} />
    </div>
  );
}

function BranchNodeComponent({ data }: NodeProps) {
  const node = data as unknown as NodeData;
  const clauses = (node.paths ?? []).map((p) => p.clause);
  const others = clauses.filter((c) => c !== node.taken);
  const tip = node.taken
    ? `Took “${node.taken}”${others.length ? ` · ${others.join(", ")} not taken` : ""}`
    : node.not_run
      ? "The run ended before it got here"
      : `Will take one of: ${clauses.join(", ")}`;

  return (
    <div className="relative">
      <Handle type="target" position={Position.Left} className={HANDLE_CLASS} />
      <div
        className={[PILL, pillTone(node.status, node.not_run)].join(" ")}
        data-tip-title="Branch"
        data-tip={`Runs one path, picked by the branch's on: value\n${tip}`}
      >
        <GitBranch className="size-3.5 shrink-0" aria-hidden="true" />
        <span className="truncate font-mono">
          {node.taken ? `→ ${node.taken}` : `${clauses.length} paths`}
        </span>
      </div>
      <Handle type="source" position={Position.Right} className={HANDLE_CLASS} />
    </div>
  );
}

export const JoinNode = memo(JoinNodeComponent);
export const BranchNode = memo(BranchNodeComponent);
