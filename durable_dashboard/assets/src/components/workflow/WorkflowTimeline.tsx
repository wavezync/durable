import { useEffect, useMemo, useState } from "react";
import { StatusBadge } from "@/components/shared/StatusBadge";
import type { StepExecution, Workflow } from "@/lib/types";
import { cn, formatDurationMs } from "@/lib/utils";

interface WorkflowTimelineProps {
  workflow: Workflow;
  steps: StepExecution[];
  onStepClick: (stepName: string) => void;
  selectedStep?: string | null;
}

type TimelineRow = {
  key: string;
  step: StepExecution;
  startMs: number;
  endMs: number;
  durationMs: number;
};

const GUTTER_PX = 200;
const STATUS_PX = 140;
const ROW_HEIGHT_PX = 34;

/**
 * Temporal-style execution waterfall. Each row is a step execution rendered
 * as a colored duration bar positioned on a shared wall-clock axis. Rows
 * show a hover card with exact start/end/duration details; running workflows
 * also get a live "now" cursor that updates once a second.
 *
 * The left gutter is fixed-width so bar alignment stays consistent across
 * rows; the time axis in the header uses the same offsets, producing the
 * network-request-waterfall feel familiar from Temporal / Chrome DevTools.
 */
export function WorkflowTimeline({
  workflow,
  steps,
  onStepClick,
  selectedStep,
}: WorkflowTimelineProps) {
  // 1Hz ticker for live duration bars while anything is still running.
  const [now, setNow] = useState(() => Date.now());
  const hasRunning = steps.some((s) => s.status === "running");

  useEffect(() => {
    if (!hasRunning) return;
    const id = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(id);
  }, [hasRunning]);

  const { rows, axisStart, axisEnd, axisSpan } = useMemo(() => {
    return buildRows(workflow, steps, now);
  }, [workflow, steps, now]);

  if (rows.length === 0) {
    return (
      <div className="flex h-full items-center justify-center p-12 text-center">
        <div>
          <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted-foreground">
            No executed steps yet
          </p>
          <p className="mt-2 text-[11px] text-muted-foreground/70">
            The waterfall will populate as the workflow runs.
          </p>
        </div>
      </div>
    );
  }

  const ticks = buildTicks(axisSpan);
  const totalDurationLabel = formatDurationMs(axisSpan);
  const nowInAxis =
    hasRunning && now >= axisStart && now <= axisEnd + 60_000
      ? ((now - axisStart) / axisSpan) * 100
      : null;

  return (
    <div className="flex h-full min-h-0 flex-col font-mono text-[11px]">
      {/* Summary header */}
      <div className="flex shrink-0 items-center justify-between border-b border-border/70 bg-card/30 px-5 py-2 text-[10px] uppercase tracking-[0.16em] text-muted-foreground">
        <span>
          Flow · {rows.length} execution{rows.length === 1 ? "" : "s"}
        </span>
        <span className="flex items-center gap-3">
          <span>
            Start{" "}
            <span className="tabular-nums text-foreground/80">{formatWallClock(axisStart)}</span>
          </span>
          <span className="h-3 w-px bg-border/70" />
          <span>
            Total <span className="tabular-nums text-[var(--primary)]">{totalDurationLabel}</span>
          </span>
        </span>
      </div>

      {/* Sticky time axis — stays put while rows scroll beneath it. */}
      <div className="relative flex shrink-0 items-stretch border-b border-border/70 bg-card/20">
        <div
          className="shrink-0 border-r border-border/60 px-4 py-2 font-mono text-[9px] uppercase tracking-[0.18em] text-muted-foreground/80"
          style={{ width: GUTTER_PX }}
        >
          Step
        </div>
        <div className="relative flex-1">
          <div className="relative h-full px-4 py-2">
            {ticks.map((tick, i) => (
              <div
                key={i}
                className="absolute inset-y-0 flex items-center"
                style={{ left: `calc(${tick.pct}% + 1rem)` }}
              >
                <span className="-translate-x-1/2 tabular-nums text-[9px] text-muted-foreground/80">
                  {tick.label}
                </span>
              </div>
            ))}
          </div>
        </div>
        <div
          className="shrink-0 border-l border-border/60 px-4 py-2 text-right font-mono text-[9px] uppercase tracking-[0.18em] text-muted-foreground/80"
          style={{ width: STATUS_PX }}
        >
          Status
        </div>
      </div>

      {/* Scrollable rows container, holding both the row list and the
          absolute-positioned grid + now-cursor layers above the rows. */}
      <div className="thin-scroll min-h-0 flex-1 overflow-auto">
        <div className="relative">
          {/* Subtle vertical gridlines so the time ticks are legible across
              the full column of rows. */}
          <div
            className="pointer-events-none absolute inset-y-0"
            style={{
              left: GUTTER_PX,
              right: STATUS_PX,
            }}
          >
            <div className="relative h-full">
              {ticks.map((tick, i) => (
                <div
                  key={i}
                  className="absolute inset-y-0 w-px bg-border/30"
                  style={{ left: `calc(${tick.pct}% + 1rem)` }}
                />
              ))}
            </div>
          </div>

          {/* Current-time cursor — only visible while at least one step is
              still running. Pulses softly to draw the eye. */}
          {nowInAxis != null && (
            <div
              className="pointer-events-none absolute inset-y-0"
              style={{
                left: GUTTER_PX,
                right: STATUS_PX,
              }}
            >
              <div className="relative h-full">
                <div
                  className="absolute inset-y-0 w-px bg-[var(--primary)]/80"
                  style={{
                    left: `calc(${nowInAxis}% + 1rem)`,
                    boxShadow: "0 0 12px 0 oklch(0.82 0.17 82 / 0.4)",
                  }}
                >
                  <div className="absolute -left-[3px] top-0 h-1.5 w-1.5 rounded-full bg-[var(--primary)] led-dot" />
                </div>
              </div>
            </div>
          )}

          <ol className="relative">
            {rows.map((row) => (
              <TimelineRow
                key={row.key}
                row={row}
                axisStart={axisStart}
                axisSpan={axisSpan}
                selected={selectedStep === row.step.step_name}
                onClick={() => onStepClick(row.step.step_name)}
              />
            ))}
          </ol>
        </div>
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */

interface TimelineRowProps {
  row: TimelineRow;
  axisStart: number;
  axisSpan: number;
  selected: boolean;
  onClick: () => void;
}

function TimelineRow({ row, axisStart, axisSpan, selected, onClick }: TimelineRowProps) {
  const { step, startMs, endMs, durationMs } = row;
  const offsetPct = axisSpan > 0 ? ((startMs - axisStart) / axisSpan) * 100 : 0;
  const widthPct = axisSpan > 0 ? Math.max(((endMs - startMs) / axisSpan) * 100, 0.6) : 0;
  const tone = statusTone(step.status);
  const isRunning = step.status === "running";
  const isPending = !step.started_at;

  // Position the hover card on the side with more available room so it
  // doesn't clip at the edge of the viewport for very early/late steps.
  const tooltipOnRight = offsetPct + widthPct < 60;

  return (
    <li
      className={cn(
        "group/row relative border-b border-border/40",
        selected && "bg-[var(--primary)]/8",
      )}
      style={{ height: ROW_HEIGHT_PX }}
    >
      <button
        type="button"
        onClick={onClick}
        className={cn(
          "relative flex h-full w-full cursor-pointer items-center text-left transition-colors",
          selected ? "bg-[var(--primary)]/10" : "hover:bg-card/40",
        )}
      >
        {/* Left gutter: step name + attempt chip */}
        <div
          className="flex h-full shrink-0 items-center gap-2 border-r border-border/60 px-4"
          style={{ width: GUTTER_PX }}
        >
          <span
            className={cn("h-1.5 w-1.5 shrink-0 rounded-full", tone.dot, isRunning && "led-dot")}
          />
          <span
            className={cn(
              "flex-1 truncate text-[11px] leading-tight",
              selected ? "text-foreground" : "text-foreground/90 group-hover/row:text-foreground",
            )}
          >
            {step.step_name}
          </span>
          {step.attempt > 1 && (
            <span className="shrink-0 border border-border/60 bg-background/50 px-1 font-mono text-[9px] uppercase tracking-[0.14em] text-muted-foreground">
              #{step.attempt}
            </span>
          )}
        </div>

        {/* Right lane: waterfall bar */}
        <div className="relative flex h-full flex-1 items-center px-4">
          {isPending ? (
            <span className="w-full text-center text-[10px] uppercase tracking-[0.18em] text-muted-foreground/50">
              —
            </span>
          ) : (
            <div
              className={cn(
                "absolute top-1/2 flex h-[14px] -translate-y-1/2 items-center border",
                tone.bar,
                tone.border,
                isRunning && "shadow-[0_0_16px_-4px_oklch(0.82_0.17_82/0.8)]",
                selected && "ring-1 ring-[var(--primary)]/60",
              )}
              style={{
                left: `${offsetPct}%`,
                width: `${widthPct}%`,
                minWidth: 8,
              }}
            />
          )}

          {/* Duration label — always rendered just past the bar end so short
              bars remain readable and never hide their own label. */}
          {!isPending && (
            <span
              className={cn(
                "pointer-events-none absolute top-1/2 -translate-y-1/2 whitespace-nowrap text-[10px] tabular-nums",
                tone.labelInside,
              )}
              style={{
                left: `calc(${offsetPct + widthPct}% + 6px)`,
              }}
            >
              {formatDurationMs(durationMs)}
            </span>
          )}

          {/* Hover card: exact timing for this row. Pure CSS — shows via
              group-hover and positions on the side with more room. */}
          {!isPending && (
            <div
              className={cn(
                "pointer-events-none absolute top-1/2 z-20 -translate-y-1/2 whitespace-nowrap border border-border/70 bg-card/95 px-3 py-2 text-left opacity-0 shadow-lg backdrop-blur-xl transition-opacity duration-150 group-hover/row:opacity-100",
                tooltipOnRight
                  ? "left-[calc(var(--bar-end)+12px)]"
                  : "right-[calc(100%-var(--bar-start)+12px)]",
              )}
              style={
                {
                  "--bar-start": `${offsetPct}%`,
                  "--bar-end": `${offsetPct + widthPct}%`,
                } as React.CSSProperties
              }
            >
              <div className="font-mono text-[9px] uppercase tracking-[0.18em] text-muted-foreground">
                {step.step_name}
                {step.attempt > 1 ? ` · attempt ${step.attempt}` : ""}
              </div>
              <div className="mt-1.5 space-y-0.5 font-mono text-[10px] text-foreground/90">
                <TimingLine label="Started" value={formatWallClock(startMs)} />
                <TimingLine
                  label="Ended"
                  value={isRunning ? "in progress" : formatWallClock(endMs)}
                />
                <TimingLine label="Duration" value={formatDurationMs(durationMs)} highlight />
                <TimingLine label="Offset" value={`+${formatDurationMs(startMs - axisStart)}`} />
              </div>
            </div>
          )}
        </div>

        {/* Status pill column — fixed width so all rows align cleanly. */}
        <div
          className="flex h-full shrink-0 items-center justify-end border-l border-border/60 px-4"
          style={{ width: STATUS_PX }}
        >
          <StatusBadge status={step.status} size="sm" />
        </div>
      </button>
    </li>
  );
}

function TimingLine({
  label,
  value,
  highlight = false,
}: {
  label: string;
  value: string;
  highlight?: boolean;
}) {
  return (
    <div className="flex items-baseline gap-3">
      <span className="w-16 text-[9px] uppercase tracking-[0.14em] text-muted-foreground/80">
        {label}
      </span>
      <span
        className={cn("tabular-nums", highlight ? "text-[var(--primary)]" : "text-foreground/90")}
      >
        {value}
      </span>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

type Tone = {
  dot: string;
  bar: string;
  border: string;
  labelInside: string;
};

function statusTone(status: string): Tone {
  switch (status) {
    case "running":
      return {
        dot: "bg-[var(--primary)]",
        bar: "bg-[oklch(0.82_0.17_82/0.55)]",
        border: "border-[var(--primary)]/80",
        labelInside: "text-[oklch(0.92_0.16_85)]",
      };
    case "completed":
      return {
        dot: "bg-[oklch(0.82_0.17_150)]",
        bar: "bg-[oklch(0.82_0.17_150/0.5)]",
        border: "border-[oklch(0.82_0.17_150)]/80",
        labelInside: "text-[oklch(0.9_0.16_150)]",
      };
    case "failed":
    case "compensation_failed":
      return {
        dot: "bg-[oklch(0.82_0.18_22)]",
        bar: "bg-[oklch(0.68_0.2_22/0.55)]",
        border: "border-[oklch(0.68_0.2_22)]/80",
        labelInside: "text-[oklch(0.9_0.18_22)]",
      };
    case "waiting":
      return {
        dot: "bg-[oklch(0.78_0.13_210)]",
        bar: "bg-[oklch(0.78_0.13_210/0.5)]",
        border: "border-[oklch(0.78_0.13_210)]/80",
        labelInside: "text-[oklch(0.9_0.13_210)]",
      };
    case "cancelled":
      return {
        dot: "bg-muted-foreground/50",
        bar: "bg-muted/40",
        border: "border-border/60",
        labelInside: "text-muted-foreground",
      };
    default:
      return {
        dot: "bg-muted-foreground/40",
        bar: "bg-muted/30",
        border: "border-border/60",
        labelInside: "text-muted-foreground",
      };
  }
}

function buildRows(
  workflow: Workflow,
  steps: StepExecution[],
  now: number,
): {
  rows: TimelineRow[];
  axisStart: number;
  axisEnd: number;
  axisSpan: number;
} {
  const startedRows: TimelineRow[] = [];
  const pendingRows: TimelineRow[] = [];

  steps.forEach((step, index) => {
    const key = `${step.id}:${step.attempt}:${index}`;
    if (!step.started_at) {
      pendingRows.push({
        key,
        step,
        startMs: 0,
        endMs: 0,
        durationMs: 0,
      });
      return;
    }
    const startMs = new Date(step.started_at).getTime();
    const endMs = step.completed_at
      ? new Date(step.completed_at).getTime()
      : step.status === "running"
        ? now
        : startMs + (step.duration_ms ?? 0);
    startedRows.push({
      key,
      step,
      startMs,
      endMs,
      durationMs: Math.max(endMs - startMs, 0),
    });
  });

  startedRows.sort((a, b) => a.startMs - b.startMs);

  const workflowStart = workflow.started_at
    ? new Date(workflow.started_at).getTime()
    : startedRows[0]?.startMs;
  const axisStart = workflowStart ?? 0;

  const workflowEnd = workflow.completed_at ? new Date(workflow.completed_at).getTime() : undefined;
  const latestStepEnd = startedRows.reduce((acc, r) => Math.max(acc, r.endMs), axisStart);
  const axisEnd = workflowEnd ?? Math.max(latestStepEnd, axisStart + 1);
  const axisSpan = Math.max(axisEnd - axisStart, 1);

  return {
    rows: [...startedRows, ...pendingRows],
    axisStart,
    axisEnd,
    axisSpan,
  };
}

function buildTicks(axisSpan: number): { pct: number; label: string }[] {
  const count = 6;
  const ticks: { pct: number; label: string }[] = [];
  for (let i = 0; i < count; i++) {
    const pct = (100 * i) / (count - 1);
    const offsetMs = (axisSpan * i) / (count - 1);
    ticks.push({
      pct,
      label: i === 0 ? "0" : formatDurationMs(offsetMs),
    });
  }
  return ticks;
}

/**
 * Wall-clock timestamp formatted for the waterfall header + tooltip. Uses
 * HH:MM:SS.mmm for precision at the sub-second level — important for fast
 * workflows that finish inside a single second.
 */
function formatWallClock(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return "—";
  const d = new Date(ms);
  return d.toLocaleTimeString(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    fractionalSecondDigits: 3,
    hour12: false,
  });
}
