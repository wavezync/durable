import { WorkflowTimeline } from "@/components/workflow/WorkflowTimeline";
import type { StepExecution, Workflow } from "@/lib/types";

interface FlowTabProps {
  workflow: Workflow;
  steps: StepExecution[];
  selectedStep: string | null;
  onStepClick: (stepName: string) => void;
}

export function FlowTab({ workflow, steps, selectedStep, onStepClick }: FlowTabProps) {
  const rowCount = steps.length;
  const height = Math.min(Math.max(rowCount * 34 + 68, 240), 600);

  return (
    <div className="border border-border/70 bg-card/30" style={{ height }}>
      <WorkflowTimeline
        workflow={workflow}
        steps={steps}
        selectedStep={selectedStep}
        onStepClick={onStepClick}
      />
    </div>
  );
}
