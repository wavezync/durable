/**
 * QuerySuggest LV hook — suggestions under the Runs query bar while typing.
 *
 * The server puts what can be suggested on the form as `data-suggest`
 * (filter keys, and values for the keys with a known set: workflow, status,
 * schedule, since). Everything else happens here, with no round trip:
 *
 *   - empty / bare word  → the keys it starts (Tab completes the first), and
 *                          values that contain it ("pay" → workflow:process_payment)
 *   - `key:`             → that key's values, the first one highlighted
 *   - `step:` and others → a line on what to type
 *
 * ↑↓ move, Enter picks the highlighted suggestion (otherwise the form submits
 * the text as typed), Esc closes. Picking a key keeps typing; picking a value
 * submits, which turns the text into tags. The panel lives in a
 * `phx-update="ignore"` element, so LiveView patches don't touch it.
 */

interface Key {
  key: string;
  insert: string;
  hint: string;
}

interface Value {
  value: string;
  meta?: string;
  dot?: string;
}

interface Data {
  keys: Key[];
  help: Record<string, string>;
  values: Record<string, Value[]>;
}

type Item =
  | { kind: "key"; label: string; hint: string; insert: string }
  | {
      kind: "value";
      // Shown only when matches span several keys (a bare word).
      scope?: string;
      label: string;
      meta?: string;
      dot?: string;
      insert: string;
    }
  | { kind: "help"; text: string };

interface HookThis {
  el: HTMLFormElement;
  items: Item[];
  active: number;
  panel: HTMLElement;
  rows: HTMLElement[];
}

const MAX_CROSS_MATCHES = 4;

function input(form: HTMLFormElement): HTMLInputElement | null {
  return form.querySelector<HTMLInputElement>("input[name=draft]");
}

// The term being typed: everything after the last space, unless a quote is
// still open (then it's a phrase, and there's nothing to suggest).
function currentTerm(value: string): string | null {
  if ((value.match(/"/g) ?? []).length % 2 === 1) return null;
  return value.slice(value.lastIndexOf(" ") + 1);
}

function byMatch(values: Value[], needle: string): Value[] {
  const n = needle.toLowerCase();
  return values
    .filter((v) => v.value.toLowerCase().includes(n))
    .sort((a, b) => {
      const ap = a.value.toLowerCase().startsWith(n) ? 0 : 1;
      const bp = b.value.toLowerCase().startsWith(n) ? 0 : 1;
      return ap - bp;
    });
}

function suggest(term: string, data: Data): Item[] {
  const colon = term.indexOf(":");

  if (colon < 0) {
    const t = term.toLowerCase();
    if (t.startsWith("input.")) return help(data, "input.");

    const keys: Item[] = data.keys
      .filter((k) => k.key.startsWith(t))
      .map((k) => ({ kind: "key", label: k.insert, hint: k.hint, insert: k.insert }));

    const values: Item[] =
      t.length < 2
        ? []
        : Object.entries(data.values).flatMap(([scope, vs]) =>
            byMatch(vs, t)
              .slice(0, MAX_CROSS_MATCHES)
              .map((v) => ({ ...valueItem(scope, v, ""), scope })),
          );

    return [...keys, ...values];
  }

  const scope = term.slice(0, colon).toLowerCase();
  if (scope.startsWith("input.")) return help(data, "input.");

  const values = data.values[scope];
  if (!values || values.length === 0) return help(data, scope);

  // status takes several, comma separated: complete the last one.
  const rest = term.slice(colon + 1);
  const cut = scope === "status" ? rest.lastIndexOf(",") + 1 : 0;
  const head = rest.slice(0, cut);
  const matches = byMatch(values, rest.slice(cut));

  return matches.length > 0
    ? matches.map((v) => valueItem(scope, v, head))
    : [{ kind: "help", text: `No ${scope} matches “${rest.slice(cut)}”` }];
}

function valueItem(scope: string, v: Value, head: string): Item & { kind: "value" } {
  return {
    kind: "value",
    label: v.value,
    meta: v.meta,
    dot: v.dot,
    insert: `${scope}:${head}${v.value}`,
  };
}

function help(data: Data, key: string): Item[] {
  const text = data.help[key];
  return text ? [{ kind: "help", text }] : [];
}

function el(tag: string, className: string, text?: string): HTMLElement {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

const ROW = "flex h-8 cursor-pointer items-center gap-2.5 px-3 text-[13px]";
const ACTIVE = ["bg-accent", "text-accent-foreground"];

export const QuerySuggest = {
  mounted(this: HookThis) {
    this.items = [];
    this.active = -1;
    this.rows = [];
    this.panel = this.el.querySelector<HTMLElement>("[data-suggest-panel]") as HTMLElement;

    const isDraft = (e: Event) => e.target instanceof HTMLInputElement && e.target.name === "draft";

    this.el.addEventListener("input", (e) => {
      if (isDraft(e)) refresh(this);
    });
    this.el.addEventListener("focusin", (e) => {
      if (isDraft(e)) refresh(this);
    });
    // Reopen after Esc: the field kept focus, so focusin won't fire again.
    this.el.addEventListener("click", (e) => {
      if (isDraft(e) && this.items.length === 0) refresh(this);
    });
    this.el.addEventListener("focusout", (e) => {
      if (isDraft(e)) close(this);
    });
    this.el.addEventListener("keydown", (e) => {
      if (isDraft(e)) onKey(this, e);
    });

    // Keep focus in the field while clicking a suggestion.
    this.panel.addEventListener("mousedown", (e) => {
      e.preventDefault();
      const row = (e.target as HTMLElement).closest<HTMLElement>("[data-index]");
      if (row) pick(this, Number(row.dataset.index));
    });
    this.panel.addEventListener("mousemove", (e) => {
      const row = (e.target as HTMLElement).closest<HTMLElement>("[data-index]");
      if (row) setActive(this, Number(row.dataset.index));
    });
  },
};

function refresh(hook: HookThis) {
  const field = input(hook.el);
  const term = field ? currentTerm(field.value) : null;
  if (!field || term === null) return close(hook);

  const data = JSON.parse(hook.el.dataset.suggest ?? "{}") as Data;
  hook.items = suggest(term, data);
  // Completing a value: the best match is a keypress away. A bare word isn't
  // highlighted, so Enter still searches for it as typed.
  hook.active = term.includes(":") ? hook.items.findIndex((i) => i.kind === "value") : -1;
  render(hook, field);
}

function close(hook: HookThis) {
  hook.items = [];
  hook.active = -1;
  hook.rows = [];
  hook.panel.replaceChildren();
  const field = input(hook.el);
  field?.setAttribute("aria-expanded", "false");
  field?.removeAttribute("aria-activedescendant");
}

function render(hook: HookThis, field: HTMLInputElement) {
  if (hook.items.length === 0) return close(hook);

  const listId = hook.panel.id;
  const box = el(
    "div",
    "absolute inset-x-0 top-[calc(100%+4px)] z-30 overflow-hidden rounded-lg border border-border bg-popover text-popover-foreground shadow-lg",
  );
  const list = el("ul", "thin-scroll max-h-72 overflow-auto py-1");
  list.setAttribute("role", "listbox");
  list.setAttribute("aria-label", "Filter suggestions");

  hook.rows = hook.items.map((item, i) => {
    if (item.kind === "help") {
      const li = el("li", "px-3 py-2 text-xs text-muted-foreground", item.text);
      li.setAttribute("role", "presentation");
      return li;
    }

    const li = el("li", ROW);
    li.id = `${listId}-${i}`;
    li.dataset.index = String(i);
    li.setAttribute("role", "option");

    if (item.kind === "key") {
      li.append(
        el("span", "w-20 shrink-0 font-mono text-xs text-foreground", item.label),
        el("span", "truncate text-xs text-muted-foreground", item.hint),
      );
    } else {
      if (item.scope) {
        li.append(
          el(
            "span",
            "shrink-0 rounded-[4px] border border-border bg-secondary px-1.5 py-px text-[11px] text-muted-foreground",
            item.scope,
          ),
        );
      }
      if (item.dot) li.append(el("span", `st-dot st-${item.dot}`));
      li.append(el("span", "truncate font-mono text-xs text-foreground", item.label));
      if (item.meta)
        li.append(el("span", "ml-auto shrink-0 text-[11px] text-muted-foreground", item.meta));
    }
    return li;
  });

  list.append(...hook.rows);
  box.append(
    list,
    el(
      "div",
      "flex gap-3 border-t border-border px-3 py-1.5 text-[11px] text-muted-foreground",
      "↑↓ move · tab complete · ↵ add · esc close",
    ),
  );
  hook.panel.replaceChildren(box);
  field.setAttribute("aria-expanded", "true");
  setActive(hook, hook.active);
}

function setActive(hook: HookThis, index: number) {
  hook.rows[hook.active]?.classList.remove(...ACTIVE);
  hook.active = index;
  const row = hook.rows[index];
  const field = input(hook.el);

  if (row) {
    row.classList.add(...ACTIVE);
    row.scrollIntoView({ block: "nearest" });
    field?.setAttribute("aria-activedescendant", row.id);
  } else {
    field?.removeAttribute("aria-activedescendant");
  }
}

function selectable(hook: HookThis): number[] {
  return hook.items.flatMap((item, i) => (item.kind === "help" ? [] : [i]));
}

function move(hook: HookThis, step: 1 | -1) {
  const options = selectable(hook);
  if (options.length === 0) return;
  const at = options.indexOf(hook.active);
  const next =
    at < 0 ? (step === 1 ? 0 : options.length - 1) : (at + step + options.length) % options.length;
  setActive(hook, options[next]);
}

function onKey(hook: HookThis, e: KeyboardEvent) {
  const open = hook.items.length > 0;
  const field = e.target as HTMLInputElement;

  switch (e.key) {
    case "ArrowDown":
    case "ArrowUp":
      e.preventDefault();
      if (!open) refresh(hook);
      move(hook, e.key === "ArrowDown" ? 1 : -1);
      break;
    case "Enter":
      if (open && hook.active >= 0) {
        e.preventDefault();
        pick(hook, hook.active);
      } else {
        close(hook);
      }
      break;
    case "Tab": {
      // Completes only a started term; on an empty field Tab moves focus.
      const first = hook.active >= 0 ? hook.active : selectable(hook)[0];
      if (open && first !== undefined && currentTerm(field.value)) {
        e.preventDefault();
        pick(hook, first);
      }
      break;
    }
    case "Escape":
      if (open) {
        e.preventDefault();
        e.stopPropagation();
        close(hook);
      }
      break;
  }
}

function pick(hook: HookThis, index: number) {
  const item = hook.items[index];
  const field = input(hook.el);
  if (!item || item.kind === "help" || !field) return;

  field.value = field.value.slice(0, field.value.lastIndexOf(" ") + 1) + item.insert;

  if (item.kind === "key") {
    field.focus();
    field.setSelectionRange(field.value.length, field.value.length);
    refresh(hook);
  } else {
    close(hook);
    hook.el.requestSubmit();
  }
}
