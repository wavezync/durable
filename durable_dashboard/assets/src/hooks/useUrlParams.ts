import { useMemo } from "react";

/**
 * Derive typed filter/pagination state from the raw `viewParams` string map.
 *
 * This is a pure derivation (useMemo) — no useState, no useEffect. Changing
 * a filter calls `navigate()` which updates viewParams via the URL, which
 * triggers a re-render, which re-derives the typed state here.
 *
 * Number-typed defaults are parsed with parseInt; everything else stays as
 * a string. Missing keys fall back to the provided defaults.
 *
 * @example
 * ```ts
 * const { status, search, page } = useUrlParams(viewParams, {
 *   status: "",
 *   search: "",
 *   page: 1,
 * });
 * ```
 */
export function useUrlParams<T extends Record<string, string | number>>(
  viewParams: Record<string, string>,
  defaults: T,
): T {
  return useMemo(() => {
    const result = { ...defaults };
    for (const key of Object.keys(defaults)) {
      const raw = viewParams[key];
      if (raw === undefined || raw === "") continue;

      const defaultVal = defaults[key];
      if (typeof defaultVal === "number") {
        const parsed = Number.parseInt(raw, 10);
        if (!Number.isNaN(parsed)) {
          (result as Record<string, string | number>)[key] = parsed;
        }
      } else {
        (result as Record<string, string | number>)[key] = raw;
      }
    }
    return result;
  }, [viewParams, defaults]);
}
