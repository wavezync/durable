import { useMemo, useState } from "react";
import { LogViewer } from "@/components/shared/LogViewer";
import type { DisplayLogEntry, StepExecution } from "@/lib/types";

interface LogsTabProps {
  steps: StepExecution[];
  initialStepFilter?: string | null;
}

export function LogsTab({ steps, initialStepFilter }: LogsTabProps) {
  const [stepFilter, setStepFilter] = useState<string | null>(initialStepFilter ?? null);

  const aggregatedLogs = useMemo<DisplayLogEntry[]>(() => {
    const all: DisplayLogEntry[] = [];
    for (const step of steps) {
      for (let i = 0; i < (step.logs?.length ?? 0); i++) {
        const log = step.logs[i];
        all.push({
          ...log,
          step: step.step_name,
          attempt: step.attempt,
          key: `${step.id}:${step.attempt}:${i}`,
        });
      }
    }
    all.sort((a, b) => {
      const ta = a.timestamp ? Date.parse(a.timestamp) : 0;
      const tb = b.timestamp ? Date.parse(b.timestamp) : 0;
      return ta - tb;
    });
    return all;
  }, [steps]);

  const visibleLogs = useMemo(() => {
    if (!stepFilter) return aggregatedLogs;
    return aggregatedLogs.filter((l) => l.step === stepFilter);
  }, [aggregatedLogs, stepFilter]);

  const stepChips = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const log of aggregatedLogs) {
      if (log.step) counts[log.step] = (counts[log.step] ?? 0) + 1;
    }
    const unique: [string, number][] = [];
    const seen = new Set<string>();
    for (const step of steps) {
      const c = counts[step.step_name] ?? 0;
      if (c > 0 && !seen.has(step.step_name)) {
        unique.push([step.step_name, c]);
        seen.add(step.step_name);
      }
    }
    return unique;
  }, [steps, aggregatedLogs]);

  if (aggregatedLogs.length === 0) {
    return (
      <div className="flex items-center justify-center py-24 text-muted-foreground">
        <p className="font-mono text-[10px] uppercase tracking-[0.22em]">No logs captured</p>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      {/* Step filter chips */}
      {stepChips.length > 1 && (
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="mr-1 font-mono text-[10px] uppercase tracking-[0.18em] text-muted-foreground/80">
            Step
          </span>
          <FilterChip
            active={!stepFilter}
            onClick={() => setStepFilter(null)}
            label="All"
            count={aggregatedLogs.length}
          />
          {stepChips.map(([name, count]) => (
            <FilterChip
              key={name}
              active={stepFilter === name}
              onClick={() => setStepFilter(name)}
              label={name}
              count={count}
            />
          ))}
        </div>
      )}

      <div className="h-[480px] border border-border/70">
        <LogViewer logs={visibleLogs} showStep={!stepFilter} />
      </div>
    </div>
  );
}

function FilterChip({
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
      className="flex items-center gap-1.5 border border-border/60 bg-background/40 px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.14em] text-muted-foreground transition-colors hover:border-border hover:text-foreground data-[active=true]:border-[var(--primary)]/60 data-[active=true]:bg-[var(--primary)]/10 data-[active=true]:text-[var(--primary)]"
    >
      <span className="max-w-[120px] truncate">{label}</span>
      <span className="opacity-70">{count}</span>
    </button>
  );
}
