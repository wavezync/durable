import { Copy, MoreHorizontal, RotateCw, XCircle } from "lucide-react";
import type { ReactNode } from "react";
import { useCallback, useEffect, useState } from "react";
import { toast } from "sonner";
import { StatusBadge } from "@/components/shared/StatusBadge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { StepDetailPanel } from "@/components/workflow/StepDetailPanel";
import { useLiveEvent, useLiveEventSubscription } from "@/hooks/useLiveEvent";
import type {
  GraphData,
  NavigateFn,
  PendingInput,
  StepExecution,
  Workflow,
  WorkflowDetailResponse,
} from "@/lib/types";
import { formatDateTime, formatDuration, shortModule } from "@/lib/utils";
import { FlowTab } from "./workflow-tabs/FlowTab";
import { HistoryTab } from "./workflow-tabs/HistoryTab";
import { IOTab } from "./workflow-tabs/IOTab";
import { LogsTab } from "./workflow-tabs/LogsTab";
import { SummaryTab } from "./workflow-tabs/SummaryTab";
import { TopologyTab } from "./workflow-tabs/TopologyTab";

interface WorkflowDetailViewProps {
  id: string;
  navigate: NavigateFn;
  viewParams?: Record<string, string>;
}

const TAB_OPTIONS = [
  { value: "summary", label: "Summary" },
  { value: "flow", label: "Flow" },
  { value: "topology", label: "Topology" },
  { value: "logs", label: "Logs" },
  { value: "io", label: "I/O" },
  { value: "history", label: "History" },
] as const;

type TabValue = (typeof TAB_OPTIONS)[number]["value"];

export function WorkflowDetailView({ id, navigate, viewParams }: WorkflowDetailViewProps) {
  const [workflow, setWorkflow] = useState<Workflow | null>(null);
  const [steps, setSteps] = useState<StepExecution[]>([]);
  const [pendingInputs, setPendingInputs] = useState<PendingInput[]>([]);
  const [graphData, setGraphData] = useState<GraphData | null>(null);
  const [selectedStep, setSelectedStep] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionLoading, setActionLoading] = useState(false);
  const { pushEvent } = useLiveEvent();

  const activeTab: TabValue = (viewParams?.tab as TabValue) || "summary";

  const applyDetail = useCallback((data: WorkflowDetailResponse) => {
    if (data.error) {
      setError(data.error);
    } else {
      setWorkflow(data.workflow);
      setSteps(data.steps || []);
      setPendingInputs(data.pending_inputs || []);
      setGraphData(data.graph || null);
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

  // ---- Actions ----

  const handleCancel = async () => {
    if (!workflow || actionLoading) return;
    setActionLoading(true);
    try {
      const result = (await pushEvent("cancel_workflow", {
        id: workflow.id,
        reason: "Cancelled from dashboard",
      })) as { ok?: boolean; error?: string };
      if (result.ok) toast.success("Workflow cancelled");
      else toast.error(result.error || "Failed to cancel");
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to cancel");
    } finally {
      setActionLoading(false);
    }
  };

  const handleRerun = async () => {
    if (!workflow || actionLoading) return;
    setActionLoading(true);
    try {
      const result = (await pushEvent("retry_workflow", {
        id: workflow.id,
      })) as { ok?: boolean; workflow_id?: string; error?: string };
      if (result.ok && result.workflow_id) {
        toast.success("New workflow started");
        navigate("workflow_detail", { id: result.workflow_id });
      } else {
        toast.error(result.error || "Failed to re-run");
      }
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to re-run");
    } finally {
      setActionLoading(false);
    }
  };

  const handleCopyId = async () => {
    if (!workflow) return;
    try {
      await navigator.clipboard.writeText(workflow.id);
      toast.success("ID copied");
    } catch {
      toast.error("Could not copy");
    }
  };

  const handleProvideInput = async (inputName: string, data: unknown) => {
    if (!workflow) return;
    try {
      const result = (await pushEvent("provide_input", {
        workflow_id: workflow.id,
        input_name: inputName,
        data,
      })) as { ok?: boolean; error?: string };
      if (result.ok) toast.success("Input provided");
      else toast.error(result.error || "Failed to provide input");
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to provide input");
    }
  };

  const handleTabChange = (tab: string) => {
    navigate("workflow_detail", { id, tab });
  };

  const handleStepClick = (stepName: string) => setSelectedStep(stepName);

  const selectedStepData = selectedStep ? steps.find((s) => s.step_name === selectedStep) : null;

  // ---- Render ----

  if (loading) return <DetailSkeleton />;

  if (error || !workflow) {
    return (
      <div className="space-y-6">
        <div className="border border-destructive/40 bg-destructive/5 p-8 text-center">
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-destructive/70">Error</p>
          <p className="mt-2 text-destructive">{error || "Workflow not found"}</p>
        </div>
      </div>
    );
  }

  const isTerminal = [
    "completed",
    "failed",
    "cancelled",
    "compensated",
    "compensation_failed",
  ].includes(workflow.status);
  const canCancel = ["pending", "running", "waiting"].includes(workflow.status);
  const canRerun = isTerminal;

  const durationText = formatDuration(
    workflow.started_at,
    workflow.completed_at || new Date().toISOString(),
  );
  const completedSteps = steps.filter((s) => s.status === "completed").length;
  const uniqueStepNames = new Set(steps.map((s) => s.step_name)).size;

  return (
    <div className="space-y-6">
      {/* Header — name + status + actions */}
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0 flex-1">
          <h1 className="text-heading text-2xl text-foreground sm:text-3xl">
            {workflow.workflow_name}
          </h1>
          <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1.5 font-mono text-[11px] text-muted-foreground">
            <StatusBadge status={workflow.status} />
            <span className="h-3 w-px bg-border" />
            <button
              type="button"
              onClick={handleCopyId}
              className="group flex items-center gap-1 tracking-[0.05em] transition-colors hover:text-foreground"
            >
              <span className="max-w-[180px] truncate">{workflow.id}</span>
              <Copy className="h-2.5 w-2.5 opacity-0 group-hover:opacity-100" />
            </button>
            <span className="h-3 w-px bg-border" />
            <span className="truncate">{workflow.workflow_module}</span>
          </div>
        </div>

        {/* Actions — primary buttons visible, secondary in dropdown */}
        <div className="flex items-center gap-2">
          {canRerun && (
            <Button size="sm" onClick={handleRerun} disabled={actionLoading} className="gap-1.5">
              <RotateCw className="h-3.5 w-3.5" /> Retry
            </Button>
          )}
          {canCancel && (
            <Button
              variant="outline"
              size="sm"
              onClick={handleCancel}
              disabled={actionLoading}
              className="gap-1.5 border-destructive/40 text-destructive hover:bg-destructive/10 hover:text-destructive"
            >
              <XCircle className="h-3.5 w-3.5" /> Cancel
            </Button>
          )}
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="icon-sm">
                <MoreHorizontal className="h-4 w-4" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem onClick={handleCopyId}>
                <Copy className="mr-2 h-3.5 w-3.5" /> Copy ID
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>

      {/* Telemetry rail */}
      <div className="grid grid-cols-2 border border-border/70 bg-card/40 sm:grid-cols-4">
        <TelemetryCell label="Duration" value={durationText} accent />
        <TelemetryCell label="Queue" value={workflow.queue} />
        <TelemetryCell
          label={isTerminal ? "Steps" : "Current Step"}
          value={
            isTerminal ? `${completedSteps} / ${uniqueStepNames}` : workflow.current_step || "—"
          }
        />
        <TelemetryCell label="Module" value={shortModule(workflow.workflow_module)} mono />
      </div>
      <div className="grid grid-cols-2 border-x border-b border-border/70 bg-card/20 sm:grid-cols-3 -mt-6">
        <TimestampCell label="Created" value={workflow.inserted_at} />
        <TimestampCell label="Started" value={workflow.started_at} />
        <TimestampCell label="Completed" value={workflow.completed_at} />
      </div>

      {/* Tabs */}
      <Tabs value={activeTab} onValueChange={handleTabChange}>
        <TabsList variant="line" className="w-full justify-start">
          {TAB_OPTIONS.map((tab) => (
            <TabsTrigger key={tab.value} value={tab.value}>
              {tab.label}
            </TabsTrigger>
          ))}
        </TabsList>

        <div className="mt-4">
          <TabsContent value="summary">
            <SummaryTab
              workflow={workflow}
              pendingInputs={pendingInputs}
              onProvideInput={handleProvideInput}
              onRetry={canRerun ? handleRerun : undefined}
            />
          </TabsContent>
          <TabsContent value="flow">
            <FlowTab
              workflow={workflow}
              steps={steps}
              selectedStep={selectedStep}
              onStepClick={handleStepClick}
            />
          </TabsContent>
          <TabsContent value="topology">
            <TopologyTab graphData={graphData} onStepClick={handleStepClick} />
          </TabsContent>
          <TabsContent value="logs">
            <LogsTab steps={steps} />
          </TabsContent>
          <TabsContent value="io">
            <IOTab workflow={workflow} />
          </TabsContent>
          <TabsContent value="history">
            <HistoryTab />
          </TabsContent>
        </div>
      </Tabs>

      {/* Step detail side panel — shared across graph + timeline */}
      <StepDetailPanel
        step={selectedStepData || null}
        stepName={selectedStep || ""}
        workflowId={workflow.id}
        open={!!selectedStep}
        onOpenChange={(open) => !open && setSelectedStep(null)}
        navigate={navigate}
      />
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Shared sub-components                                                      */
/* -------------------------------------------------------------------------- */

function TelemetryCell({
  label,
  value,
  mono = false,
  accent = false,
}: {
  label: string;
  value: ReactNode;
  mono?: boolean;
  accent?: boolean;
}) {
  return (
    <div className="border-r border-border/70 px-4 py-3 last:border-r-0">
      <p className="font-mono text-[9px] uppercase tracking-[0.22em] text-muted-foreground">
        {label}
      </p>
      <p
        className={`mt-1.5 truncate text-lg ${mono ? "font-mono text-sm" : ""} ${accent ? "text-[var(--primary)]" : "text-foreground"}`}
      >
        {value}
      </p>
    </div>
  );
}

function TimestampCell({ label, value }: { label: string; value: string | null }) {
  return (
    <div className="border-r border-border/70 px-4 py-2.5 last:border-r-0">
      <p className="font-mono text-[9px] uppercase tracking-[0.22em] text-muted-foreground">
        {label}
      </p>
      <p className="mt-1 font-mono text-[11px] tabular-nums text-foreground/80">
        {formatDateTime(value)}
      </p>
    </div>
  );
}

function DetailSkeleton() {
  return (
    <div className="space-y-6">
      <div className="space-y-3">
        <Skeleton className="h-8 w-64" />
        <Skeleton className="h-4 w-96" />
      </div>
      <Skeleton className="h-20 rounded-none" />
      <Skeleton className="h-10 w-full" />
      <Skeleton className="h-[400px] rounded-none" />
    </div>
  );
}
