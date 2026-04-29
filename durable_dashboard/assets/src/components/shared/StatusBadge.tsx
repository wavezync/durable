import type { StepStatus, WorkflowStatus } from "@/lib/types";
import { cn } from "@/lib/utils";

type StatusTone =
  | "neutral"
  | "running"
  | "waiting"
  | "completed"
  | "failed"
  | "cancelled"
  | "compensating"
  | "compensated";

type StatusMeta = {
  label: string;
  tone: StatusTone;
};

const STATUS_META: Record<string, StatusMeta> = {
  pending: { label: "Pending", tone: "neutral" },
  running: { label: "Running", tone: "running" },
  waiting: { label: "Waiting", tone: "waiting" },
  completed: { label: "Completed", tone: "completed" },
  failed: { label: "Failed", tone: "failed" },
  cancelled: { label: "Cancelled", tone: "cancelled" },
  compensating: { label: "Compensating", tone: "compensating" },
  compensated: { label: "Compensated", tone: "compensated" },
  compensation_failed: { label: "Comp. Failed", tone: "failed" },
};

const TONE_STYLES: Record<StatusTone, { chip: string; dot: string; pulsing: boolean }> = {
  neutral: {
    chip: "border-border/70 text-muted-foreground bg-muted/30",
    dot: "bg-muted-foreground/60",
    pulsing: false,
  },
  running: {
    chip: "border-[var(--primary)]/50 text-[oklch(0.92_0.14_85)] bg-[oklch(0.82_0.17_82/0.12)] shadow-[0_0_20px_-8px_oklch(0.82_0.17_82/0.7)]",
    dot: "bg-[var(--primary)] text-[var(--primary)]",
    pulsing: true,
  },
  waiting: {
    chip: "border-[oklch(0.78_0.13_210)]/40 text-[oklch(0.88_0.12_210)] bg-[oklch(0.78_0.13_210/0.1)]",
    dot: "bg-[oklch(0.78_0.13_210)] text-[oklch(0.78_0.13_210)]",
    pulsing: true,
  },
  completed: {
    chip: "border-[oklch(0.82_0.17_150)]/40 text-[oklch(0.9_0.16_150)] bg-[oklch(0.82_0.17_150/0.1)]",
    dot: "bg-[oklch(0.82_0.17_150)]",
    pulsing: false,
  },
  failed: {
    chip: "border-[oklch(0.68_0.2_22)]/50 text-[oklch(0.82_0.18_22)] bg-[oklch(0.68_0.2_22/0.12)]",
    dot: "bg-[oklch(0.82_0.18_22)]",
    pulsing: false,
  },
  cancelled: {
    chip: "border-border/60 text-muted-foreground bg-muted/20",
    dot: "bg-muted-foreground/40",
    pulsing: false,
  },
  compensating: {
    chip: "border-[oklch(0.82_0.17_40)]/40 text-[oklch(0.88_0.17_40)] bg-[oklch(0.82_0.17_40/0.12)]",
    dot: "bg-[oklch(0.82_0.17_40)] text-[oklch(0.82_0.17_40)]",
    pulsing: true,
  },
  compensated: {
    chip: "border-[oklch(0.78_0.13_280)]/40 text-[oklch(0.85_0.13_280)] bg-[oklch(0.78_0.13_280/0.12)]",
    dot: "bg-[oklch(0.78_0.13_280)]",
    pulsing: false,
  },
};

interface StatusBadgeProps {
  status: WorkflowStatus | StepStatus | string;
  className?: string;
  size?: "sm" | "md";
}

export function StatusBadge({ status, className, size = "md" }: StatusBadgeProps) {
  const meta = STATUS_META[status] || {
    label: status,
    tone: "neutral" as const,
  };
  const tone = TONE_STYLES[meta.tone];

  return (
    <span
      className={cn(
        "inline-flex items-center gap-2 border font-mono uppercase tracking-[0.14em] transition-colors",
        size === "sm" ? "h-5 px-1.5 text-[10px]" : "h-6 px-2 text-[10px]",
        tone.chip,
        className,
      )}
      data-status={meta.tone}
    >
      <span
        className={cn("inline-block h-1.5 w-1.5 rounded-full", tone.dot, tone.pulsing && "led-dot")}
      />
      {meta.label}
    </span>
  );
}
