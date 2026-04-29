import { Copy, MoveVertical, Search, TextSelect, WrapText, X } from "lucide-react";
import {
  memo,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { toast } from "sonner";
import type { DisplayLogEntry, LogEntry } from "@/lib/types";
import { cn } from "@/lib/utils";

interface LogViewerProps {
  logs: LogEntry[] | DisplayLogEntry[];
  /**
   * Render an extra column showing the step name each line belongs to. Only
   * meaningful for the aggregated workflow logs view; off by default so the
   * per-step variant stays compact.
   */
  showStep?: boolean;
  /**
   * Empty-state title override. The aggregated logs view wants a more
   * specific message than the default "No logs captured".
   */
  emptyTitle?: string;
}

type LevelKey = "all" | "debug" | "info" | "warn" | "error";

const LEVELS: { key: LevelKey; label: string }[] = [
  { key: "all", label: "All" },
  { key: "debug", label: "Debug" },
  { key: "info", label: "Info" },
  { key: "warn", label: "Warn" },
  { key: "error", label: "Error" },
];

/** Map a server level string to one of our canonical buckets. */
function normalizeLevel(raw: string | undefined): Exclude<LevelKey, "all"> {
  const v = (raw || "").toLowerCase();
  if (v.startsWith("err") || v === "fatal") return "error";
  if (v.startsWith("warn")) return "warn";
  if (v.startsWith("debug") || v === "trace") return "debug";
  return "info";
}

const LEVEL_TONE: Record<Exclude<LevelKey, "all">, { pill: string; bar: string; text: string }> = {
  debug: {
    pill: "bg-muted/40 text-muted-foreground border-border/70",
    bar: "bg-border",
    text: "text-muted-foreground",
  },
  info: {
    pill: "bg-[oklch(0.78_0.13_210/0.12)] text-[oklch(0.88_0.12_210)] border-[oklch(0.78_0.13_210)]/40",
    bar: "bg-[oklch(0.78_0.13_210)]/60",
    text: "text-foreground/85",
  },
  warn: {
    pill: "bg-[oklch(0.82_0.17_82/0.12)] text-[oklch(0.92_0.16_85)] border-[var(--primary)]/40",
    bar: "bg-[var(--primary)]/70",
    text: "text-foreground/90",
  },
  error: {
    pill: "bg-[oklch(0.68_0.2_22/0.14)] text-[oklch(0.82_0.18_22)] border-[oklch(0.68_0.2_22)]/50",
    bar: "bg-[oklch(0.82_0.18_22)]/80",
    text: "text-foreground/95",
  },
};

export function LogViewer({ logs, showStep = false, emptyTitle }: LogViewerProps) {
  const [filter, setFilter] = useState<LevelKey>("all");
  const [query, setQuery] = useState("");
  const [wrap, setWrap] = useState(true);
  const [autoScroll, setAutoScroll] = useState(true);
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const searchId = useId();

  // Widen the row type locally so the display column is available without
  // forcing every caller to migrate to DisplayLogEntry.
  const displayLogs = logs as DisplayLogEntry[];

  const levelCounts = useMemo(() => {
    const out = { debug: 0, info: 0, warn: 0, error: 0 } as Record<
      Exclude<LevelKey, "all">,
      number
    >;
    for (const log of displayLogs) {
      out[normalizeLevel(log.level)]++;
    }
    return out;
  }, [displayLogs]);

  const filteredLogs = useMemo(() => {
    const q = query.trim().toLowerCase();
    return displayLogs.filter((log) => {
      if (filter !== "all" && normalizeLevel(log.level) !== filter) {
        return false;
      }
      if (q && !log.message.toLowerCase().includes(q)) {
        return false;
      }
      return true;
    });
  }, [displayLogs, filter, query]);

  // Auto-scroll to bottom when new logs arrive, but only if the user hasn't
  // scrolled up to read history. useLayoutEffect avoids a visible jump.
  useLayoutEffect(() => {
    if (!autoScroll || !scrollRef.current) return;
    scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [autoScroll]);

  // biome-ignore lint/correctness/useExhaustiveDependencies: intentional — rescroll when the stream grows
  useEffect(() => {
    if (!autoScroll || !scrollRef.current) return;
    scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [autoScroll, filteredLogs.length]);

  const handleCopy = useCallback(async () => {
    const text = filteredLogs
      .map((log) => {
        const ts = log.timestamp ? `[${formatLogTime(log.timestamp)}] ` : "";
        const step = showStep && log.step ? `${log.step.padEnd(24)} ` : "";
        return `${ts}${(log.level || "info").toUpperCase().padEnd(5)} ${step}${log.message}`;
      })
      .join("\n");
    try {
      await navigator.clipboard.writeText(text);
      toast.success(`Copied ${filteredLogs.length} lines`);
    } catch {
      toast.error("Could not copy to clipboard");
    }
  }, [filteredLogs, showStep]);

  return (
    <div className="flex h-full min-h-0 flex-col border border-border/70 bg-background/40">
      {/* Toolbar */}
      <div className="flex flex-col gap-2 border-b border-border/70 bg-card/30 p-2">
        <div className="flex items-center gap-2">
          <label htmlFor={searchId} className="relative flex min-w-0 flex-1 items-center">
            <Search
              aria-hidden
              className="pointer-events-none absolute left-2 h-3 w-3 text-muted-foreground"
            />
            <input
              id={searchId}
              type="text"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="Search log lines…"
              className="h-7 w-full border border-border/60 bg-background/60 pl-6 pr-6 font-mono text-[11px] text-foreground placeholder:text-muted-foreground/60 focus:border-[var(--primary)]/50 focus:outline-none focus:ring-1 focus:ring-[var(--primary)]/30"
            />
            {query && (
              <button
                type="button"
                onClick={() => setQuery("")}
                className="absolute right-1 rounded-sm p-0.5 text-muted-foreground hover:bg-muted/40 hover:text-foreground"
                aria-label="Clear search"
              >
                <X className="h-3 w-3" />
              </button>
            )}
          </label>
          <ToolbarToggle
            active={wrap}
            onClick={() => setWrap((v) => !v)}
            label="Wrap"
            icon={<WrapText className="h-3 w-3" />}
          />
          <ToolbarToggle
            active={autoScroll}
            onClick={() => setAutoScroll((v) => !v)}
            label="Tail"
            icon={<MoveVertical className="h-3 w-3" />}
          />
          <ToolbarButton
            onClick={handleCopy}
            disabled={filteredLogs.length === 0}
            label="Copy"
            icon={<Copy className="h-3 w-3" />}
          />
        </div>
        <div className="flex items-center justify-between gap-2">
          <div className="flex items-center gap-1">
            {LEVELS.map((lv) => {
              const active = filter === lv.key;
              const count =
                lv.key === "all"
                  ? displayLogs.length
                  : levelCounts[lv.key as Exclude<LevelKey, "all">];
              return (
                <button
                  key={lv.key}
                  type="button"
                  onClick={() => setFilter(lv.key)}
                  data-active={active}
                  className="group flex items-center gap-1.5 border border-transparent px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.14em] text-muted-foreground transition-colors hover:text-foreground data-[active=true]:border-border data-[active=true]:bg-background/80 data-[active=true]:text-foreground"
                >
                  {lv.label}
                  <span className="text-[9px] opacity-60">{count}</span>
                </button>
              );
            })}
          </div>
          <div className="flex items-center gap-1.5 font-mono text-[10px] uppercase tracking-[0.16em] text-muted-foreground">
            <TextSelect className="h-3 w-3" />
            <span>
              {filteredLogs.length}
              {filteredLogs.length !== displayLogs.length ? ` / ${displayLogs.length}` : ""} lines
            </span>
          </div>
        </div>
      </div>

      {/* Log stream */}
      <div
        ref={scrollRef}
        className="thin-scroll min-h-0 flex-1 overflow-auto bg-background/70 font-mono text-[11px] leading-5"
      >
        {filteredLogs.length === 0 ? (
          <EmptyState hasLogs={displayLogs.length > 0} hasQuery={!!query} title={emptyTitle} />
        ) : (
          <ol className="py-1">
            {filteredLogs.map((log, i) => (
              <LogLine
                key={log.key ?? i}
                log={log}
                index={i + 1}
                wrap={wrap}
                query={query}
                showStep={showStep}
              />
            ))}
          </ol>
        )}
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */

interface LogLineProps {
  log: DisplayLogEntry;
  index: number;
  wrap: boolean;
  query: string;
  showStep: boolean;
}

const LogLine = memo(function LogLine({ log, index, wrap, query, showStep }: LogLineProps) {
  const level = normalizeLevel(log.level);
  const tone = LEVEL_TONE[level];

  return (
    <li
      className={cn(
        "group/line flex items-start gap-3 border-l-2 border-transparent px-3 py-0.5 hover:border-l-[var(--primary)]/40 hover:bg-card/40",
        tone.text,
      )}
    >
      <span className="w-8 shrink-0 select-none text-right text-[10px] text-muted-foreground/50 tabular-nums">
        {index}
      </span>
      {log.timestamp && (
        <span className="w-24 shrink-0 text-muted-foreground/80 tabular-nums">
          {formatLogTime(log.timestamp)}
        </span>
      )}
      <span
        className={cn(
          "shrink-0 border px-1 text-[9px] font-semibold uppercase tracking-[0.16em]",
          tone.pill,
        )}
      >
        {level}
      </span>
      {showStep && (
        <span className="w-40 shrink-0 truncate text-[10px] uppercase tracking-[0.12em] text-muted-foreground/80">
          {log.step || "—"}
          {log.attempt && log.attempt > 1 ? ` · #${log.attempt}` : ""}
        </span>
      )}
      <span
        className={cn("flex-1 break-all", wrap ? "whitespace-pre-wrap" : "truncate whitespace-pre")}
      >
        {query ? <HighlightedText text={log.message} query={query} /> : log.message}
      </span>
    </li>
  );
});

function HighlightedText({ text, query }: { text: string; query: string }) {
  const q = query.trim();
  if (!q) return <>{text}</>;
  const parts: (string | { match: string })[] = [];
  const lower = text.toLowerCase();
  const target = q.toLowerCase();
  let i = 0;
  while (i < text.length) {
    const idx = lower.indexOf(target, i);
    if (idx === -1) {
      parts.push(text.slice(i));
      break;
    }
    if (idx > i) parts.push(text.slice(i, idx));
    parts.push({ match: text.slice(idx, idx + target.length) });
    i = idx + target.length;
  }
  return (
    <>
      {parts.map((p, k) =>
        typeof p === "string" ? (
          <span key={k}>{p}</span>
        ) : (
          <mark key={k} className="bg-[var(--primary)]/35 text-foreground">
            {p.match}
          </mark>
        ),
      )}
    </>
  );
}

function ToolbarButton({
  onClick,
  label,
  icon,
  disabled,
}: {
  onClick: () => void;
  label: string;
  icon: React.ReactNode;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="flex h-7 items-center gap-1.5 border border-border/60 bg-background/40 px-2 font-mono text-[10px] uppercase tracking-[0.14em] text-muted-foreground transition-colors hover:border-border hover:text-foreground disabled:cursor-not-allowed disabled:opacity-40"
    >
      {icon}
      <span className="hidden sm:inline">{label}</span>
    </button>
  );
}

function ToolbarToggle({
  active,
  onClick,
  label,
  icon,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
  icon: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      data-active={active}
      className="flex h-7 items-center gap-1.5 border border-border/60 bg-background/40 px-2 font-mono text-[10px] uppercase tracking-[0.14em] text-muted-foreground transition-colors hover:border-border hover:text-foreground data-[active=true]:border-[var(--primary)]/50 data-[active=true]:bg-[var(--primary)]/10 data-[active=true]:text-[var(--primary)]"
    >
      {icon}
      <span className="hidden sm:inline">{label}</span>
    </button>
  );
}

function EmptyState({
  hasLogs,
  hasQuery,
  title: titleOverride,
}: {
  hasLogs: boolean;
  hasQuery: boolean;
  title?: string;
}) {
  const title =
    titleOverride ??
    (!hasLogs ? "No logs captured" : hasQuery ? "No matching lines" : "No logs at this level");
  const hint = !hasLogs
    ? "Run the workflow to produce log output."
    : "Adjust the filter or search to see more.";
  return (
    <div className="flex h-full flex-col items-center justify-center gap-2 p-8 text-center">
      <p className="font-mono text-[10px] uppercase tracking-[0.22em] text-muted-foreground">
        {title}
      </p>
      <p className="text-[11px] text-muted-foreground/70">{hint}</p>
    </div>
  );
}

function formatLogTime(ts: string): string {
  try {
    const d = new Date(ts);
    return d.toLocaleTimeString(undefined, {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      fractionalSecondDigits: 3,
      hour12: false,
    });
  } catch {
    return ts;
  }
}
