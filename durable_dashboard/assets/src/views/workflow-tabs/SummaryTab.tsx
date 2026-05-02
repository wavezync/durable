import { RotateCw } from "lucide-react";
import { InputForm } from "@/components/shared/InputForm";
import { Button } from "@/components/ui/button";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import type { PendingInput, Workflow } from "@/lib/types";

interface SummaryTabProps {
  workflow: Workflow;
  pendingInputs: PendingInput[];
  onProvideInput: (inputName: string, data: unknown) => void;
  onRetry?: () => void;
}

export function SummaryTab({ workflow, pendingInputs, onProvideInput, onRetry }: SummaryTabProps) {
  const isTerminal = [
    "completed",
    "failed",
    "cancelled",
    "compensated",
    "compensation_failed",
  ].includes(workflow.status);

  return (
    <div className="space-y-6">
      {/* Error panel */}
      {workflow.error && (
        <ErrorPanel error={workflow.error as Record<string, unknown>} onRetry={onRetry} />
      )}

      {/* Pending inputs */}
      {pendingInputs.length > 0 && (
        <section className="border border-[var(--primary)]/40 bg-[oklch(0.82_0.17_82/0.04)]">
          <div className="flex items-center justify-between border-b border-[var(--primary)]/30 px-5 py-3">
            <h3 className="font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--primary)]">
              Pending inputs
            </h3>
            <span className="font-mono text-[10px] uppercase tracking-[0.16em] text-[var(--primary)]/70">
              {pendingInputs.length} awaiting
            </span>
          </div>
          <div className="space-y-4 p-5">
            {pendingInputs.map((input) => (
              <InputForm
                key={input.id}
                input={input}
                onSubmit={(data) => onProvideInput(input.input_name, data)}
              />
            ))}
          </div>
        </section>
      )}

      {/* Workflow input */}
      {workflow.input && Object.keys(workflow.input).length > 0 && (
        <JsonSection label="Workflow input" value={workflow.input} />
      )}

      {/* Context snapshot */}
      {!isTerminal && workflow.context && Object.keys(workflow.context).length > 0 && (
        <section className="border border-border/70 bg-card/30">
          <Collapsible>
            <CollapsibleTrigger className="group flex w-full items-center justify-between px-5 py-3 text-left">
              <span className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted-foreground group-hover:text-foreground">
                Context snapshot
              </span>
              <span className="font-mono text-[10px] text-muted-foreground">[ expand ]</span>
            </CollapsibleTrigger>
            <CollapsibleContent>
              <pre className="thin-scroll max-h-64 overflow-auto border-t border-border/70 bg-background/50 p-5 font-mono text-[11px] text-muted-foreground">
                {JSON.stringify(workflow.context, null, 2)}
              </pre>
            </CollapsibleContent>
          </Collapsible>
        </section>
      )}

      {/* Empty state when nothing to show */}
      {!workflow.error &&
        pendingInputs.length === 0 &&
        (!workflow.input || Object.keys(workflow.input).length === 0) && (
          <div className="py-16 text-center text-muted-foreground">
            <p className="font-mono text-[10px] uppercase tracking-[0.22em]">No summary data</p>
            <p className="mt-2 text-sm">
              Switch to the Flow or Topology tab to see execution details.
            </p>
          </div>
        )}
    </div>
  );
}

function ErrorPanel({ error, onRetry }: { error: Record<string, unknown>; onRetry?: () => void }) {
  return (
    <section className="border border-destructive/40 bg-destructive/5">
      <div className="flex items-center justify-between border-b border-destructive/30 px-5 py-3">
        <div className="flex items-center gap-3">
          <span className="h-1.5 w-1.5 rounded-full bg-destructive led-dot" />
          <h3 className="font-mono text-[11px] uppercase tracking-[0.18em] text-destructive">
            Execution fault
          </h3>
        </div>
        {onRetry && (
          <Button size="sm" onClick={onRetry} className="gap-1.5">
            <RotateCw className="h-3 w-3" /> Retry workflow
          </Button>
        )}
      </div>
      <pre className="thin-scroll max-h-48 overflow-auto p-5 font-mono text-[11px] text-destructive/80">
        {JSON.stringify(error, null, 2)}
      </pre>
    </section>
  );
}

function JsonSection({ label, value }: { label: string; value: Record<string, unknown> }) {
  return (
    <section className="border border-border/70">
      <div className="border-b border-border/70 bg-card/40 px-5 py-2.5">
        <h3 className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted-foreground">
          {label}
        </h3>
      </div>
      <pre className="thin-scroll max-h-64 overflow-auto bg-background/50 p-5 font-mono text-[11px] text-foreground/80">
        {JSON.stringify(value, null, 2)}
      </pre>
    </section>
  );
}
