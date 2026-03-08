# M06: Phoenix Dashboard

**Status:** Not Started
**Priority:** Low
**Effort:** 2 weeks
**Dependencies:** M01 (graph visualization), M05 (message bus for real-time updates)

## Motivation

A web dashboard provides the most accessible way to monitor and manage workflows — especially for non-developer stakeholders (ops, support). LiveView enables real-time updates without polling, and graph visualization (M01) makes workflow state immediately comprehensible. This follows the pattern established by Phoenix LiveDashboard and Oban Web.

## Scope

### In Scope

- Plug/router module for embedding in Phoenix apps (`Durable.Dashboard`)
- LiveView pages: workflow list, execution detail, step logs, graph visualization
- Real-time updates via M05 message bus
- Basic actions: cancel workflow, provide input, retry failed workflow
- Responsive design with minimal CSS (Tailwind or inline styles)

### Out of Scope

- Standalone web server (must be embedded in a Phoenix app)
- Authentication/authorization (host app responsibility — provide hooks)
- Workflow definition editor (code-only)
- Historical analytics / charts
- Multi-tenant dashboard (single Durable instance per dashboard)

## Architecture & Design

### Module Layout

```
lib/durable/dashboard.ex                        # Plug router / mount point
lib/durable/dashboard/layout.ex                  # Shared layout component
lib/durable/dashboard/live/                      # LiveView pages
├── workflow_list_live.ex                         # Paginated workflow list
├── workflow_detail_live.ex                       # Single execution detail
├── step_logs_live.ex                             # Step log viewer
└── graph_live.ex                                 # Interactive graph (M01)
lib/durable/dashboard/components/                # Reusable components
├── status_badge.ex                               # Status pill component
├── duration.ex                                   # Duration display
├── pagination.ex                                 # Pagination controls
└── graph_renderer.ex                             # SVG/Mermaid graph renderer
```

### Embedding Pattern

```elixir
# In host app's router.ex
scope "/admin" do
  pipe_through [:browser, :admin_auth]
  forward "/durable", Durable.Dashboard, otp_app: :my_app
end
```

`Durable.Dashboard` is a `Plug.Router` that mounts LiveView routes:

```elixir
defmodule Durable.Dashboard do
  use Plug.Router

  # Accepts :otp_app, :live_socket_path, :csp_nonce options
  # Mounts LiveView routes for each page
end
```

### LiveView Pages

#### Workflow List (`/`)

- Paginated table of workflow executions
- Filter by: status, workflow module, queue, date range
- Sort by: started_at, updated_at
- Quick actions: cancel, view detail
- Real-time: new executions appear, status updates live

#### Execution Detail (`/workflows/:id`)

- Workflow metadata: module, name, status, input, timing
- Step timeline: ordered list of steps with status, duration, attempt count
- Context viewer: current context as formatted JSON
- Graph visualization: workflow graph with execution state overlay (M01)
- Actions: cancel, provide input (if waiting), retry (if failed)

#### Step Logs (`/workflows/:id/steps/:step`)

- Full log output for a specific step execution
- Attempt selector (if retried)
- Log level filtering
- Timestamps and duration

#### Graph View (`/workflows/:id/graph`)

- Full-page graph visualization using M01 output
- Render as SVG (from Mermaid or custom renderer)
- Nodes colored by execution state
- Click node to navigate to step detail
- Real-time state updates via M05

### Real-Time Updates

Subscribe to message bus topics on LiveView mount:

```elixir
def mount(%{"id" => workflow_id}, _session, socket) do
  if connected?(socket) do
    Durable.MessageBus.subscribe("durable:workflow:#{workflow_id}")
  end
  # ...
end

def handle_info(%{event: :step_completed} = event, socket) do
  # Update relevant assigns
  {:noreply, update_step_status(socket, event)}
end
```

### Styling

Use inline styles or a small embedded CSS module — no external CSS framework dependency. Follow Phoenix LiveDashboard's approach of self-contained styling.

### Optional Dependency

```elixir
# mix.exs
{:phoenix_live_view, "~> 1.0", optional: true}
```

Dashboard module compiles conditionally:
```elixir
if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule Durable.Dashboard do
    # ...
  end
end
```

## Implementation Plan

1. **Router/plug scaffold** — `lib/durable/dashboard.ex`
   - Basic Plug.Router with LiveView mounting
   - Layout component with nav, styles

2. **Workflow list page** — `lib/durable/dashboard/live/workflow_list_live.ex`
   - Query executions with pagination
   - Filter/sort controls
   - Status badges, duration formatting

3. **Execution detail page** — `lib/durable/dashboard/live/workflow_detail_live.ex`
   - Fetch execution + steps
   - Step timeline component
   - Context JSON viewer
   - Action buttons (cancel, retry)

4. **Step logs page** — `lib/durable/dashboard/live/step_logs_live.ex`
   - Fetch step execution logs
   - Attempt selector
   - Log rendering with levels

5. **Graph visualization** — `lib/durable/dashboard/live/graph_live.ex`
   - Use M01's Mermaid export for rendering
   - Embed Mermaid.js for client-side rendering
   - OR: use M01's DOT export + server-side SVG generation
   - Execution state coloring

6. **Real-time integration** — wire M05 message bus to all LiveViews
   - Subscribe on mount
   - Handle events, update assigns
   - Graceful degradation if message bus not configured

7. **Input/action forms** — add to execution detail page
   - "Provide Input" form for waiting workflows
   - "Cancel" confirmation
   - "Retry" for failed workflows

## Testing Strategy

- `test/durable/dashboard/workflow_list_live_test.exs` — LiveView tests:
  - Renders workflow list
  - Pagination works
  - Filters narrow results
- `test/durable/dashboard/workflow_detail_live_test.exs` — LiveView tests:
  - Renders execution detail
  - Shows step timeline
  - Cancel action works
- `test/durable/dashboard/graph_live_test.exs` — renders graph component
- Use `Phoenix.LiveViewTest` for all LiveView tests
- Seed test data with DataCase
- Test real-time updates by publishing events and asserting DOM changes

## Acceptance Criteria

- [ ] `forward "/durable", Durable.Dashboard` mounts successfully in a Phoenix router
- [ ] Workflow list page shows executions with filters and pagination
- [ ] Execution detail page shows steps, context, and timing
- [ ] Step logs page shows captured logs with level filtering
- [ ] Graph page renders workflow graph with execution state
- [ ] Real-time updates work (step status changes appear without refresh)
- [ ] Cancel/provide-input actions work from the dashboard
- [ ] Dashboard is self-contained (no external CSS/JS dependencies besides LiveView)
- [ ] Dashboard degrades gracefully without message bus (poll fallback)
- [ ] `mix credo --strict` passes

## Open Questions

- Mermaid.js (client-side) vs server-side SVG rendering for graphs?
- Should dashboard include queue management (pause/resume queues)?
- Authentication: provide a `:on_mount` hook option, or leave entirely to host app?
- Should we ship as a separate hex package (`durable_dashboard`) to keep core lean?

## References

- `agents/arch.md` — "Graph Visualization" section
- `agents/milestones/M01-graph-visualization.md` — graph data structures and export
- `agents/milestones/M05-message-bus.md` — real-time event delivery
- Phoenix LiveDashboard source — embedding pattern reference
- Oban Web — commercial dashboard reference for workflow-like systems
