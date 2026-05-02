# Durable Dashboard — Design Language

This document is the source of truth for every visual decision in the Durable
Dashboard. Read it before adding or modifying any UI surface. If a decision
isn't here, codify it here first; don't make it twice.

> **Audience.** Any contributor (human or AI assistant) shipping a UI piece.
> **Goal.** A new contributor can answer *"how do I render a list of executions?"*
> after five minutes with this doc.

## 1. Philosophy

Durable Dashboard is a **workflow-engine console**. The aesthetic priorities
are, in order:

1. **Data density.** Operators read this thing all day. Every pixel that
   isn't carrying information is a tax.
2. **Dark-first.** The default theme is dark; light theme is supported with
   the same visual fidelity for ops on bright monitors.
3. **Restrained color.** Color carries semantic meaning (status). It is
   never used for branding or decoration.
4. **No chrome.** No drop shadows for depth, no gradients for polish, no
   illustrations, no marketing copy. Elevation comes from background
   contrast, not effects.

**Inspirations** (not to imitate, but to calibrate against):

- **Temporal Web** — data density and disciplined hierarchy.
- **Inngest** — polish and motion vocabulary.
- **Linear** — typography rhythm and command-palette discipline.
- **Argo Workflows / n8n** — workflow graph conventions.

**Visual budget.** Every surface earns its weight. No card-in-card-in-card.
Whitespace is structural, not decorative — it separates regions, not
paragraphs.

## 2. Foundations

### 2.1 Colors

Every color comes from a CSS custom property declared in
`assets/src/index.css`. Light + dark values are paired. Tailwind utility
classes (`bg-card`, `text-primary`, `border-border`) read these tokens via
the `@theme inline` block.

| Token                   | Light                    | Dark                      | Use                                           |
| ----------------------- | ------------------------ | ------------------------- | --------------------------------------------- |
| `--background`          | `oklch(1 0 0)`           | `oklch(0.145 0 0)`        | App canvas                                    |
| `--foreground`          | `oklch(0.18 0 0)`        | `oklch(0.98 0 0)`         | Primary text                                  |
| `--card`                | `oklch(0.985 0 0)`       | `oklch(0.185 0 0)`        | Surfaces above the canvas                     |
| `--popover`             | `oklch(0.99 0 0)`        | `oklch(0.205 0 0)`        | Floating surfaces                             |
| `--primary`             | `oklch(0.5 0.2 250)`     | `oklch(0.72 0.16 250)`    | Primary actions, focus, active nav            |
| `--secondary`           | `oklch(0.96 0 0)`        | `oklch(0.22 0 0)`         | Secondary buttons, neutral chips              |
| `--accent`              | `oklch(0.95 0 0)`        | `oklch(0.24 0 0)`         | Hover backgrounds                             |
| `--muted`               | `oklch(0.96 0 0)`        | `oklch(0.21 0 0)`         | Subdued surfaces                              |
| `--muted-foreground`    | `oklch(0.5 0 0)`         | `oklch(0.62 0 0)`         | Secondary text                                |
| `--success`             | `oklch(0.55 0.18 155)`   | `oklch(0.78 0.16 155)`    | Status: completed / running                   |
| `--warning`             | `oklch(0.65 0.18 75)`    | `oklch(0.82 0.16 80)`     | Status: waiting / compensating                |
| `--destructive`         | `oklch(0.55 0.22 22)`    | `oklch(0.72 0.20 22)`     | Status: failed / timeout, destructive actions |
| `--info`                | `oklch(0.55 0.16 230)`   | `oklch(0.78 0.13 230)`    | Status: scheduled                             |
| `--border`              | `oklch(0.92 0 0)`        | `oklch(0.27 0 0)`         | Hairline dividers                             |
| `--input`               | `oklch(0.94 0 0)`        | `oklch(1 0 0 / 8%)`       | Input borders/backgrounds                     |
| `--ring`                | `oklch(0.5 0.2 250 / 0.4)` | `oklch(0.72 0.16 250 / 0.55)` | Focus rings                              |

#### Forbidden

- Hex literals — `#3b82f6`, `#22c55e`, `#fff`. Use tokens.
- Inline OKLCH/HSL/RGB in components — `oklch(0.78 0.16 155)`,
  `rgb(34 197 94)`. Use tokens.
- Tailwind palette colors — `text-blue-500`, `bg-green-100`. Use tokens.
- Any new color outside the table without first adding it here.

#### Opacity

Use the slash modifier on token classes for tints: `bg-success/10`,
`text-primary/80`, `border-destructive/20`. Standard tints: `/5`, `/10`,
`/15`, `/20`, `/40`, `/60`, `/80`. Anything else needs justification.

### 2.2 Typography

- `--font-sans` = **Inter Variable** with `cv11` enabled.
- `--font-mono` = **JetBrains Mono Variable** with ligatures off.

Use `font-mono` (or the `text-numeric` utility for tabular numerics) on:
IDs, durations, timestamps, JSON, code, status pills, dense numeric tables.

#### Type scale

Six sizes only. Anything else needs a comment explaining why.

| Class          | Size | Use                                                    |
| -------------- | ---- | ------------------------------------------------------ |
| `text-[9px]`   | 9    | *Exception only:* graph-marker micro-eyebrows (start/end labels, group badges). |
| `text-[10px]`  | 10   | Eyebrow / uppercase chip / kbd / footer hints           |
| `text-[11px]`  | 11   | Footnote, dense table cell, tertiary metadata           |
| `text-xs`      | 12   | Body small, control labels, navigation items           |
| `text-[13px]`  | 13   | Default body, default button text, form fields         |
| `text-sm`      | 14   | Card titles, primary body, list-row titles             |
| `text-[18px]`  | 18   | Section heading (h2)                                   |
| `text-[22px]`  | 22   | Page heading (h1)                                      |

Two heading utilities are declared in `index.css`:

- `text-heading` — applies `font-weight: 600`, `letter-spacing: -0.015em`,
  `line-height: 1.2`. Use on h1/h2/h3.
- `text-numeric` — applies `font-mono`, tabular nums, slashed zero.

### 2.3 Spacing

4 px grid. Allowed tailwind values: `0.5, 1, 1.5, 2, 2.5, 3, 4, 6, 8, 12, 16`.
Snap everything else.

Common rhythms:

- `gap-1.5` — chips, inline status indicators
- `gap-2` — adjacent controls (button + button)
- `gap-3` — related controls (input + button group)
- `gap-4` — within a card body
- `gap-6` — between major sections

Page padding: `px-6 py-4` standard. Sheet / dialog inner padding: `p-4`.

### 2.4 Radius

Maps to `--radius-*` tokens; use the Tailwind shortcuts:

| Class            | px  | Use                                              |
| ---------------- | --- | ------------------------------------------------ |
| `rounded-sm`     | 2   | Chips, badges, kbd, dense controls               |
| `rounded-md`     | 4   | Buttons, inputs, cards, surface containers       |
| `rounded-lg`     | 6   | Sheets, dialogs, large surfaces                  |
| `rounded-full`   | ∞   | Avatars, status dots, circular buttons           |

No 8 px or 10 px radii. They look like marketing components.

### 2.5 Borders

- 1 px hairline default — `border border-border`.
- 1.5 px only for focus rings (`ring-2 ring-ring/40`).
- 2 px reserved for status emphasis (e.g. "current execution" outline on a
  graph node — see §11).
- Avoid double borders (border + ring without offset).

### 2.6 Shadows

`shadow-sm` only. Elevation is achieved via *background contrast* (card
above canvas), not blurred shadows. The one exception: `<EdgeLabelRenderer>`
and other floating overlays may use `shadow-lg` for popovers.

## 3. Motion

Three named animations only. Defined in `assets/src/index.css`.

| Name              | Duration | Easing      | Use                                                  |
| ----------------- | -------- | ----------- | ---------------------------------------------------- |
| `led-dot`         | 1.6 s    | ease-in-out | Running/active status dots; pulses opacity + glow.   |
| `dash-flow`       | 1.0 s    | linear      | Flowing edges in the workflow graph.                 |
| `animate-pulse`   | 2.0 s    | cubic-bezier| Skeleton loaders only (never on real content).       |

Transitions: `transition-colors duration-150` for hover/focus. Nothing
slower than 200 ms. Layout transitions (`transition-all`) are forbidden —
they make data-dense UIs feel sluggish.

`prefers-reduced-motion: reduce` disables all three animations through a
single media query in `index.css`. Don't bypass it.

## 4. Status semantics — canonical table

This is the **single source of truth** for every status string the system
emits. Do not invent local mappings.

| Status            | Color tier      | Dot     | Label          |
| ----------------- | --------------- | ------- | -------------- |
| `pending`         | `muted`         | none    | "pending"      |
| `running`         | `success`       | pulse   | "running"      |
| `waiting`         | `warning`       | solid   | "waiting"      |
| `completed`       | `success`       | solid   | "completed"    |
| `failed`          | `destructive`   | none    | "failed"       |
| `cancelled`       | `muted`         | none    | "cancelled"    |
| `compensating`    | `warning`       | pulse   | "compensating" |
| `compensated`     | `muted`         | none    | "compensated"  |
| `compensation_failed` | `destructive` | none  | "comp. failed" |
| `scheduled`       | `info`          | none    | "scheduled"    |
| `timeout`         | `destructive`   | none    | "timeout"      |

To add a status:

1. Update this table.
2. Update `Components.Core.status_meta/1` (HEEx-side) and the `toneFor`
   helpers in `step_node.tsx` and any other React node components.
3. Update the workflow query/schema if needed.

If those four don't agree, the table wins.

## 5. Component primitives — `Components.Core` API contract

Stateless visual primitives live in
`lib/durable_dashboard/components/core.ex`. Every primitive listed here is
already implemented; see the source for the full attr list.

### `<.button>`

Variants: `primary | secondary | ghost | destructive | link`.
Sizes: `sm` (28h) | `md` (32h, default) | `lg` (40h).

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

Uppercase eyebrow chip. Variants: `default | primary | success | warning |
destructive | info | muted`. Use for tags, counts, eyebrows. **Don't** use
for live workflow status — that's `<.status_pill>`.

### `<.status_pill>`

Workflow / step state chip. Reads `status` (atom or string) and resolves
to the canonical table in §4.

```heex
<.status_pill status={execution.status} />
```

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

Inline code chip — IDs, JSON snippets, durations, queue names.

### `<.kbd>`

Keyboard hint inside command palette / tooltips.

### `<.relative_time at={dt}>`

Humanized "2m ago" with absolute ISO in `title`. Always use this; never
hand-format times.

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
<AppSidebar /> <TopBar />
                <main class="px-6 py-4 max-w-screen-2xl mx-auto">
                  <PageHeader />
                  <PageContent />
                </main>
```

- Sidebar: collapsible, lucide icons, fixed width when expanded.
- Topbar: 28 h, breadcrumbs left, theme toggle + ⌘K hint right.
- Main: `max-w-screen-2xl` to keep line lengths readable on ultrawide
  monitors.

### Page header

```heex
<header class="flex items-end justify-between gap-3 mb-4">
  <.heading level={1} subtitle={...}>Workflows</.heading>
  <div class="flex items-center gap-2"> <.button>...</.button> </div>
</header>
```

Subtitle = relative time, scope context, or counts. Never marketing copy.

### Tab strip

`<.tabs>` from `Components.Workflow.Tabs`. No ad-hoc nav strips.

### List / table row

- 36–40 h tall, hairline divider between rows.
- Hover: `bg-accent/50`.
- Click anywhere on the row → `live_patch` to detail.
- Right-aligned secondary actions reveal on hover.

### Detail sheet / drawer

`data-slot="sheet-content"` is styled centrally in `index.css`. **Don't**
override its background or backdrop-blur in the sheet itself.

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
- **Forbidden:** inline `<svg>` with hard-coded paths in component files
  outside `core.ex` and the curated lucide imports.

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

Specific rules for the ReactFlow `Flow` tab. (We do not have a separate
Topology tab — graph topology and runtime state share the same surface.
Status overlay is layered on top of the structural rendering rather than
shown alongside.)

### Visual model — n8n editor canvas

The canvas reads as a **horizontal flow of icon-first squares with
labels below**, in the spirit of n8n's editor: every node — step,
decision, fork, join, start, end — occupies a uniform 88 × 96 cell
(64 × 64 icon box + 32 px label region). Branches splay out and rejoin
via flowing bezier curves; there is no bounding rectangle for parallel
groups. Background is the dot-grid surface ReactFlow ships.

### Node types

| Type        | Component       | Lucide icon | Purpose                            |
| ----------- | --------------- | ----------- | ---------------------------------- |
| `start`     | `StartNode`     | `Play`      | Boundary marker (success tone)     |
| `end`       | `EndNode`       | `Flag`      | Boundary marker                    |
| `step`      | `StepNode`      | `Box`       | Regular step (clickable)           |
| `decision`  | `GatewayNode`   | `GitBranch` | Conditional branching point        |

There are **no marker nodes** for parallel fork/join or branch
fork/join. Fan-out and fan-in are expressed purely through edge
geometry: the previous step has multiple outgoing edges (one per
parallel/branch child), and the next step has multiple incoming edges
(one from each child's tail). This matches n8n's editor convention.

Every cell is identical: 64 × 64 rounded-md card, status-tinted border,
lucide icon centered, status dot at top-right of the box. Below the
box, a 32 px label region carries the step name + status meta in
`text-[11px]` and `text-[9px]` respectively.

### Edge styling

A single custom edge component (`AnimatedFlowEdge`) — a flowing bezier
path. Status-driven stroke is set by classes the server attaches via
`graph_builder.overlay_status/3`:

- `.flow-edge-completed` — `--success` solid, 1.5 px.
- `.flow-edge-running` — `--primary` with `dash-flow` animation.
- `.flow-edge-pending` — `--border` 1 px dashed.
- `.flow-edge-conditional` — `--primary/55` dashed. Used for
  decision-step `{:goto, :target, _}` paths extracted at compile time
  by `Durable.DSL.Step.build_decision/3`. Stays dashed regardless of
  runtime state because it represents a *possible* path, not a
  *taken* one.

Edge labels (branch clause names like `low` / `high` / `default`, and
decision goto targets like `goto :auto_remove`) render as
`<.badge kind="muted">`-style chips at the bezier midpoint via
`<EdgeLabelRenderer>`.

### "Current execution" emphasis

When the user is viewing a particular workflow execution, the matching
step's icon box receives
`ring-2 ring-primary/60 ring-offset-2 ring-offset-background`. This is
the only place 2 px borders are sanctioned (§2.5).

### Drill-in arrow + child preview

A step with an associated child workflow gets a small chevron badge at
the top-right corner of the icon box. Two cases:

1. **Parallel-child step** — the child runs in its own
   `WorkflowExecution` with its own steps. Clicking the step navigates
   to the child's flow page (URL aligns with the data on screen).
2. **Sub-workflow step** (`call_workflow` / `start_workflow`) — the
   calling step runs in the parent execution but spawned a child via
   `Durable.Orchestration`. Clicking opens the inspector sheet with a
   **Child** tab as the default, showing:
   - Child status pill, module, duration
   - Compact horizontal mini-flow strip (status-tinted chips, no
     ReactFlow island — see `mini_chip/1` in `flow_graph.ex`)
   - Child input + result/error
   - "Open full flow →" link that navigates to the child's flow page

The two cases share the chevron affordance but diverge on click intent:
parallel children navigate (data lives elsewhere), sub-workflows preview
inline (caller and callee share a parent-context narrative).

The step→child mapping is sourced from the parent's context:
`__parallel_children` (written by the executor for parallel blocks) and
`__call_children` (written by `Durable.Orchestration` for
`call_workflow` and `start_workflow`). Both are merged by
`parallel_children_lookup/1` in `flow_graph.ex`.

---

## 12. Updating this doc

When you ship a UI change that establishes new precedent (a new
component, a new color use, a new animation), update this doc in the same
PR. If you can't justify the change here, don't ship it there.

If you disagree with a rule here, change the rule with a PR — don't
ignore it locally.
