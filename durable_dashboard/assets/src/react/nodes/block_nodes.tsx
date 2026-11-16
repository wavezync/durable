/**
 * The two small nodes that give parallel and branch blocks their shape —
 * pills like Start / End, not cards, because they run no code of their own:
 *
 *   - JoinNode    closes a parallel block: "all 3 done" once every child has;
 *                 a block that collects goes on with "2 done · 1 failed"
 *   - BranchNode  a branch's gateway: "3 paths", then "→ low" once one ran;
 *                 a named branch leads with its name, "risk → review"
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
  const failed = node.failed ?? 0;
  const unit = node.lanes ? "lanes" : "parallel steps";
  const label =
    node.status !== "completed"
      ? done > 0
        ? `${done} of ${total} done`
        : `join · ${total}`
      : failed > 0
        ? `${done} done · ${failed} failed`
        : `all ${total} done`;
  const rule = node.collect
    ? `Goes on once all ${total} ${unit} have ended, failed or not`
    : `Waits for all ${total} ${unit} before the run moves on`;

  return (
    <div className="relative">
      <Handle type="target" position={Position.Left} className={HANDLE_CLASS} />
      <div
        className={[PILL, pillTone(node.status, node.not_run)].join(" ")}
        data-tip-title="Join"
        data-tip={`${rule}\n${done} of ${total} done${failed > 0 ? ` · ${failed} failed` : ""}`}
      >
        <GitMerge className="size-3.5 shrink-0" aria-hidden="true" />
        <span className="truncate">{label}</span>
      </div>
      <Handle type="source" position={Position.Right} className={HANDLE_CLASS} />
    </div>
  );
}

function branchTip(node: NodeData, clauses: string[]): string {
  const others = clauses.filter((c) => c !== node.taken);
  if (node.taken)
    return `Took “${node.taken}”${others.length ? ` · ${others.join(", ")} not taken` : ""}`;
  if (node.status === "failed") return node.error ?? "The deciding step failed";
  if (node.not_run) return "The run ended before it got here";
  return `Will take one of: ${clauses.join(", ")}`;
}

function BranchNodeComponent({ data }: NodeProps) {
  const node = data as unknown as NodeData;
  const clauses = (node.paths ?? []).map((p) => p.clause);
  const outcome = node.taken ? `→ ${node.taken}` : `${clauses.length} paths`;
  // A named branch's gateway is its deciding step, and carries the name.
  const how = node.decider
    ? `A step picks one path${node.step_execution_id ? " · click to inspect it" : ""}`
    : "Runs one path, picked by the branch's on: value";

  return (
    <div className="relative">
      <Handle type="target" position={Position.Left} className={HANDLE_CLASS} />
      <div
        className={[PILL, pillTone(node.status, node.not_run)].join(" ")}
        data-tip-title={node.decider ? `Branch “${node.label}”` : "Branch"}
        data-tip={`${how}\n${branchTip(node, clauses)}`}
      >
        <GitBranch className="size-3.5 shrink-0" aria-hidden="true" />
        <span className="truncate font-mono">
          {node.decider ? `${node.label} ${node.taken ? outcome : `· ${outcome}`}` : outcome}
        </span>
      </div>
      <Handle type="source" position={Position.Right} className={HANDLE_CLASS} />
    </div>
  );
}

export const JoinNode = memo(JoinNodeComponent);
export const BranchNode = memo(BranchNodeComponent);
