# Durable Dashboard — Design Language

This document is the source of truth for every visual decision in the Durable
Dashboard. Read it before adding or modifying any UI surface. If a decision
isn't here, codify it here first; don't make it twice.

> **Audience.** Any contributor (human or AI assistant) shipping a UI piece.
> **Goal.** A new contributor can answer *"how do I render a list of executions?"*
> after five minutes with this doc.

## 1. Philosophy

Durable Dashboard is a **workflow-engine console** — a control room. The
aesthetic priorities, in order:

1. **Answers before data.** Every screen leads with the thing an operator
   came for (what failed, why, what to do) and puts the action next to it.
   A list that can't act on its rows is unfinished.
2. **Data density.** Operators read this all day. Hairlines, not boxes;
   tables, not cards; numbers in mono.
3. **Dark-first.** Dark is the default; light is a peer, checked on every
   change.
4. **Restrained color.** Color carries meaning — status, or "live". Never
   decoration, never branding.
5. **Shape before color.** Every status reads as shape + color + label, so
   nothing depends on telling hues apart.

**Calibrated against** Inngest (trace + inspector, metrics), Temporal Web
(density), Linear (type rhythm, ⌘K). The reference mockups live on the
"Durable Dashboard v1" design canvas; this file is the source of truth.

## 2. Foundations

### 2.1 Colors

Every color is a CSS custom property in `assets/src/index.css`, paired for
light and dark, exposed to Tailwind through `@theme inline` (`bg-card`,
`text-success`, `border-input`, …).

| Token                 | Light     | Dark      | Use                                               |
| --------------------- | --------- | --------- | ------------------------------------------------- |
| `--background`        | `#f5f6f8` | `#0b0d10` | App canvas (ink)                                  |
| `--card`              | `#ffffff` | `#111418` | Panels, sidebar, tables                           |
| `--popover`           | `#ffffff` | `#181c22` | Floating surfaces                                 |
| `--secondary`/`--muted` | `#eef0f3` | `#181c22` / `#161a20` | Raised chips, selected nav, pill grounds |
| `--accent`            | `#f0f2f5` | `#1a1f26` | Hover backgrounds                                 |
| `--foreground`        | `#0f1217` | `#e6e8eb` | Primary text                                      |
| `--subtle-foreground` | `#4a5260` | `#a6adb7` | Secondary text, nav items                         |
| `--muted-foreground`  | `#646c78` | `#8b939e` | Captions, labels, meta                            |
| `--border`            | `#e3e6ea` | `#22272e` | Hairlines                                         |
| `--input`             | `#d2d7dd` | `#2e343c` | Control borders                                   |
| `--primary`           | `#1a5fd0` | `#4c8dff` | **Live**: running, links, focus, active nav icon  |
| `--success`           | `#00766a` | `#2bb3a3` | Completed (teal)                                  |
| `--destructive`       | `#b33a25` | `#f2785b` | Failed (red-orange)                               |
| `--warning`           | `#8a5800` | `#e9b458` | Waiting, saturated                                |
| `--comp`              | `#5e45c8` | `#b3a6f5` | Compensation / rolled back (violet)               |
| `--off`               | `#8a929c` | `#6b7380` | Pending, cancelled                                |
| `--chart-ok` / `--chart-fail` | `#00897b` / `#d4462e` | `#23a094` / `#e8603f` | Chart marks for completed / failed |
| `--chart-1…4`         | dataviz categorical slots 1–4                      | | Series that aren't statuses |

**Why teal and red-orange.** Green/red failed the color-blind separation
check (deutan ΔE 5.7). Teal/red-orange passes in both themes (ΔE ≥ 12 dark,
≥ 9 light) — re-run the dataviz validator before changing either.

**Contrast.** Every text color above clears WCAG AA (4.5:1) on its own 13%
tint, which is how pills and chips are drawn. Don't fade text with opacity
modifiers (`text-muted-foreground/60`) — pick the right token instead.

**Primary is "live".** Blue means *now / running / you are here / a link*.
Primary *buttons* are ink-inverted (`bg-foreground text-background`), not
blue, so the accent stays a signal.

#### Forbidden

- Hex or OKLCH literals in components. Use tokens (charts too: `var(--chart-ok)`).
- Tailwind palette colors (`text-blue-500`).
- Opacity-faded text.

### 2.2 Typography

- `--font-sans` = **IBM Plex Sans** (400/500/600), `--font-mono` = **IBM Plex
  Mono** (400/500), loaded from Google Fonts in `Layouts.root/1`.
- Body is 13px / 1.45.
- **Mono is for machine facts only**: ids, numbers, durations, timestamps,
  code, JSON, step names. Never for labels.
- **Labels are sentence case.** No uppercase, no letter-spacing, no mono
  eyebrows. `<.label>` is a 12px muted caption; column headers are 12px
  medium muted.

| Size        | Use                                                  |
| ----------- | ---------------------------------------------------- |
| 11px        | Axis ticks, kbd hints, dense chips                   |
| 12px (`text-xs`) | Labels, captions, column headers, pills, meta   |
| 13px        | Default body, table cells, buttons, nav              |
| 14px (`text-sm`) | Panel titles (semibold)                         |
| 16px (`text-base`) | Section heading (h2)                          |
| 20px        | Page title (h1), semibold, −0.01em                   |
| 22–24px mono | KPI values                                          |

### 2.3 Spacing

4px grid. Page gutter `px-7`, panel padding 16px, table cell padding
`px-4`, rows 40–46px. Gaps: 8px between controls, 16px between panels.

### 2.4 Radius

| Use                         | Radius |
| --------------------------- | ------ |
| Chips, badges, kbd          | 4–5px  |
| Buttons, inputs, pills, nav | 7px (`rounded-md`) |
| Panels, cards, tables       | 10px   |

### 2.5 Borders & elevation

1px hairlines (`border-border`) between rows and around panels; control
borders use `border-input`. **No card shadows** — panels separate by surface
step (ink → card) and hairline. Popovers and menus keep `shadow-pop` because
they float.

## 3. Motion

- **`st-beat`** — the running mark's pulse (1.6s). Only on live things.
- **`dash-flow`** — running edges in the graph.
- **`animate-pulse`** — skeletons only.

Hover/focus transitions ≤ 150ms (`transition-colors`). No layout animation.
`prefers-reduced-motion` disables all of it from one media query.

## 4. Status semantics — canonical table

Status is **shape + color + label**, everywhere — `<.status_pill>`,
`<.status_dot>`, trace rows, charts, graph nodes. Shapes are CSS classes
`st-dot st-<status>` in `index.css`.

| Status                | Shape            | Color          | Label                |
| --------------------- | ---------------- | -------------- | -------------------- |
| `pending`             | dashed ring      | `off`          | Pending              |
| `running`             | disc, pulsing    | `primary`      | Running              |
| `waiting`             | hollow ring      | `warning`      | Waiting              |
| `completed`           | disc             | `success`      | Completed            |
| `failed`              | diamond          | `destructive`  | Failed               |
| `cancelled`           | dash             | `off`          | Cancelled            |
| `compensating`        | disc, pulsing    | `comp`         | Compensating         |
| `compensated`         | disc             | `comp`         | Compensated          |
| `compensation_failed` | diamond          | `destructive`  | Compensation failed  |
| `scheduled`           | dashed ring      | `off`          | Scheduled            |
| `timeout`             | diamond          | `destructive`  | Timed out            |
| `paused` (queue)      | hollow ring      | `warning`      | Paused               |
| `idle` (queue)        | dashed ring      | `off`          | Idle                 |
| `alive` (node)        | disc             | `success`      | Alive                |
| `missing` (node)      | diamond          | `destructive`  | Missing              |

To add a status: update this table, `Core.status_meta/1`, the `st-*` class in
`index.css`, and the React node tone helpers. If they disagree, the table
wins.

## 5. Component primitives — `Components.Core` API contract

Stateless visual primitives live in
`lib/durable_dashboard/components/core.ex`. Every primitive listed here is
already implemented; see the source for the full attr list.

### `<.button>`

Variants: `primary` (ink-inverted — the one main action on a surface) |
`secondary` (card ground, `border-input`; the default) | `ghost` |
`destructive` (outlined, red-orange text — never a filled red slab) | `link`.
Sizes: `sm` (26h) | `md` (30h, default) | `lg` (40h).

```heex
<.button kind="primary" type="submit">Save</.button>
<.button kind="ghost" size="sm" phx-click="cancel">Cancel</.button>
```

**Don't** roll your own `<button class="...">`. If a variant doesn't fit,
add the variant here.

### `<.icon_button>`

Square, icon-only — for toolbar controls (theme toggle, pagination
chevrons, sheet close, table row actions). Variants: `default`
(bordered card surface) | `ghost` (no border). Sizes: `sm` (28) | `md`
(32). Always pass `aria-label` since there is no text.

```heex
<.icon_button icon="x-mark" aria-label="Close" phx-click="close" />
<.icon_button kind="ghost" size="sm" icon="chevron-right" aria-label="Next" />
```

Use over a raw `<button>` for any single-icon toolbar control. Composite
controls (e.g. icon + label + kbd hint) and two-icon swaps (e.g. moon ⇄
sun) keep raw markup with an exemption comment pointing at this primitive.

### `<.badge>`

Small sentence-case chip (11px, 5px radius). Variants: `default | primary |
success | warning | destructive | info | muted`. Use for tags and counts.
**Don't** use for run status — that's `<.status_pill>`.

### `<.status_pill>`

Run / step state chip: the §4 shape mark + sentence-case label on a 13%
tint of the status color. Reads `status` (atom or string).

```heex
<.status_pill status={execution.status} />
```

### `<.status_dot>`

The bare §4 shape mark, for places a pill is too heavy: trace rows, feeds,
graph nodes, the sidebar's live indicator. Always next to a label or name.

**Don't** use for arbitrary tags; the colors carry meaning.

### `<.card>`

Single bordered surface; padding variants `none | sm | md | lg`. Optional
`title` and `action` slots render a 48 h header strip.

**Don't** nest cards. If you feel the urge, you want a sub-section
heading, not another card.

### `<.heading>`

`level={1 | 2 | 3}` with optional `subtitle`. h1 = page, h2 = section,
h3 = subsection. Don't use raw `<h1>`/`<h2>` tags except inside the
component.

### `<.code>`

Inline code chip — IDs, JSON snippets, durations, queue names. Pass
`copy={"the text"}` to append a hover-revealed `<.copy_button>` (used on the
execution id, settings config values).

### `<.copy_button>`

A small ghost clipboard button that copies `text` to the clipboard and flashes
a check (clipboard ⇄ check via `.copy-btn[data-copied]` CSS). It carries
`data-copy` and is driven by **one delegated listener** (`hooks/copy.ts`, wired
in `main.ts`) — no `phx-hook`/`id` per button. Reveal it on hover of its host
(`opacity-0 group-hover/…:opacity-100`), never always-on (DENSITY §8). Already
baked into `<.json>` (top-right of every JSON block) and `<.code copy={…}>`;
drop it beside any other copy-worthy value rather than hand-rolling a button.

### `<.kbd>`

Keyboard hint inside command palette / tooltips.

### `<.relative_time at={dt}>`

Humanized "2m ago" (past) or "in 2h" (future) for durations. Always use this;
never hand-format times. It is sign-aware — a future timestamp (e.g. a
schedule's next run) reads "in …", never "just now". Its tooltip (`tooltip.ts`)
shows the moment in the viewer's zone, how long ago, and UTC. It sets tabular
figures in the **surrounding** font, not mono — it usually sits inside a
sentence ("asked 2m ago"), where a mono space reads as a gap. Use
`local_time` instead when the user needs the exact moment shown inline.

### `<.local_time at={dt} format="time|datetime|date">`

For **absolute** timestamps the user reads. The server only knows UTC, so a
raw ISO string is ambiguous; this emits a `<time data-ts data-format>` with
a UTC fallback as its text, and the client rewrites it to the viewer's
timezone (`assets/src/hooks/local_time.ts`, wired via LiveSocket's `dom`
callbacks — no per-element id needed). Never print a bare UTC timestamp;
use `relative_time` for "ago" durations and `local_time` for the moment.

### `<.label>` and `<.field key="…">`

The canonical "this is a label, not a value" treatment: a 12px
sentence-case caption in `text-muted-foreground`. Use `<.label>` for every
field name, column header and metadata key. Never uppercase, never mono.

```heex
<.label>level</.label>
<.label class="text-destructive">error</.label>
```

`<.field key="level">info</.field>` is the key/value detail row built on
`<.label>`: a fixed-width label column beside a monospace value. Use inside
a `<dl>` for aligned metadata tables (step inspector, log detail, etc.).
Labels read as labels and values as values — keys are never lowercase plain
text indistinguishable from their values.

### `<.skeleton>`, `<.empty_state>`, `<.error_state>`

These three carry **distinct semantics** — don't substitute one for
another:

- `skeleton` — data is *loading*. Render shape-matching placeholders.
- `empty_state` — data is *fetched and there's nothing*. Friendly tone,
  optional CTA via `:action` slot.
- `error_state` — *something broke*. Destructive icon, optional `reason`
  for the error message, optional retry action via `:action` slot.

Every list LV must ship all three. CI may grep for this in the future.

### `<.icon name="..." />`

Curated set of heroicons-mini paths. Default class is `size-4` (16 px).
To add an icon:

1. Pull the SVG path from heroicons.com (mini variant, solid/outline).
2. Add a new `def icon(%{name: "..."} = assigns)` clause to `core.ex`.
3. Always use `viewBox="0 0 20 20"` and `fill="currentColor"`.

React-side may use `lucide-react` (already imported in the sidebar).
Same naming conventions apply. Always `className="size-4"` default; never
inline `width`/`height`.

### Adding a primitive

Stateless and visual → `Components.Core`. Stateful or composes others →
its own `Phoenix.LiveComponent` module under
`lib/durable_dashboard/components/<area>/`.

**Document the new entry in this file before merging.**

## 6. Composition patterns

### Page shell

```
<Sidebar />  <main class="px-7 pt-5 pb-10 max-w-[1440px] mx-auto">
               <Breadcrumb :if={deep page} />
               <PageHeader />
               <PageContent />
             </main>
```

- **No topbar.** The sidebar carries everything global: brand, ⌘K, nav,
  live indicator, version, GitHub and theme toggle.
- **Sidebar** (232px, `bg-card`, hairline right border):
  - Brand: the three-step mark (persisted steps rising) + "Durable" over the
    schema name.
  - ⌘K button ("Jump to run, workflow…").
  - Nav in three intent groups under plain sentence-case captions —
    **Observe** (Overview, Runs, Workflows), **Operate** (Inbox, Queues &
    nodes, Schedules), **Instrument** (Telemetry, Settings). Active item:
    `bg-secondary` with the icon in the live blue.
  - Inbox carries an amber count pill when inputs are waiting on a person
    (`DurableDashboard.InboxBadge`, an `on_mount` hook every page gets; it
    consumes input events unless a page assigns `wants_input_events`).
  - Footer: running mark + "Live · version", GitHub, theme toggle.
- **Breadcrumbs** render above the heading only on pages more than one
  level deep.

### Page header

```heex
<header class="flex items-end justify-between gap-3 mb-4">
  <.heading level={1} subtitle={...}>Workflows</.heading>
  <div class="flex items-center gap-2"> <.button>...</.button> </div>
</header>
```

Subtitle = relative time, scope context, or counts. Never marketing copy.

### View switch / tab strip

A row of `patch` links over a hairline bottom border; the active one gets a
2px `border-primary` underline and `text-foreground`, the rest
`text-subtle-foreground`. A count rides in a `bg-secondary` mono pill
(Inbox: "Needs input 22"). The active view lives in the URL (`?tab=` /
`/:view`) so it's shareable.

### Command palette (⌘K)

`Components.Command.CommandPalette` — rendered **once** by `Layouts.app`
(needs `base_path` + `durable`), opened by ⌘K or the sidebar "Jump to run, workflow…"
button. It is the canonical global jumper (§9) and follows Linear's
command-palette discipline (§1).

- **Searches the console's nouns, grouped** under `<.label>` section
  headers: **Go to** (page routes, plus the Runs saved views once you type —
  "fail" → Failed runs), **Workflows** (→ the workflow's page),
  **Schedules** (→ the schedule's page, with its cadence and On/Off),
  **Recent runs** / **Runs** (→ the run). Grouping carries result *type*,
  so rows don't need per-row type chips. Icons are the sidebar's own.
- **Snapshot on open, filter in memory** — workflows, schedules and the
  newest runs are fetched once on `palette:open`. The one exception: a
  query shaped like a run id (4+ hex characters) is looked up in the
  database by prefix, so any run is found, not only the recent ones. The
  input is debounced (100 ms). Degrades to page routes when `durable` is
  `nil`.
- **Selection is marked in the live blue**
  plus a `↵` hint that appears only on the selected row. Keyboard nav
  wraps across groups via a single flat selection index; hover selects.
- Row meta is restrained: workflow rows show run count + last-status
  pill, run rows show short id + status pill. Numbers are `text-numeric`.

### List / table row

- Tables are plain HEEx inside a `Charts.panel` (there is no table
  component — each page's columns are its own). 46 px rows, hairline
  `border-b border-border` between them, `hover:bg-accent`.
- **Column headers** are sentence case, `text-xs font-medium
  text-muted-foreground`, with `border-y` framing the header row. Numbers
  right-aligned and mono; never uppercase or letter-spaced.
- The row's primary cell links to the noun's page (run, workflow); actions
  sit in a last, right-aligned column as `size="sm"` buttons, rendered only
  when the viewer's access allows them (§12 Access).

### Tooltips

One tooltip for the whole dashboard (`assets/src/tooltip.ts`): it opens after
a 350 ms hover (instantly while another just closed) or on keyboard focus,
and Esc, a click or scrolling closes it. It sits above its trigger (below when
there's no room), is clamped to the viewport, and is `position: fixed` on
`<body>` — a table or card with `overflow: hidden` can't clip it. While open
it re-reads its trigger, so a live value stays current.

- **Markup.** `data-tip` is the body (`\n` for a new line); `data-tip-title`
  a heading of a few words; `data-tip-meta` a mono footnote under a rule —
  ids, raw values, UTC; `data-tip-kbd` a shortcut beside the title;
  `data-tip-side="bottom"` to prefer below. Works on SVG elements too.
  **Never `title=`** — the browser's tooltip is unstyled, slow and can't be
  themed. Every `<time data-ts>` (`relative_time`, `local_time`) gets one
  for free: the moment in the viewer's zone, how long ago, and UTC.
- **Status pills explain themselves** (`Core.status_help/1`); pass `tip=` to
  say something more specific, `tip={false}` for none.
- **Say what the screen doesn't.** A tooltip that repeats its label is noise.
  Name what a number means, how it's counted and over what window
  (title "Failure rate", body "failed ÷ finished runs · last 24h"); give the
  exact value behind a rounded one (1.2k → 1,234 · "3h 7m" → its start and
  end); the full text behind a truncated one; the meaning of a symbol or an
  abbreviation (↻, p95, "gave up"); the action and shortcut of an icon-only
  button; why a control is disabled.
- **Short.** Title ≤ 4 words; body ≤ 2 lines of fragments joined by " · ",
  no closing full stop; numbers formatted as on screen (`Format`). Nothing
  interactive inside — tooltips ignore the pointer.
- **Charts.** Every data mark has one: a bar or a bucket shows its time span
  as the title and each series' value as a line. Line and area charts take
  hover on a full-height column per bucket, wider than the mark, and draw a
  guide line plus a dot on the hovered point (CSS `:hover`, no JS).

### Query bar

Filtering a list of the system's nouns (e.g. Runs) uses a **query bar**
(`Components.Data.ExecutionFilters`): one search field that holds every filter
in force as a **tag**, with the facet menus (Workflow, Status, Time) beside it.
It's the ops-console query builder (Linear / Datadog / GitHub).

- **Every filter is a tag.** A tag is `key` (muted, own cell) + value (mono)
  + ✕, `h-6` inside the `h-8` field; the field wraps when tags fill it. Facet
  tags come first in menu order, then one per search term (`RunSearch.tokens`),
  labelled by what the term searches (a bare word reads `error`, an id-shaped
  one `id`). A tag that can't be removed (the workflow on its own runs page)
  has no ✕. A status set a saved-view tab already names gets no tag — the tab
  shows it.
- **Type, then Enter.** The field is a draft: Enter turns it into tags (an
  `↵ add` hint shows while there's text); `workflow:`, `status:a,b` and
  `since:24h` become the facets the menus set; Backspace in an empty field
  removes the last tag; a ✕ at the field's end clears all. After a commit the
  field is re-keyed so it comes back empty and focused.
- **Suggestions while typing** (`QuerySuggest` hook, no round trip). On focus
  the field lists the filter keys with a line on each; a started word narrows
  them (Tab completes the first) and also offers values that contain it,
  tagged with their key ("pay" → `workflow process_payment · 272 runs`);
  after `key:` it lists that key's values — statuses with their dot — with the
  best match highlighted, or a line on what to type for free-text keys.
  ↑↓ move, Enter picks the highlight (with none, Enter adds the text as typed,
  so a bare word is never hijacked), Esc closes, clicking the field reopens.
  Picking a key keeps typing; picking a value adds the tag. The server sends
  the candidates as `data-suggest` JSON; the panel sits in a
  `phx-update="ignore"` element and is built with `textContent` only.
- **Menus never change width.** A menu trigger shows its label only — the
  value lives in the tag — and fills with `bg-accent` when set. Popovers open
  right-aligned (the menus sit at the bar's end), `bg-popover` + `shadow-lg`.
- **Pick the control to the data.** A facet over a *known finite set* (workflow
  names from `Query.list_workflows`) is a **searchable combobox**, never free
  text. Status is **multi-select**. Time is **relative presets + a custom UTC
  range** (→ the query's `:from`/`:to`).
- **URL is the source of truth.** The bar owns only transient UI state (which
  menu is open, combobox text, the field's revision); values live in the
  parent's query. Each change sends `{:execution_filters, patch}` to the parent
  LV, which merges, resets to page 1, and `push_patch`es.
- **Open state is server-side** (an `open_facet` assign), so a LiveView patch
  can't reset an open panel. Close via `phx-click-away` + `phx-key="Escape"`.
- **Active ≠ live.** Set menus and tags are neutral, never `--primary` — blue
  stays reserved for live/now/here (§2.1).

### Status readout (instrument cluster)

Aggregate counts (Overview's status KPIs, a workflow card's runs/failed/
waiting) render as a **segmented readout**, not a row of free-floating cards:
one panel with hairline-divided cells, so it reads like an instrument cluster.

- Draw the dividers with the **`gap-px` + `bg-border` trick** when the grid
  wraps responsively (container `bg-border`, cells `bg-card`, `gap-px`);
  use `divide-x divide-border` only for a fixed single row that never wraps.
- Numbers are **mono** (`text-numeric`) — they're machine facts. Labels use
  `<.label>`.
- **Restraint of color:** the dot carries status; only the counts that signal
  trouble light up (failed → destructive, waiting → warning, when `> 0`).
  Running pulses (`led-dot`). Everything else stays neutral, so the eye lands
  on what's wrong instead of a rainbow. No gradient glows.

### Detail sheet / drawer

`data-slot="sheet-content"` is styled centrally in `index.css`. **Don't**
override its background or backdrop-blur in the sheet itself.

### Run page (`WorkflowLive`)

One run, one page — header, banner, facts, then a view switch.

- **Header**: workflow name + status pill, short id, and the actions that
  fit the run's state: Cancel (live runs), Retry from step (failed),
  Rerun and Rerun with edited input (finished). Actions need operator
  access; errors render inline under the buttons (`role="alert"`).
- **Banner** says what happened in a sentence — "`charge_card` failed after
  3 attempts — <error line>", "Cancelled — <reason>. Steps that finished stay
  finished." — with "Show error" linking straight to the inspector pane, and
  for rolled-back runs, why Retry is off. No banner for a clean success.
- **Facts strip**: started, duration, queued for, attempts, trigger (and
  what triggered it), queue · node, child runs — one line, mono values.
- **Views**: Trace (default), Graph, Logs, Context, Family. URL:
  `/executions/:id/:view?step=&pane=`, so "this step's error" is a link.

### Trace waterfall (`DurableDashboard.Trace`)

One row per step — the run's own plus its direct children's (parallel
branches, called workflows) indented one level — on the run's wall-clock
window, Honeycomb/Jaeger style. Each **attempt is a bar**; the gap between
attempts is drawn and named: **backoff** after a failure, **wait** after a
suspension. Compensations sort last in their own lane. Bars have a 6 px
floor so a 1 ms step stays clickable. While the run is live the window
ends at `now` and the page ticks every 500 ms.

Clicking a row opens the **inspector** beside the waterfall with panes:
Error, Input, Output, Logs, Attempts. The error pane's tab is
destructive-tinted so a failure is findable without reading.

The Error pane shows the type, the message, any other fields, then the
**stack**, innermost call first. Each frame wraps onto two lines (the
function, then `file:line · app`), never one long line to scroll. Frames
from the user's app are shown in full with a left rule; each run of
library frames (durable, elixir, ecto, phoenix…) folds to "7 library frames
· durable, elixir", which opens on click (all open when none are the
user's). DSL-generated functions read the way they were written —
`Orders · step :charge`, `compensation :refund`, `branch on:` — and the raw
frame is in each frame's tooltip and in Copy. A returned `{:error, …}` has no
stack; the pane says so by its type ("Returned {:error, …}").

### Runs list (`ExecutionsLive`)

Saved views as a tab strip with counts (All, Failed, Running, Waiting,
Cancelled), then the query bar (search grammar from `RunSearch`: id prefix,
`step:`, `error:`, `input.path:value`, `schedule:`). Columns: run, status,
where it is (current step), steps, retries, trigger, node, age.

**Nothing moves under the pointer.**
- Columns have fixed widths (`table-fixed` + a `colgroup`); Run and Where it
  is take the rest and truncate.
- Live events reload at most once a second. When the same runs are listed
  they update in place; when *which* runs are listed changes (new ones
  arrive, some leave the view) the rows stay and a blue pill over the
  table's head — "↑ 3 new runs" — applies the change on click.

**Bulk actions**: row checkboxes plus a select-all; a bar **floats** at the
bottom of the viewport (sticky, `bg-popover` + `shadow-lg`) rather than pushing
the table down, with "Retry N from failed step", "Rerun N", "Cancel N"
(confirmed), each counting only the selected runs it fits and shown only when
N > 0. A selection is the rows on screen: a new page, view or filter starts it
over. More than 100 runs needs admin. The result is one sentence ("Retried 12
of 12 runs.") in the same floating spot, dismissable.

### Charts (`Components.Charts`)

Three forms, all inline SVG/HTML from `Durable.Stats` buckets, all inside a
`panel` (title, sentence-case sub, optional legend + action slot):

- `stacked_bars` — runs finished per bucket: completed / failed / cancelled
  (`--chart-ok`, `--chart-fail`, `--off`), 2 px surface gap between
  segments.
- `rate_line` — failure rate; the ceiling adapts to the peak so 0.4% isn't
  a flat line.
- `percentile_lines` — p50 and p95 duration, one axis.

Plus `sparkline` and `meter` (a thin bar against a top value — capacity,
share of peak). Every chart has a legend when it has two or more series and
a per-bucket hover tooltip; one y-axis, never two. Range is `?range=1h|24h|7d|30d`
via `range_switch`.

- **Counts halve to whole numbers.** A count axis's top is even when small
  (`count_max`: 1 → 2, 5 → 6), so the middle gridline is never "0.5"
  rounded to "0".
- **Empty says empty.** With nothing in the window a chart drops its scale
  and says "No runs finished in this window" — a 0–10 scale over nothing
  reads as data.
- **A lone point is a dot.** A line chart bucket with no neighbour on
  either side (one completed run in a day) is drawn as a 6 px dot; a line
  through one point has no length and wouldn't show.

### Overview & Workflow pages

Both read the same way: **KPI strip** (number, then its change against the
previous window — red only when the change is bad), **charts row**, then
**tables that answer "what's wrong"**: failing workflows grouped by error
signature (digits normalized to `<n>`), slowest steps by p95 *active* time
(waits excluded), queues. Overview adds a live feed of lifecycle events;
the Workflow page adds its structure annotated with each step's p95 and
failure share, and the definition as compiled. Stats refresh on PubSub
events, throttled to one reload per 2 s.

### Structure map (`Components.Workflow.Structure`)

The workflow page's definition, drawn as a flow with the range's traffic
through it — a funnel you read left to right.

- **Start → cards → End.** Start and End are plain text (label, big mono
  number, one-line note), not boxes, so the cards carry the weight. End is
  "Completed N" with what else happened ("31 failed · 43 rolled back").
- **Arrows carry counts**: the number on the arrow into a card is the runs
  that reached it. Counts needn't shrink monotonically (retries resume
  mid-flow) — they're shown as they are.
- **A card** is the step's kind glyph (circle step, diamond decision, fork
  parallel, split branch) + mono name, a note only when there's something to
  say (retry policy, "may jump to …"), then two lines: `N reached · p95`,
  `N gave up · %` (a link to those runs) and `% retried` in amber. A
  traffic bar closes it: width = reached ÷ peak, the share that gave up in
  `--chart-fail`, the rest `--chart-ok`. Border turns destructive past 5%.
- **Flags, sparingly**: "Most give up here" (the step most runs gave up at)
  and "Slowest" — only when one step takes at least half the summed p95 and
  10 ms or more; 3 ms vs 1 ms is noise, not a finding.
- **Blocks**: parallel lists its steps with a neutral bar for each one's
  p95 (which branch sets the wall time); branch lists its paths — clause
  pill, step chain, share of runs that took it.
- **Compensations sit under the step they undo**, joined by a dashed violet
  line: "↺ name · runs if a later step fails · ran N×".
- Cards share the panel width (grid `minmax(168px, 1fr)` per card, 40 px
  arrows) and the row scrolls only when they hit their minimum.

### Queues & nodes (`QueuesLive`)

Queues table: state (Running / Idle / Paused), a **running / capacity
meter** (capacity ≈ this node's concurrency × live nodes polling the
queue; amber when full), ready, scheduled, oldest ready (amber past a
minute), done per minute, queue wait p95, and Pause/Resume. A queue no live
node polls says so in amber instead of a meter. Nodes table: id ("This
node" badge), alive/missing, running, queues, last heartbeat, uptime,
version. Polled every 3 s — heartbeats don't publish events.

Each queue also gets a **"Ready, last hour" sparkline** (baseline at zero,
neutral ink, peak beside it) from `Stats.queue_history` — one sample a minute,
drawn from the first sample so a fresh install isn't an hour of zeros. Below
the tables, **Operations** is `Durable.Activity` for the last day: one line
per event, written as a sentence ("Put 3 runs back on the queue — their node
stopped heartbeating for 300 s"), with a status mark (amber for recoveries,
diamond for fenced workers / failed acks / disabled schedules, ring for
pauses) and the node that recorded it.

### Inbox (`InputsLive`)

Three views: **Needs input**, **Waiting for events**, **Sleeping**.

- Needs input is a **two-pane task list**: the list (type badge, timeout,
  prompt, workflow · input · age) beside the selected task, which is sticky
  and selected via `?id=` so it's linkable. The task shows its run, prompt,
  a timeout sentence that says what happens next ("times out in 23h, then
  the run fails"), metadata as a definition list, and the form its type
  calls for — approval (comment + Reject / Approve), single or multi choice
  (option cards), form (fields from the wait spec; numbers parsed), free
  text. A disclosure states exactly what the run receives.
- Every form field is keyed by the input's id, so answering one task never
  leaves values in the next.
- Waiting for events: a table with a "Send event…" composer (JSON payload)
  calling `send_event`. Internal events (`__*`) are hidden.
- Viewers see the forms disabled with a one-line explanation.

### Schedules, Telemetry, Settings

- **Schedules** (`/schedules`): one row per schedule — switch (admin), name
  (links to its page) over its cadence in words with the cron as a code chip
  (`DurableDashboard.Cron`: "Every day at 09:00", "Weekdays at 09:30"; raw
  expression only when it can't say), workflow, **recent runs as status
  marks** oldest → newest (each a link), next run ("in 42s", "due now", "Off",
  or "Turned off" in destructive), last run (cron or Run now, whichever is
  newer) and Run now (operator → opens the new run). A failing schedule says
  so under its cadence. Shared pieces live in `Components.Schedule`.
- **A schedule's page** (`/schedules/:name`): name + On/Off pill, cadence;
  the switch and Run now on the right. A banner when it's failing to start
  its workflow (amber) or was turned off for it (destructive), with the last
  error. Facts: workflow, next run, last run, ok/failed over its last runs,
  p50 · p95 duration, queue. **Recent runs** as a duration strip (one bar per
  run, height = time taken, colour = outcome, each a link) over a table;
  **Next fires** in the viewer's local time (dimmed with a note when off);
  **Input**. "All its runs" opens Runs filtered with `schedule:<name>`.
- **Telemetry**: who is listening (`:telemetry.list_handlers/1`), the
  wire-up snippet, the event catalog grouped by area with a live
  last-5-minutes count per event on this node (a `:counters` handler that
  detaches itself when the page closes), and `Durable.Telemetry.metrics/0`.
- **Settings**: read-only and explanatory. Schema status first — pending
  migrations are an amber alert with the exact commands. Then instance,
  access (your level highlighted), queues on this node, every timing knob
  with a sentence on what it means for runs, retention (with Prune now,
  admin) and log capture, and the effective config as a copyable child spec.

### Empty / loading / error shells

For every list LV:

```heex
<div :if={@loading?}>     <.skeleton ...      />  …  </div>
<div :if={@error}>        <.error_state ...   />     </div>
<div :if={@items == []}>  <.empty_state ...   />     </div>
<div :if={@items != []}>  <list rendering>          </div>
```

## 7. Iconography

- HEEx side: `Components.Core.icon` curated SVG set (heroicons mini).
- React side: `lucide-react`, imported per icon.
- Default size: `size-4` (16 px). Larger only inside icon-bg pills, where
  `size-5` is OK.
- **Brand logos** (e.g. `github`) live in the `core.ex` set like any icon,
  but may keep their native `viewBox` (the GitHub mark is `0 0 24 24`) — the
  viewBox sizes the coordinate space, not the render size, so it still scales
  to `size-4`. Heroicons-style functional glyphs stay `0 0 20 20`.
- **Forbidden:** inline `<svg>` with hard-coded paths in component files
  outside `core.ex` and the curated lucide imports. **One sanctioned
  exception:** the sidebar **pulse mark** (the brand lockup in
  `Sidebar.brand/1`) — a one-off identity glyph, not reusable iconography, so
  it lives inline rather than in `core.ex`. Its two paths use
  `stroke="currentColor"` with `text-*` token classes (muted baseline, primary
  beat); no other bespoke SVG is allowed.

## 8. Density

This is a console, not a marketing site. Defaults are compact:

- Buttons: 32 h default; 28 h in dense surfaces (filter bars, table headers).
- Inputs: 32 h default; 28 h in dense surfaces.
- Table rows: 36–40 h. Never 48+.
- Vertical rhythm: `gap-1.5` / `gap-3` / `gap-6` (chip / control / section).
- Hover-to-reveal beats always-visible secondary actions.

## 9. Theming & accessibility

- **Dark is the default**, light is fully supported. Both are tested by
  every visual change.
- **Focus rings are mandatory** for every interactive element:
  `focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1
  focus-visible:ring-offset-background`. Component primitives bake this
  in; use them.
- **Contrast targets:** 4.5:1 for body text against background, 3:1 for
  status pills. Verified once per token tweak.
- **Keyboard nav:** every action reachable; ⌘K palette is the canonical
  global jumper.
- **Reduced motion:** respected globally — never bypass.

## 10. What NOT to build

- Custom illustrations, hero graphics, marketing-style animations.
- Bespoke animations beyond §3.
- Inline color literals or font sizes outside §2.
- New status strings without first updating §4.
- Nested cards.
- Drop shadows for elevation.
- Light-mode branded variants (e.g. lighter blue) — themes are reflective.
- Toast notifications. Use status pills + `error_state` instead.
- Confirmation modals for non-destructive actions.

## 11. Workflow graph addendum

The run page's **Graph** view: a ReactFlow island (`assets/src/react/`) fed
by `GraphBuilder` through the `FlowGraph` LiveComponent. Structure and this
run's state share one surface.

### Shape

A left-to-right flow of **cards** (220 × 56) for code that runs, and
**pills** (28 px tall) for the structure around it. dagre lays it out
(`graph-layout.ts`, rank gap 88, row gap 44); edges are smoothstep.

| Type             | Component           | Looks like | What it is                                     |
| ---------------- | ------------------- | ---------- | ---------------------------------------------- |
| `start` / `end`  | `StartNode`/`EndNode` | pill     | The run's boundaries                           |
| `step`           | `StepNode`          | card, `Box`      | A step                                   |
| `child_workflow` | `ChildWorkflowNode` | card, `GitFork`, stacked sheet | A step that ran as its own run, or started one |
| `decision`       | `GatewayNode`       | card, `GitBranch`, "decide" | A decision step; its dashed edges are the `goto` targets |
| `join`           | `JoinNode`          | pill, `GitMerge` | Closes a parallel block: "all 3 done" / "2 of 3 done" |
| `branch`         | `BranchNode`        | pill, `GitBranch` | A branch's gateway: "3 paths", then "→ low" |

**Blocks have a join and a gateway.** A parallel block fans out from the
step before it and meets in its join; a branch is one gateway with an edge
per clause, in the order they're written. Without them, a parallel block
followed by a branch wired every child to every clause (N × M labelled
edges).

### Cards

Icon tile tinted by status, the step name, and a status line with the
shared status dot: "● Completed · 147 ms · 2 attempts". In a finished run a
step that never ran is **dashed and dimmed and says "Not run"** —
"pending" would read as "about to". No ring, no corner dot: status lives on
the dot and the tint. Hovering shows the dashboard tooltip (`stepTip` in
`nodes/shared.ts`): the outcome, attempt n of max, start time, its parallel
block or branch clause, what a click does, and the error or internal name
as the footnote.

### Edges

Status classes from `graph_builder.overlay_status/3`:

- `.flow-edge-completed` — `--success` solid: this run went this way.
- `.flow-edge-running` — `--primary`, dash-flow animation.
- `.flow-edge-pending` — `--border` dashed: not reached (yet).
- `.flow-edge-conditional` — `--primary/55` dashed: a branch clause or a
  decision's `goto` this run didn't take. The taken one repaints as
  completed — static; the solid line against the dashed ones is the cue.

Clause labels (`low`, `otherwise`, `goto :x`) are small mono chips on the
edge's **last run into its target**, where every target has its own row —
not at the midpoint, where a gateway's edges share a trunk and labels stack.
A legend in the bottom-left names the four edge styles.

### Framing

The canvas is sized to the graph (280–640 px tall, plus a strip for the
legend) and the graph is framed above the legend: centred when it fits at
≥ 75 % zoom, never above 100 % (a small graph stays its natural size);
otherwise from its start at 75 %, to pan. No minimap. Re-framing happens
only when the topology changes — a status update never moves the view.

### Inspector

The Graph view uses **the run page's step inspector** — the one the Trace
view has — beside the canvas, not a sheet of its own. Clicking a card patches
the URL to `?step=<execution id>` (linkable; Esc or × closes it), rings the
card, and opens the inspector on Error for a failed step, else Output:
status, name and kind; a summary ("Failed on 3 attempts · 450ms active");
the local start time and a link to the child run it ran in or started;
then Error (with the stack), Input, Output, Logs and Attempts. A step that
never ran isn't clickable. Unlike Trace, the Graph view opens no step until
one is clicked.

A parallel child's output is stored wrapped (`__output__` / `__context__` /
`__result__`) so the block can resume; panes show what it returned
(`Trace.returned/1`).

Child runs are linked from the step's execution: when it belongs to a run
other than this one, the card becomes a `child_workflow` that opens it.
`__parallel_children` / `__call_children` in the root's context are a
fallback for children that haven't produced a step yet.

---

## 12. Information architecture

Nouns first: **workflows** (definitions, derived from run history),
**runs**, and the operator surfaces around them. The sidebar groups them by
intent — Observe, Operate, Instrument.

| URL                          | LiveView             | Purpose                                         |
| ---------------------------- | -------------------- | ----------------------------------------------- |
| `/`                          | `OverviewLive`       | Health over a range, what's failing, live feed  |
| `/executions`                | `ExecutionsLive`     | Runs: saved views, search, facets, bulk actions |
| `/executions/:id[/:view]`    | `WorkflowLive`       | One run: trace, graph, logs, context, family    |
| `/workflows`                 | `WorkflowsLive`      | Catalog: runs, failure rate, p50/p95, retries   |
| `/workflows/:name`           | `WorkflowDetailLive` | One workflow's health, steps and errors         |
| `/workflows/:name/runs`      | `ExecutionsLive`     | Runs of one workflow                            |
| `/inputs`                    | `InputsLive`         | Inbox: inputs, events, sleeping runs            |
| `/queues`                    | `QueuesLive`         | Queues and nodes                                |
| `/schedules`                 | `SchedulesLive`      | Cron schedules                                  |
| `/telemetry`                 | `TelemetryLive`      | Events, handlers, metrics                       |
| `/settings`                  | `SettingsLive`       | Schema status and configuration                 |

Older run URLs (`/executions/:id/summary|timeline|history|flow|io`) map onto
the current views.

### Access

`DurableDashboard.Access`: **viewer** (default — sees everything, changes
nothing), **operator** (retry, rerun, cancel, answer inputs, send events,
pause queues, run a schedule now), **admin** (bulk over 100 runs,
enable/disable schedules, prune). The host supplies a `resolver:` on the
router. UI rule: controls the viewer can't use are **hidden** in tables and
**disabled with a sentence** in forms; the server checks again in
`Access.perform/5`, which also emits `[:durable_dashboard, :action]` for
audit.

## 13. Updating this doc

When you ship a UI change that establishes new precedent (a new
component, a new color use, a new animation), update this doc in the same
PR. If you can't justify the change here, don't ship it there.

If you disagree with a rule here, change the rule with a PR — don't
ignore it locally.
