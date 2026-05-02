import { type ClassValue, clsx } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

/**
 * Format an ISO datetime string for compact display in telemetry rails.
 * Returns an em-dash placeholder when the input is null/undefined.
 */
export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

/**
 * Format a duration given a start timestamp and an end timestamp (ISO strings).
 * Returns an em-dash placeholder when start is missing.
 */
export function formatDuration(
  start: string | null | undefined,
  end: string | null | undefined,
): string {
  if (!start) return "—";
  const endTs = end ? new Date(end).getTime() : Date.now();
  return formatDurationMs(endTs - new Date(start).getTime());
}

/**
 * Format a duration in milliseconds with human-friendly units.
 */
export function formatDurationMs(ms: number): string {
  if (ms < 0) return "0ms";
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(2)}s`;
  if (ms < 3_600_000) {
    return `${Math.floor(ms / 60_000)}m ${Math.floor((ms % 60_000) / 1000)}s`;
  }
  return `${Math.floor(ms / 3_600_000)}h ${Math.floor((ms % 3_600_000) / 60_000)}m`;
}

/**
 * Shorten a fully-qualified Elixir module to just the leaf module name.
 */
export function shortModule(fqn: string | null | undefined): string {
  if (!fqn) return "—";
  const parts = fqn.split(".");
  return parts[parts.length - 1] || fqn;
}

/**
 * Parse the current URL's query string into a plain object. Falls back to
 * an empty object if the query string is absent. Used by the React-side
 * router when it needs to carry deep-link state like `?step=foo&attempt=2`.
 */
export function parseQueryString(search: string): Record<string, string> {
  if (!search || search === "?") return {};
  const params = new URLSearchParams(search.startsWith("?") ? search.slice(1) : search);
  const out: Record<string, string> = {};
  params.forEach((value, key) => {
    out[key] = value;
  });
  return out;
}

/**
 * Build a query-string suffix (including leading "?") from a map, omitting
 * empty/undefined entries. Returns an empty string when nothing to encode.
 */
export function buildQueryString(params: Record<string, string | null | undefined>): string {
  const entries = Object.entries(params).filter(
    ([, v]) => v !== undefined && v !== null && v !== "",
  );
  if (entries.length === 0) return "";
  const encoded = entries
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
    .join("&");
  return `?${encoded}`;
}
