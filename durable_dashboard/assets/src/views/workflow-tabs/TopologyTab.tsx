import { WorkflowGraph } from "@/components/workflow/WorkflowGraph";
import type { GraphData } from "@/lib/types";

interface TopologyTabProps {
  graphData: GraphData | null;
  onStepClick: (stepName: string) => void;
}

export function TopologyTab({ graphData, onStepClick }: TopologyTabProps) {
  if (!graphData || graphData.nodes.length === 0) {
    return (
      <div className="flex items-center justify-center py-24 text-muted-foreground">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em]">No graph data available</p>
      </div>
    );
  }

  return (
    <div className="h-[520px] border border-border/70 bg-card/30">
      <WorkflowGraph graphData={graphData} onNodeClick={onStepClick} />
    </div>
  );
}
