/**
 * Tooltips — one styled tooltip for the whole dashboard (`DESIGN.md`
 * "Tooltips"). Any element with `data-tip` gets one, and so does every
 * `<time data-ts>` (its local time, how long ago, and UTC):
 *
 *   data-tip        the body; "\n" starts a new line
 *   data-tip-title  a short heading above it
 *   data-tip-meta   a mono footnote: an id, a raw value, a UTC time
 *   data-tip-kbd    a keyboard shortcut, shown beside the title
 *   data-tip-side   "bottom" to prefer below (default: above)
 *
 * Delegated listeners on `document`, so LiveView patches need no hooks. It
 * opens after a short hover (instantly while another just closed) or on
 * keyboard focus; Esc, a click, or scrolling closes it. It is `position:
 * fixed` on `<body>`, so `overflow: hidden` containers can't clip it, and it
 * re-reads its trigger while open, so a value that updates live stays current.
 */

const SELECTOR = "[data-tip], time[data-ts]";
const OPEN_MS = 350;
const WARM_MS = 600;
const EDGE = 8;
const GAP = 8;

type Trigger = HTMLElement | SVGElement;

interface Parts {
  title?: string;
  body?: string;
  meta?: string;
  kbd?: string;
}

let tip: HTMLElement;
let current: Trigger | null = null;
let pending: Trigger | null = null;
let openTimer = 0;
let watchTimer = 0;
let lastClosed = 0;

export function initTooltips(): void {
  tip = document.createElement("div");
  tip.id = "dd-tooltip";
  tip.className = "dd-tip";
  tip.setAttribute("role", "tooltip");
  document.body.append(tip);

  document.addEventListener("pointerover", (e) => {
    if (e.pointerType === "touch") return;
    const target = triggerOf(e.target);
    if (target === current || target === pending) return;
    if (target) schedule(target);
    else close();
  });
  document.addEventListener("pointerout", (e) => {
    if (e.relatedTarget === null) close();
  });
  document.addEventListener("focusin", (e) => {
    const target = triggerOf(e.target);
    if (target && (target as HTMLElement).matches?.(":focus-visible")) open(target);
  });
  document.addEventListener("focusout", () => close());
  document.addEventListener("pointerdown", () => close(), true);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") close();
  });
  window.addEventListener("scroll", () => close(), true);
}

function triggerOf(node: EventTarget | null): Trigger | null {
  return node instanceof Element ? (node.closest(SELECTOR) as Trigger | null) : null;
}

function schedule(target: Trigger) {
  window.clearTimeout(openTimer);
  pending = target;
  const warm = current !== null || performance.now() - lastClosed < WARM_MS;
  if (current) hide();
  openTimer = window.setTimeout(() => open(target), warm ? 0 : OPEN_MS);
}

function open(target: Trigger) {
  window.clearTimeout(openTimer);
  pending = null;
  const parts = partsOf(target);
  if (!parts) return close();

  current = target;
  render(parts);
  place(target);
  tip.dataset.open = "";
  target.setAttribute("aria-describedby", tip.id);

  window.clearInterval(watchTimer);
  watchTimer = window.setInterval(() => {
    if (!current?.isConnected) return close();
    const next = partsOf(current);
    if (next) {
      render(next);
      place(current);
    }
  }, 500);
}

function close() {
  window.clearTimeout(openTimer);
  pending = null;
  if (!current) return;
  hide();
  lastClosed = performance.now();
}

function hide() {
  window.clearInterval(watchTimer);
  current?.removeAttribute("aria-describedby");
  current = null;
  delete tip.dataset.open;
}

function partsOf(el: Trigger): Parts | null {
  const d = el.dataset;
  if (d.tip) return { title: d.tipTitle, body: d.tip, meta: d.tipMeta, kbd: d.tipKbd };
  if (d.ts) return timeParts(d.ts);
  return null;
}

function render(parts: Parts) {
  const nodes: Node[] = [];

  if (parts.title || parts.kbd) {
    const head = div("dd-tip-title", parts.title ?? "");
    if (parts.kbd) head.append(div("dd-tip-kbd", parts.kbd, "kbd"));
    nodes.push(head);
  }
  if (parts.body) nodes.push(div("dd-tip-body", parts.body));
  if (parts.meta) nodes.push(div("dd-tip-meta", parts.meta));
  nodes.push(div("dd-tip-arrow", ""));

  tip.replaceChildren(...nodes);
}

function div(className: string, text: string, tag = "div"): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  node.textContent = text;
  return node;
}

function place(target: Trigger) {
  const r = target.getBoundingClientRect();
  const { width, height } = tip.getBoundingClientRect();

  let side = target.dataset.tipSide === "bottom" ? "bottom" : "top";
  if (side === "top" && r.top - height - GAP < EDGE) side = "bottom";
  if (side === "bottom" && r.bottom + height + GAP > window.innerHeight - EDGE) side = "top";

  const center = r.left + r.width / 2;
  const left = clamp(center - width / 2, EDGE, window.innerWidth - width - EDGE);
  const top = side === "top" ? r.top - height - GAP : r.bottom + GAP;

  tip.dataset.side = side;
  tip.style.left = `${Math.round(left)}px`;
  tip.style.top = `${Math.round(top)}px`;
  tip.style.setProperty("--arrow-x", `${Math.round(clamp(center - left, 12, width - 12))}px`);
}

function clamp(n: number, min: number, max: number): number {
  return Math.min(Math.max(n, min), Math.max(min, max));
}

// ---- Times ------------------------------------------------------------------

const relative = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });

const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [
  ["year", 31_536_000],
  ["month", 2_592_000],
  ["week", 604_800],
  ["day", 86_400],
  ["hour", 3_600],
  ["minute", 60],
  ["second", 1],
];

function timeParts(iso: string): Parts | null {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;

  const seconds = Math.round((d.getTime() - Date.now()) / 1000);
  const [unit, size] = UNITS.find(([, s]) => Math.abs(seconds) >= s) ?? ["second", 1];
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;

  return {
    title: d.toLocaleString([], {
      weekday: "short",
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hour12: false,
    }),
    body: `${relative.format(Math.round(seconds / size), unit)} · your time (${zone})`,
    meta: `${d.toISOString().replace("T", " ").replace("Z", "")} UTC`,
  };
}
