# Durable Phoenix Demo

A sample Phoenix LiveView application for the [Durable](https://github.com/wavezync/durable) workflow engine and its dashboard. It builds against the `durable` and `durable_dashboard` in this repository.

## Features

- **Eight workflows**, each showing a different part of Durable. Seven start from the home page (see [Workflows](#workflows))
- **Human input and events**: pages to answer pending inputs and to send the events runs wait for
- **Schedules**: a cron workflow that fires every minute, with run-now and on/off
- **Real-time updates**: the pages update as runs progress, over the app's PubSub
- **Durable Dashboard** mounted at `/dashboard`

## Getting Started

### Prerequisites

- Elixir 1.15+
- PostgreSQL 13+

### Setup

1. **Start the database** (using Docker):
   ```bash
   cd examples/phoenix_demo
   docker-compose up -d
   ```

   This starts PostgreSQL on port 53412.

2. **Install dependencies**:
   ```bash
   mix deps.get
   ```

3. **Create and migrate the database**:
   ```bash
   mix ecto.create
   mix durable.gen.upgrade -r PhoenixDemo.Repo   # only if Durable has newer migrations than the ones checked in
   mix ecto.migrate
   ```

4. **Start the server**:
   ```bash
   mix phx.server
   ```

5. **Open in browser**:

   Navigate to [http://localhost:4005](http://localhost:4005) (the dashboard is
   mounted at [http://localhost:4005/dashboard](http://localhost:4005/dashboard))

### Stopping the Database

```bash
docker-compose down
```

To also remove the data volume:
```bash
docker-compose down -v
```

## Usage

### Starting a Workflow

The home page lists the workflows. Each card has a small form for its input and
a button that calls `Durable.start/2` (or `Durable.trigger_schedule/1` for the
cron one). The run then shows up under **Executions**, and in the dashboard.

### Workflows

| Workflow | Shows |
|---|---|
| Order Fulfillment | `call_workflow`, `compensate` and `on_failure: :rollback`. Tick "force failure" to watch the rollback |
| Payment | Retries with exponential backoff. Also the child of Order Fulfillment |
| Expense Approval | `wait_for_form`, `wait_for_approval` and `wait_for_all` |
| Content Moderation | A named `parallel` block with `into:`, `branch on:` and `wait_for_choice` |
| Payment Reconciliation | `wait_for_event` with a timeout |
| Drip Email Campaign | `schedule_at` and `sleep` |
| Article Sync | Workflow keys: `debounce:` and `on_duplicate: {:send_event, name}`. Not on the home page: start it from IEx with `key: "article:42"` |
| Hourly Metrics (cron) | `@schedule cron: ...`, firing every minute |

They live in `lib/phoenix_demo/workflows/`.

### Answering Inputs and Sending Events

- **Pending inputs** (`/pending-inputs`) lists the runs waiting for a person,
  with a form for each input type. Submitting calls
  `Durable.Wait.provide_input/3` and the run resumes.
- **Pending events** (`/pending-events`) lists the events runs wait for and
  sends one with `Durable.send_event/3`, standing in for a webhook.
- **Schedules** (`/schedules`) lists the cron schedules, runs one now and turns
  one on or off.

The dashboard at `/dashboard` does all of this too, from its Inbox and
Schedules pages.

## Architecture

Durable starts in the app's supervision tree, with the app's repo and PubSub:

```elixir
{Durable,
 repo: PhoenixDemo.Repo,
 queues: %{default: [concurrency: 5]},
 pubsub: PhoenixDemo.PubSub,
 scheduler_interval: 5_000,
 scheduled_modules: [PhoenixDemo.Workflows.HourlyMetricsCronWorkflow]}
```

The dashboard is one line in the router. The demo's resolver makes everyone an
admin; a real app maps its own users:

```elixir
use DurableDashboard.Router,
  mount: "/dashboard",
  durable: Durable,
  resolver: PhoenixDemoWeb.DurableResolver
```

### Key Components

- **HomeLive**: the workflows, with a form to start each
- **ExecutionsLive**: every run and its status
- **WorkflowDetailLive**: one run, its steps and its child runs
- **PendingInputsLive**, **PendingEventsLive**: answer inputs, send events
- **SchedulesLive**: cron schedules

### Database Tables

Durable keeps its tables in the `durable` schema, among them:

- `durable.workflow_executions` - Runs
- `durable.step_executions` - One row per step attempt
- `durable.pending_inputs`, `durable.pending_events` - What runs wait for
- `durable.scheduled_workflows` - Cron schedules

After pulling a Durable change that adds a migration, run
`mix durable.gen.upgrade -r PhoenixDemo.Repo` and `mix ecto.migrate`.

## Development

### Compiling

```bash
mix compile
```

### Running Tests

```bash
mix test
```

### Code Style

```bash
mix format
```

## Learn More

- [Durable Documentation](https://hexdocs.pm/durable)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view)
- [Ecto](https://hexdocs.pm/ecto)
