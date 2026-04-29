import { ArrowLeft } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import { LogViewer } from "@/components/shared/LogViewer";
import { Skeleton } from "@/components/ui/skeleton";
import { useLiveEvent, useLiveEventSubscription } from "@/hooks/useLiveEvent";
import type {
  DisplayLogEntry,
  NavigateFn,
  StepExecution,
  Workflow,
  WorkflowDetailResponse,
} from "@/lib/types";
import { cn } from "@/lib/utils";

interface WorkflowLogsViewProps {
  id: string;
  stepFilter?: string;
  attemptFilter?: string;
  navigate: NavigateFn;
}

/**
 * Full-viewport aggregated log stream for a whole workflow. Reads the same
 * detail payload the overview page uses — logs are already embedded under
 * each step — and interleaves them into a single time-ordered display feed.
 *
 * Deep-link entry points (the "Open logs" link from the side panel) can
 * scope the view by pre-setting the step (and optionally attempt) filter.
 */
export function WorkflowLogsView({
  id,
  stepFilter,
  attemptFilter,
  navigate,
}: WorkflowLogsViewProps) {
  const [workflow, setWorkflow] = useState<Workflow | null>(null);
  const [steps, setSteps] = useState<StepExecution[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [activeStep, setActiveStep] = useState<string | null>(stepFilter ?? null);
  const { pushEvent } = useLiveEvent();

  // Keep local filter state in sync with URL-provided deep-link param.
  useEffect(() => {
    setActiveStep(stepFilter ?? null);
  }, [stepFilter]);

  const applyDetail = useCallback((data: WorkflowDetailResponse) => {
    if (data.error) {
      setError(data.error);
    } else {
      setWorkflow(data.workflow);
      setSteps(data.steps || []);
    }
  }, []);

  const loadData = useCallback(async () => {
    if (!id) return;
    try {
      const data = (await pushEvent("get_workflow", {
        id,
      })) as WorkflowDetailResponse;
      applyDetail(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to load workflow");
    } finally {
      setLoading(false);
    }
  }, [id, pushEvent, applyDetail]);

  useEffect(() => {
    loadData();
  }, [loadData]);

  useLiveEventSubscription("workflow_detail", (payload) => {
    applyDetail(payload as WorkflowDetailResponse);
  });

  // Build the unified log stream. Each line gets a stable key so the
  // underlying <LogViewer> can preserve DOM nodes across PubSub refreshes
  // (important for autoscroll not jumping as new lines arrive).
  const aggregatedLogs = useMemo<DisplayLogEntry[]>(() => {
    const all: DisplayLogEntry[] = [];
    steps.forEach((step) => {
      const stepLogs = step.logs || [];
      stepLogs.forEach((log, idx) => {
        all.push({
          ...log,
          step: step.step_name,
          attempt: step.attempt,
          key: `${step.id}:${step.attempt}:${idx}`,
        });
      });
    });
    // Sort by timestamp when available; fall back to encounter order so
    // steps without timestamps still appear grouped.
    all.sort((a, b) => {
      const ta = a.timestamp ? Date.parse(a.timestamp) : 0;
      const tb = b.timestamp ? Date.parse(b.timestamp) : 0;
      return ta - tb;
    });
    return all;
  }, [steps]);

  // Count lines per step so the filter chips can show volumes.
  const stepCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const log of aggregatedLogs) {
      if (!log.step) continue;
      counts[log.step] = (counts[log.step] ?? 0) + 1;
    }
    return counts;
  }, [aggregatedLogs]);

  const stepChips = useMemo(() => {
    const unique = new Map<string, number>();
    for (const step of steps) {
      const count = stepCounts[step.step_name] ?? 0;
      if (count === 0) continue;
      unique.set(step.step_name, count);
    }
    return Array.from(unique.entries());
  }, [steps, stepCounts]);

  // Narrow the feed based on active filters (step + optional attempt).
  const visibleLogs = useMemo<DisplayLogEntry[]>(() => {
    if (!activeStep && !attemptFilter) return aggregatedLogs;
    const attempt = attemptFilter ? Number(attemptFilter) : null;
    return aggregatedLogs.filter((log) => {
      if (activeStep && log.step !== activeStep) return false;
      if (attempt != null && log.attempt !== attempt) return false;
      return true;
    });
  }, [aggregatedLogs, activeStep, attemptFilter]);

  const handleStepClick = useCallback(
    (stepName: string | null) => {
      setActiveStep(stepName);
      // Push the URL change so a bookmarked logs view reflects the choice.
      navigate("workflow_detail", {
        id,
        tab: "logs",
        ...(stepName ? { step: stepName } : {}),
      });
    },
    [id, navigate],
  );

  if (loading) {
    return <LogsSkeleton />;
  }

  if (error || !workflow) {
    return (
      <div className="space-y-6">
        <BackLink onClick={() => navigate("workflow_detail", { id })} />
        <div className="border border-destructive/40 bg-destructive/5 p-8 text-center">
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-destructive/70">Error</p>
          <p className="mt-2 text-destructive">{error || "Workflow not found"}</p>
        </div>
      </div>
    );
  }

  const totalLines = aggregatedLogs.length;
  const emptyTitle = totalLines === 0 ? "No logs yet" : undefined;

  return (
    <div className="flex min-h-[calc(100vh-9rem)] flex-col gap-6">
      <div className="space-y-4">
        <BackLink onClick={() => navigate("workflow_detail", { id })} />
        <div className="flex flex-wrap items-end justify-between gap-4">
          <div>
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted-foreground">
              Log stream
            </p>
            <h1 className="text-heading mt-2 text-4xl text-foreground md:text-5xl">
              {workflow.workflow_name}
            </h1>
          </div>
          <div className="font-mono text-[10px] uppercase tracking-[0.16em] text-muted-foreground">
            {totalLines.toLocaleString()} total lines · {stepChips.length} step
            {stepChips.length === 1 ? "" : "s"}
          </div>
        </div>
      </div>

      {/* Step filter chips */}
      {stepChips.length > 0 && (
        <div className="flex flex-wrap items-center gap-1.5 border-y border-border/70 bg-card/30 px-4 py-3">
          <span className="mr-2 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground/80">
            Step
          </span>
          <StepChip
            active={!activeStep}
            onClick={() => handleStepClick(null)}
            label="All"
            count={totalLines}
          />
          {stepChips.map(([name, count]) => (
            <StepChip
              key={name}
              active={activeStep === name}
              onClick={() => handleStepClick(name)}
              label={name}
              count={count}
            />
          ))}
        </div>
      )}

      {/* The full-height log stream. `h-[70vh]` anchors it so the viewer fills
          the browser viewport even with a tall header. */}
      <div className="h-[70vh] min-h-[420px]">
        <LogViewer logs={visibleLogs} showStep={!activeStep} emptyTitle={emptyTitle} />
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */

function BackLink({ onClick }: { onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="group inline-flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.2em] text-muted-foreground transition-colors hover:text-foreground"
    >
      <ArrowLeft className="h-3 w-3 transition-transform group-hover:-translate-x-0.5" />
      Back to workflow
    </button>
  );
}

function StepChip({
  active,
  onClick,
  label,
  count,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
  count: number;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      data-active={active}
      className={cn(
        "flex items-center gap-1.5 border px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.14em] transition-colors",
        "border-border/60 bg-background/40 text-muted-foreground hover:border-border hover:text-foreground",
        "data-[active=true]:border-[var(--primary)]/60 data-[active=true]:bg-[var(--primary)]/10 data-[active=true]:text-[var(--primary)]",
      )}
    >
      <span className="max-w-[160px] truncate">{label}</span>
      <span className="opacity-70">{count}</span>
    </button>
  );
}

function LogsSkeleton() {
  return (
    <div className="space-y-6">
      <Skeleton className="h-3 w-24" />
      <Skeleton className="h-14 w-96" />
      <Skeleton className="h-10 w-full rounded-none" />
      <Skeleton className="h-[70vh] w-full rounded-none" />
    </div>
  );
}
