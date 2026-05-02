import { ArrowUpRight } from "lucide-react";
import { useEffect, useState } from "react";
import { StatusBadge } from "@/components/shared/StatusBadge";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from "@/components/ui/sheet";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import type { NavigateFn, StepExecution } from "@/lib/types";

interface StepDetailPanelProps {
  step: StepExecution | null;
  stepName: string;
  workflowId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  navigate?: NavigateFn;
  /** Scroll to the inline log section with this step pre-filtered. */
  onOpenLogs?: (stepName: string) => void;
}

export function StepDetailPanel({
  step,
  stepName,
  workflowId,
  open,
  onOpenChange,
  navigate,
  onOpenLogs,
}: StepDetailPanelProps) {
  const [activeTab, setActiveTab] = useState("info");

  useEffect(() => {
    if (step?.error) {
      setActiveTab("error");
    } else {
      setActiveTab("info");
    }
  }, [step?.error]);

  const handleOpenLogs = () => {
    onOpenChange(false);
    if (onOpenLogs) {
      onOpenLogs(stepName);
    } else if (navigate) {
      navigate("workflow_detail", {
        id: workflowId,
        tab: "logs",
        step: stepName,
        ...(step?.attempt ? { attempt: String(step.attempt) } : {}),
      });
    }
  };

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        side="right"
        className="flex w-full flex-col gap-0 border-l border-border/70 p-0 sm:max-w-xl"
      >
        <SheetHeader className="gap-2 border-b border-border/70 px-6 py-5">
          <div className="flex items-center justify-between gap-3">
            <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted-foreground">
              Step inspector
            </p>
            {(onOpenLogs || navigate) && (
              <button
                type="button"
                onClick={handleOpenLogs}
                className="flex items-center gap-1 border border-border/60 bg-background/40 px-2 py-0.5 font-mono text-[9px] uppercase tracking-[0.16em] text-muted-foreground transition-colors hover:border-[var(--primary)]/50 hover:text-[var(--primary)]"
              >
                Open in logs
                <ArrowUpRight className="h-2.5 w-2.5" />
              </button>
            )}
          </div>
          <SheetTitle className="font-sans text-3xl leading-[1.05] tracking-[-0.01em] text-foreground">
            {stepName}
          </SheetTitle>
          {step && (
            <SheetDescription asChild>
              <div className="flex items-center gap-3 pt-1">
                <StatusBadge status={step.status} />
                <span className="font-mono text-[10px] uppercase tracking-[0.16em] text-muted-foreground">
                  Attempt {step.attempt}
                </span>
                {step.duration_ms != null && (
                  <span className="font-mono text-[10px] uppercase tracking-[0.16em] text-muted-foreground">
                    · {formatDuration(step.duration_ms)}
                  </span>
                )}
              </div>
            </SheetDescription>
          )}
        </SheetHeader>

        <Tabs
          value={activeTab}
          onValueChange={setActiveTab}
          className="flex min-h-0 flex-1 flex-col"
        >
          <TabsList
            variant="line"
            className="h-auto w-full justify-start gap-2 rounded-none border-b border-border/70 bg-transparent px-6 py-0"
          >
            <StepTab value="info">Info</StepTab>
            <StepTab value="io">I/O</StepTab>
            {step?.error && <StepTab value="error">Error</StepTab>}
          </TabsList>

          <div className="min-h-0 flex-1 overflow-auto">
            {!step ? (
              <EmptyState />
            ) : (
              <>
                <TabsContent value="info" className="p-6">
                  <InfoTab step={step} />
                </TabsContent>
                <TabsContent value="io" className="p-6">
                  <IOTab step={step} />
                </TabsContent>
                <TabsContent value="error" className="p-6">
                  <ErrorTab step={step} />
                </TabsContent>
              </>
            )}
          </div>
        </Tabs>
      </SheetContent>
    </Sheet>
  );
}

/* -------------------------------------------------------------------------- */

function StepTab({ value, children }: { value: string; children: React.ReactNode }) {
  return (
    <TabsTrigger
      value={value}
      className="border-0 px-0 py-3 font-mono text-[11px] uppercase tracking-[0.18em] text-muted-foreground data-[state=active]:text-foreground"
    >
      {children}
    </TabsTrigger>
  );
}

function EmptyState() {
  return (
    <div className="flex h-full items-center justify-center p-8 text-center">
      <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted-foreground">
        No execution data
      </p>
    </div>
  );
}

function InfoTab({ step }: { step: StepExecution }) {
  const items = [
    { label: "Name", value: step.step_name, mono: true },
    { label: "Type", value: step.step_type, mono: true },
    { label: "Status", value: step.status, mono: true },
    { label: "Attempt", value: String(step.attempt), mono: true },
    {
      label: "Duration",
      value: step.duration_ms != null ? formatDuration(step.duration_ms) : "—",
      mono: true,
    },
    {
      label: "Started",
      value: step.started_at ? new Date(step.started_at).toLocaleString() : "—",
    },
    {
      label: "Completed",
      value: step.completed_at ? new Date(step.completed_at).toLocaleString() : "—",
    },
  ];

  return (
    <dl className="divide-y divide-border/70 border-y border-border/70">
      {items.map((item) => (
        <div key={item.label} className="flex items-center justify-between gap-4 py-2.5">
          <dt className="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
            {item.label}
          </dt>
          <dd
            className={`truncate text-right text-[12px] text-foreground ${
              item.mono ? "font-mono" : ""
            }`}
          >
            {item.value}
          </dd>
        </div>
      ))}
    </dl>
  );
}

function IOTab({ step }: { step: StepExecution }) {
  return (
    <div className="space-y-5">
      <IOBlock label="Input" value={step.input} />
      <IOBlock label="Output" value={step.output} />
    </div>
  );
}

function IOBlock({ label, value }: { label: string; value: Record<string, unknown> | null }) {
  return (
    <div className="border border-border/70">
      <div className="flex items-center justify-between border-b border-border/70 bg-card/40 px-3 py-1.5">
        <span className="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
          {label}
        </span>
        <span className="font-mono text-[9px] text-muted-foreground/60">
          {value ? "JSON" : "null"}
        </span>
      </div>
      <pre className="thin-scroll max-h-56 overflow-auto bg-background/50 p-3 font-mono text-[11px] text-foreground/90">
        {value ? JSON.stringify(value, null, 2) : "null"}
      </pre>
    </div>
  );
}

function ErrorTab({ step }: { step: StepExecution }) {
  if (!step.error) {
    return (
      <p className="text-center font-mono text-[10px] uppercase tracking-[0.22em] text-muted-foreground">
        No error
      </p>
    );
  }

  return (
    <div className="space-y-4">
      {step.error.type != null && (
        <Field label="Type">
          <span className="font-mono text-[12px] text-destructive">{String(step.error.type)}</span>
        </Field>
      )}
      {step.error.message != null && (
        <Field label="Message">
          <span className="text-[13px] text-destructive/90">{String(step.error.message)}</span>
        </Field>
      )}
      <div className="border border-destructive/40">
        <div className="border-b border-destructive/30 bg-destructive/5 px-3 py-1.5 font-mono text-[10px] uppercase tracking-[0.18em] text-destructive">
          Full trace
        </div>
        <pre className="thin-scroll max-h-64 overflow-auto bg-destructive/5 p-3 font-mono text-[11px] text-destructive/80">
          {JSON.stringify(step.error, null, 2)}
        </pre>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="border-l-2 border-destructive/40 pl-3">
      <p className="font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground">
        {label}
      </p>
      <div className="mt-1">{children}</div>
    </div>
  );
}

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60000) return `${(ms / 1000).toFixed(2)}s`;
  return `${Math.floor(ms / 60000)}m ${Math.floor((ms % 60000) / 1000)}s`;
}
