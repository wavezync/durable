import type { NodeMouseHandler } from "@xyflow/react";
import { Background, BackgroundVariant, Controls, MiniMap, ReactFlow } from "@xyflow/react";
import { useCallback, useMemo } from "react";
import { layoutGraph } from "@/lib/graph-layout";
import type { GraphData } from "@/lib/types";
import { BranchNode } from "./nodes/BranchNode";
import { JoinNode } from "./nodes/JoinNode";
import { ParallelNode } from "./nodes/ParallelNode";
import { StepNode } from "./nodes/StepNode";

const nodeTypes = {
  step: StepNode,
  decision: StepNode,
  branch_fork: BranchNode,
  branch_join: BranchNode,
  parallel_fork: ParallelNode,
  parallel_join: ParallelNode,
  join: JoinNode,
};

interface WorkflowGraphProps {
  graphData: GraphData;
  onNodeClick: (nodeId: string) => void;
}

export function WorkflowGraph({ graphData, onNodeClick }: WorkflowGraphProps) {
  const { nodes, edges } = useMemo(() => layoutGraph(graphData), [graphData]);

  const handleNodeClick: NodeMouseHandler = useCallback(
    (_event, node) => {
      onNodeClick(node.id);
    },
    [onNodeClick],
  );

  return (
    <div className="relative h-full w-full">
      {/* Subtle schematic grid underlay — lives inside the frame so the
          fiducials in the parent read as bezels, not page chrome. */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0"
        style={{
          backgroundImage:
            "linear-gradient(to right, oklch(0.96 0.015 85 / 0.035) 1px, transparent 1px), linear-gradient(to bottom, oklch(0.96 0.015 85 / 0.035) 1px, transparent 1px)",
          backgroundSize: "40px 40px",
        }}
      />
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        onNodeClick={handleNodeClick}
        fitView
        fitViewOptions={{ padding: 0.24 }}
        minZoom={0.25}
        maxZoom={2}
        proOptions={{ hideAttribution: true }}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={true}
      >
        <Background
          variant={BackgroundVariant.Dots}
          color="oklch(0.96 0.015 85)"
          gap={24}
          size={0.8}
          style={{ opacity: 0.08 }}
        />
        <Controls showInteractive={false} />
        <MiniMap
          nodeColor="oklch(0.82 0.17 82 / 0.8)"
          nodeStrokeColor="oklch(0.82 0.17 82)"
          maskColor="oklch(0.135 0.008 65 / 0.7)"
          pannable
          zoomable
        />
      </ReactFlow>
    </div>
  );
}
