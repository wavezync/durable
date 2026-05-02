import type { Workflow } from "@/lib/types";

interface IOTabProps {
  workflow: Workflow;
}

export function IOTab({ workflow }: IOTabProps) {
  const hasInput = workflow.input && Object.keys(workflow.input).length > 0;
  const hasContext = workflow.context && Object.keys(workflow.context).length > 0;

  if (!hasInput && !hasContext) {
    return (
      <div className="flex items-center justify-center py-24 text-muted-foreground">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em]">No input or output data</p>
      </div>
    );
  }

  return (
    <div className="grid gap-6 lg:grid-cols-2">
      <JsonPanel label="Input" value={workflow.input} />
      <JsonPanel label="Context / Output" value={workflow.context} />
    </div>
  );
}

function JsonPanel({
  label,
  value,
}: {
  label: string;
  value: Record<string, unknown> | null | undefined;
}) {
  return (
    <div className="border border-border/70">
      <div className="flex items-center justify-between border-b border-border/70 bg-card/40 px-4 py-2.5">
        <span className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted-foreground">
          {label}
        </span>
        <span className="font-mono text-[9px] text-muted-foreground/60">
          {value ? "JSON" : "null"}
        </span>
      </div>
      <pre className="thin-scroll max-h-[400px] overflow-auto bg-background/50 p-4 font-mono text-[11px] text-foreground/80">
        {value ? JSON.stringify(value, null, 2) : "null"}
      </pre>
    </div>
  );
}
