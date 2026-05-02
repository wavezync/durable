# DurableDashboard

LiveView-first web console for the [Durable](https://hex.pm/packages/durable)
workflow engine.

The dashboard renders server-side via Phoenix LiveView, with a single
ReactFlow island for the workflow-graph view. No SPA, no separate API —
just one router macro.

## Features

- **Overview** — live status counts and recent executions
- **Workflows** — searchable, filterable list with pagination
- **Workflow detail** — summary, flow graph, topology, logs, I/O, and
  child-execution history
- **Pending inputs** — surface and resolve human-in-the-loop steps
- **Schedules** — toggle, trigger, and inspect cron-driven workflows
- **Settings** — inspect Durable's runtime configuration
- **⌘K command palette** — keyboard-driven navigation

## Installation

Add `durable_dashboard` alongside `durable`:

```elixir
def deps do
  [
    {:durable, "~> 0.0.0-alpha"},
    {:durable_dashboard, "~> 0.0.0-alpha"}
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

### URL surface

The macro emits these routes under your `:mount` prefix:

- `GET /` — Overview
- `GET /workflows` — list
- `GET /workflows/:id[/:tab]` — detail
- `GET /inputs`
- `GET /schedules`
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

## Design

`DESIGN.md` codifies the design language: tokens, typography, spacing,
motion, status semantics, component primitives, and composition
patterns. New visual decisions are made there first, then applied in
code.

## License

MIT
