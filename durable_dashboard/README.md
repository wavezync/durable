# DurableDashboard

[![CI](https://github.com/wavezync/durable/actions/workflows/ci.yml/badge.svg)](https://github.com/wavezync/durable/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/durable_dashboard.svg)](https://hex.pm/packages/durable_dashboard)
[![HexDocs](https://img.shields.io/badge/hex-docs-8f75f0.svg)](https://hexdocs.pm/durable_dashboard)
[![License](https://img.shields.io/hexpm/l/durable_dashboard.svg)](https://github.com/wavezync/durable/blob/main/LICENSE)

**Docs:** [durable.wavezync.com](https://durable.wavezync.com/docs/dashboard/) ·
**Guide:** [Using the dashboard](guides/using_the_dashboard.md) ·
**Engine:** [`durable`](https://hex.pm/packages/durable) ·
**API:** [HexDocs](https://hexdocs.pm/durable_dashboard)

LiveView-first web console for the [Durable](https://hex.pm/packages/durable)
workflow engine.

The dashboard renders server-side via Phoenix LiveView, with a single
ReactFlow island for the workflow-graph view. No SPA, no separate API —
just one router macro.

## Features

- **Overview** — health over a time range: what's failing and why, queue
  pressure, the slowest steps and a live feed
- **Runs** — every run, with saved views, a query bar (`step:`, `error:`,
  `input.path:`, `key:`, `tag:` and more) and bulk retry, rerun and cancel.
  Filters live in the URL, so views are shareable
- **One run** — a trace of every attempt, the workflow graph, logs, context,
  parent and child runs, and what happened to its workflow key
- **Workflows** — runs, failure rate, duration and retries per workflow, its
  structure with per-step numbers, and errors grouped by signature
- **Inbox** — answer inputs, send events, see what's sleeping
- **Keys** — every workflow key, who holds it, and what was re-added or dropped
- **Queues & nodes** — load, backlog and wait per queue, pause and resume, node
  health and a record of recoveries
- **Schedules** — cron schedules, their recent runs, run now, on and off
- **Telemetry** — which handlers are attached and which events are firing
- **Settings** — schema status, this instance's configuration, retention
- **⌘K command palette** — jump to any page, workflow, schedule, run or key

New to it? Read [Using the dashboard](guides/using_the_dashboard.md).

## Installation

Add `durable_dashboard` alongside `durable`:

```elixir
def deps do
  [
    {:durable, "~> 1.5"},
    {:durable_dashboard, "~> 1.3"}
  ]
end
```

## Usage

Mount the dashboard at any path in your host router:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  # ...your existing pipelines and scopes...

  use DurableDashboard.Router, mount: "/dashboard", durable: MyApp.Durable
end
```

The macro emits the dashboard's pipelines, asset routes, and live routes
inline in your router. It must live at the **top level** — not inside a
`scope` or `pipe_through` block, since it defines its own pipelines.

### Options

- `:mount` — URL prefix the dashboard mounts at (required)
- `:durable` — Durable instance name (default: `Durable`)
- `:live_socket_path` — path your endpoint uses for `Phoenix.LiveView.Socket`
  (default: `"/live"`)
- `:on_mount` — list of `on_mount` hooks the host wants to inject for
  auth or other concerns (default: `[]`)
- `:resolver` — a `DurableDashboard.Access` module that decides who can change
  things. Without one the dashboard is read-only

### URL surface

The macro emits these routes under your `:mount` prefix:

- `GET /` — Overview
- `GET /executions` — Runs
- `GET /executions/:id[/:view]` — one run (`trace`, `graph`, `logs`, `context`,
  `family`, `key`)
- `GET /workflows`, `GET /workflows/:name`, `GET /workflows/:name/runs`
- `GET /inputs` — Inbox
- `GET /keys`
- `GET /queues` — Queues & nodes
- `GET /schedules`, `GET /schedules/:name`
- `GET /telemetry`
- `GET /settings`
- `GET /__assets__/*` — CSS/JS/font assets

## Authentication

Inject your host app's auth via `:on_mount` hooks — the dashboard does
not ship its own auth layer:

```elixir
use DurableDashboard.Router,
  mount: "/dashboard",
  durable: MyApp.Durable,
  on_mount: [{MyAppWeb.UserAuth, :ensure_authenticated}]
```

Without a `:resolver`, everyone who can open the dashboard is read-only. See
[Using the dashboard](guides/using_the_dashboard.md#set-it-up) for the access
levels.

## Design

`DESIGN.md` codifies the design language: tokens, typography, spacing,
motion, status semantics, component primitives, and composition
patterns. New visual decisions are made there first, then applied in
code.

## License

MIT
