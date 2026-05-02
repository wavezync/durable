import { createContext, useContext, useEffect, useMemo, useState } from "react";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";

// ---------------------------------------------------------------------------
// Shared tick context — a single 30s interval drives all RelativeTime
// instances so we don't spawn a timer per component.
// ---------------------------------------------------------------------------

const TickContext = createContext<number>(Date.now());

export function RelativeTimeProvider({ children }: { children: React.ReactNode }) {
  const [tick, setTick] = useState(Date.now);

  useEffect(() => {
    const id = window.setInterval(() => setTick(Date.now()), 30_000);
    return () => window.clearInterval(id);
  }, []);

  return <TickContext.Provider value={tick}>{children}</TickContext.Provider>;
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

interface RelativeTimeProps {
  value: string | null | undefined;
  className?: string;
}

export function RelativeTime({ value, className }: RelativeTimeProps) {
  const tick = useContext(TickContext);

  const { relative, absolute } = useMemo(() => {
    if (!value) return { relative: "—", absolute: "" };
    const date = new Date(value);
    return {
      relative: formatRelative(date, tick),
      absolute: date.toLocaleString(),
    };
  }, [value, tick]);

  if (!value) {
    return <span className={cn("text-muted-foreground", className)}>—</span>;
  }

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <time dateTime={value} className={cn("tabular-nums", className)}>
          {relative}
        </time>
      </TooltipTrigger>
      <TooltipContent side="top" className="font-mono text-xs">
        {absolute}
      </TooltipContent>
    </Tooltip>
  );
}

function formatRelative(date: Date, now: number): string {
  const diffMs = now - date.getTime();
  if (diffMs < 0) return "just now";
  const diffSec = Math.floor(diffMs / 1000);
  if (diffSec < 5) return "just now";
  if (diffSec < 60) return `${diffSec}s ago`;
  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;
  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;
  const diffDay = Math.floor(diffHr / 24);
  if (diffDay < 30) return `${diffDay}d ago`;
  // Fall back to a short date for anything older.
  return date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}
