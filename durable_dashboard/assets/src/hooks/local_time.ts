/**
 * Local time rendering — show UTC timestamps in the viewer's own timezone.
 *
 * The server can only emit UTC (it has no idea where the viewer is), so a raw
 * `2026-06-23T11:39:40.328499Z` is ambiguous and hard to read. The server
 * renders `<time data-ts="<iso>" data-format="...">` with a UTC fallback as
 * its text (legible even without JS); these helpers rewrite the text to the
 * browser's locale + timezone and add a full-detail tooltip.
 *
 * Wired through LiveSocket's `dom` callbacks in `main.ts` rather than a
 * per-element hook, so timestamps inside lists don't each need a unique id:
 * one pass localizes the initial render, `onNodeAdded` catches streamed-in
 * nodes, and `onBeforeElUpdated` re-localizes elements LiveView re-renders.
 *
 * Formats (via `data-format`):
 *   - "time"      11:39:40.328           local time of day, ms precision
 *   - "datetime"  Jun 23, 2026, 11:39:40 local date + time
 *   - "date"      Jun 23, 2026
 */

type Fmt = "time" | "datetime" | "date";

/** Localize a single `<time data-ts>` element in place. */
export function localizeTime(el: HTMLElement): void {
  const iso = el.dataset.ts;
  if (!iso) return;

  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return;

  // Relative elements ("2m ago" / "in 2h") keep their server-computed text;
  // only the hover tooltip is localized to the viewer's timezone so the exact
  // moment is legible without exposing a confusing UTC string.
  if (el.dataset.rel) {
    el.setAttribute("title", format(d, "datetime"));
    return;
  }

  el.textContent = format(d, (el.dataset.format as Fmt) || "datetime");
  el.setAttribute("title", d.toString());
}

/** Localize every `<time data-ts>` under (and including) `root`. */
export function localizeTimes(root: ParentNode | Element): void {
  if (root instanceof HTMLElement && root.matches("time[data-ts]")) {
    localizeTime(root);
  }
  for (const el of root.querySelectorAll<HTMLElement>("time[data-ts]")) {
    localizeTime(el);
  }
}

function format(d: Date, fmt: Fmt): string {
  switch (fmt) {
    case "time":
      return d.toLocaleTimeString([], {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        fractionalSecondDigits: 3,
        hour12: false,
      });
    case "date":
      return d.toLocaleDateString([], { year: "numeric", month: "short", day: "numeric" });
    default:
      return d.toLocaleString([], {
        year: "numeric",
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
      });
  }
}
