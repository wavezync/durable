# Durable

[![CI](https://github.com/wavezync/durable/actions/workflows/ci.yml/badge.svg)](https://github.com/wavezync/durable/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/durable.svg)](https://hex.pm/packages/durable)
[![HexDocs](https://img.shields.io/badge/hex-docs-8f75f0.svg)](https://hexdocs.pm/durable)
[![Downloads](https://img.shields.io/hexpm/dt/durable.svg)](https://hex.pm/packages/durable)
[![License](https://img.shields.io/hexpm/l/durable.svg)](https://github.com/wavezync/durable/blob/main/LICENSE)

A durable, resumable workflow engine for Elixir. Similar to Temporal/Inngest.

**Docs:** [durable.wavezync.com](https://durable.wavezync.com/docs/) ·
**Dashboard:** [`durable_dashboard`](https://hex.pm/packages/durable_dashboard) ·
**API:** [HexDocs](https://hexdocs.pm/durable)

## Features

- **Pipeline Model** - Context flows from step to step, simple and explicit
- **Resumability** - Sleep, wait for events, wait for human input
- **Branching** - Pattern-matched conditional flow control
- **Parallel** - Run steps concurrently with result collection
- **Compensations** - Saga pattern with automatic rollback
- **Cron Scheduling** - Recurring workflows with cron expressions
- **Reliability** - Automatic retries with exponential/linear/constant backoff
- **Orchestration** - Parent/child workflow composition
- **Persistence** - PostgreSQL-backed execution state

## Installation

```elixir
def deps do
  [{:durable, "~> 1.0"}]
end
```

## Quick Start

### 1. Create Migration

```elixir
defmodule MyApp.Repo.Migrations.AddDurable do
  use Ecto.Migration
  def up, do: Durable.Migration.up()
  def down, do: Durable.Migration.down()
end
```

When a Durable upgrade ships new internal migrations, generate a new wrapper
migration and run your normal Ecto migration flow:

```bash
mix durable.gen.upgrade -r MyApp.Repo
mix ecto.migrate
```

Use `mix durable.migrations -r MyApp.Repo --check` in CI or deploy gates to
fail when the database is behind the Durable library version.

### 2. Add to Supervision Tree

```elixir
children = [
  MyApp.Repo,
  {Durable, repo: MyApp.Repo, queues: %{default: [concurrency: 10]}}
]
```

### 3. Define & Run

```elixir
defmodule MyApp.OrderWorkflow do
  use Durable
  use Durable.Helpers

  workflow "process_order", timeout: hours(2) do
    # First step receives workflow input
    step :validate, fn input ->
      {:ok, %{
        order_id: input["id"],
        items: input["items"],
        customer_id: input["customer_id"]
      }}
    end

    # Each step receives previous step's output as context
    step :calculate_total, fn ctx ->
      total = ctx.items |> Enum.map(& &1["price"]) |> Enum.sum()
      {:ok, assign(ctx, :total, total)}
    end

    step :charge_payment, [retry: [max_attempts: 3, backoff: :exponential]], fn ctx ->
      {:ok, charge} = PaymentService.charge(ctx.order_id, ctx.total)
      {:ok, assign(ctx, :charge_id, charge.id)}
    end

    step :send_confirmation, fn ctx ->
      EmailService.send_confirmation(ctx.order_id)
      {:ok, ctx}
    end
  end
end

# Start it
{:ok, id} = Durable.start(MyApp.OrderWorkflow, %{"id" => "order_123", "items" => items})
```

## Examples

### Approval Workflow

Wait for human approval with timeout fallback.

```elixir
defmodule MyApp.ExpenseApproval do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "expense_approval" do
    step :request_approval, fn ctx ->
      result = wait_for_approval("manager",
        prompt: "Approve $#{ctx["amount"]} expense?",
        timeout: days(3),
        timeout_value: :auto_rejected
      )
      {:ok, assign(ctx, :decision, result)}
    end

    branch on: fn ctx -> ctx.decision end do
      :approved ->
        step :process, fn ctx ->
          Expenses.reimburse(ctx["employee_id"], ctx["amount"])
          {:ok, assign(ctx, :status, :reimbursed)}
        end

      _ ->
        step :notify_rejection, fn ctx ->
          Mailer.send_rejection(ctx["employee_id"])
          {:ok, assign(ctx, :status, :rejected)}
        end
    end
  end
end

# Approve externally
Durable.provide_input(workflow_id, "manager", :approved)
```

### Parallel Data Fetch

Fetch data concurrently, then combine results.

```elixir
defmodule MyApp.DashboardBuilder do
  use Durable
  use Durable.Helpers

  workflow "build_dashboard" do
    step :init, fn input ->
      {:ok, %{user_id: input["user_id"]}}
    end

    # Parallel steps produce results in __results__ map
    parallel do
      step :user, fn ctx ->
        {:ok, %{user: Users.get(ctx.user_id)}}
      end

      step :orders, fn ctx ->
        {:ok, %{orders: Orders.recent(ctx.user_id)}}
      end

      step :notifications, fn ctx ->
        {:ok, %{notifs: Notifications.unread(ctx.user_id)}}
      end
    end

    # Access results from __results__ map
    step :render, fn ctx ->
      results = ctx[:__results__]

      # Results are tagged tuples: ["ok", data] or ["error", reason]
      user = case results["user"] do
        ["ok", data] -> data.user
        _ -> nil
      end

      orders = case results["orders"] do
        ["ok", data] -> data.orders
        _ -> []
      end

      notifs = case results["notifications"] do
        ["ok", data] -> data.notifs
        _ -> []
      end

      dashboard = Dashboard.build(user, orders, notifs)
      {:ok, assign(ctx, :dashboard, dashboard)}
    end
  end
end

# Or use into: to transform results directly
defmodule MyApp.DashboardBuilderWithInto do
  use Durable
  use Durable.Helpers

  workflow "build_dashboard_v2" do
    step :init, fn input ->
      {:ok, %{user_id: input["user_id"]}}
    end

    parallel into: fn ctx, results ->
      # results contains tuples: %{user: {:ok, data}, orders: {:ok, data}, ...}
      case {results[:user], results[:orders], results[:notifications]} do
        {{:ok, user_data}, {:ok, orders_data}, {:ok, notifs_data}} ->
          {:ok, Map.merge(ctx, %{
            user: user_data.user,
            orders: orders_data.orders,
            notifs: notifs_data.notifs
          })}

        _ ->
          {:error, "Failed to fetch dashboard data"}
      end
    end do
      step :user, fn ctx -> {:ok, %{user: Users.get(ctx.user_id)}} end
      step :orders, fn ctx -> {:ok, %{orders: Orders.recent(ctx.user_id)}} end
      step :notifications, fn ctx -> {:ok, %{notifs: Notifications.unread(ctx.user_id)}} end
    end

    step :render, fn ctx ->
      dashboard = Dashboard.build(ctx.user, ctx.orders, ctx.notifs)
      {:ok, assign(ctx, :dashboard, dashboard)}
    end
  end
end
```

### Batch Processing

Process items with controlled concurrency using `Task.async_stream`.

```elixir
defmodule MyApp.BulkEmailer do
  use Durable
  use Durable.Helpers

  workflow "send_campaign" do
    step :load, fn input ->
      recipients = Subscribers.active(input["campaign_id"])
      {:ok, %{campaign_id: input["campaign_id"], recipients: recipients}}
    end

    step :send_emails, fn ctx ->
      results =
        ctx.recipients
        |> Task.async_stream(
          fn recipient ->
            case Mailer.send_campaign(recipient, ctx.campaign_id) do
              :ok -> {:ok, recipient}
              {:error, reason} -> {:error, {recipient, reason}}
            end
          end,
          max_concurrency: 10,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, r} -> r end)

      sent = for {:ok, _} <- results, do: 1
      failed = for {:error, _} <- results, do: 1

      {:ok, ctx
      |> assign(:sent_count, length(sent))
      |> assign(:failed_count, length(failed))}
    end
  end
end
```

### Trip Booking (Saga)

Book multiple services with automatic rollback on failure.

```elixir
defmodule MyApp.TripBooking do
  use Durable
  use Durable.Helpers

  workflow "book_trip" do
    step :book_flight, [compensate: :cancel_flight], fn ctx ->
      booking = Flights.book(ctx["flight"])
      {:ok, assign(ctx, :flight, booking)}
    end

    step :book_hotel, [compensate: :cancel_hotel], fn ctx ->
      booking = Hotels.book(ctx["hotel"])
      {:ok, assign(ctx, :hotel, booking)}
    end

    step :charge, fn ctx ->
      total = ctx.flight.price + ctx.hotel.price
      Payments.charge(ctx["card"], total)
      {:ok, assign(ctx, :charged, true)}
    end

    compensate :cancel_flight, fn ctx ->
      Flights.cancel(ctx.flight.id)
      {:ok, ctx}
    end

    compensate :cancel_hotel, fn ctx ->
      Hotels.cancel(ctx.hotel.id)
      {:ok, ctx}
    end
  end
end
```

### Scheduled Reports

Run daily at 9am.

```elixir
defmodule MyApp.DailyReport do
  use Durable
  use Durable.Helpers
  use Durable.Scheduler.DSL

  @schedule cron: "0 9 * * *", timezone: "America/New_York"
  workflow "daily_sales_report" do
    step :generate, fn _input ->
      report = Reports.sales_summary(Date.utc_today())
      {:ok, %{report: report}}
    end

    step :distribute, fn ctx ->
      Mailer.send_report(ctx.report, to: "team@company.com")
      Slack.post_summary(ctx.report, channel: "#sales")
      {:ok, ctx}
    end
  end
end

# Register in supervision tree
{Durable, repo: MyApp.Repo, scheduled_modules: [MyApp.DailyReport]}
```

### Delayed & Scheduled Execution

Sleep, schedule for specific times, and wait for events.

```elixir
defmodule MyApp.TrialReminder do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "trial_reminder" do
    step :welcome, fn ctx ->
      Mailer.send_welcome(ctx["user_id"])
      {:ok, %{user_id: ctx["user_id"], trial_started_at: ctx["trial_started_at"]}}
    end

    step :wait_3_days, fn ctx ->
      sleep(days(3))
      {:ok, ctx}
    end

    step :check_in, fn ctx ->
      Mailer.send_tips(ctx.user_id)
      {:ok, ctx}
    end

    step :wait_until_trial_ends, fn ctx ->
      trial_end = DateTime.add(ctx.trial_started_at, 14, :day)
      schedule_at(trial_end)
      {:ok, ctx}
    end

    step :convert_or_remind, fn ctx ->
      if Subscriptions.active?(ctx.user_id) do
        {:ok, assign(ctx, :converted, true)}
      else
        Mailer.send_upgrade_reminder(ctx.user_id)
        {:ok, assign(ctx, :converted, false)}
      end
    end
  end
end
```

### Event-Driven Workflow

Wait for external webhook events.

```elixir
defmodule MyApp.PaymentFlow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "payment_flow" do
    step :create_invoice, fn ctx ->
      invoice = Invoices.create(ctx["order_id"], ctx["amount"])
      {:ok, %{order_id: ctx["order_id"], invoice_id: invoice.id}}
    end

    step :await_payment, fn ctx ->
      {event, _payload} = wait_for_any(["payment.success", "payment.failed"],
        timeout: days(7),
        timeout_value: {"payment.expired", nil}
      )
      {:ok, assign(ctx, :result, event)}
    end

    branch on: fn ctx -> ctx.result end do
      "payment.success" ->
        step :fulfill, fn ctx ->
          Orders.fulfill(ctx.order_id)
          {:ok, assign(ctx, :status, :fulfilled)}
        end

      _ ->
        step :cancel, fn ctx ->
          Orders.cancel(ctx.order_id)
          {:ok, assign(ctx, :status, :cancelled)}
        end
    end
  end
end

# Webhook handler sends event
Durable.send_event(workflow_id, "payment.success", %{transaction_id: "txn_123"})
```

## Reference

### Helper Functions

```elixir
use Durable.Helpers

assign(ctx, :key, value)    # Set a value
assign(ctx, %{a: 1, b: 2})  # Merge multiple values
update(ctx, :key, default, fn old -> new end)
append(ctx, :list, item)    # Append to list
increment(ctx, :count)      # Increment by 1
increment(ctx, :count, 5)   # Increment by 5
```

### Time Helpers

```elixir
seconds(30)   # 30_000 ms
minutes(5)    # 300_000 ms
hours(2)      # 7_200_000 ms
days(7)       # 604_800_000 ms
```

### Orchestration

```elixir
use Durable.Orchestration

# Synchronous: call child and wait for result
case call_workflow(MyApp.PaymentWorkflow, %{"amount" => 100}, timeout: hours(1)) do
  {:ok, result} -> {:ok, assign(data, :payment, result)}
  {:error, reason} -> {:error, reason}
end

# Fire-and-forget: start child and continue
{:ok, child_id} = start_workflow(MyApp.EmailWorkflow, %{"to" => email}, ref: :welcome)

# call_workflow also works inside parallel blocks (executed inline)
parallel do
  step :payment, fn data ->
    case call_workflow(MyApp.PaymentWorkflow, %{"amount" => data.total}, ref: :pay) do
      {:ok, result} -> {:ok, assign(data, :payment, result)}
      {:error, reason} -> {:error, reason}
    end
  end

  step :shipping, fn data ->
    case call_workflow(MyApp.ShippingWorkflow, %{"id" => data.order_id}, ref: :ship) do
      {:ok, result} -> {:ok, assign(data, :shipping, result)}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Workflow Options

```elixir
workflow "process_order", timeout: hours(2), queue: :orders do
```

- `:timeout` — how long a run may take from when it's due to start, waits and
  sleeps included. A run past it fails with a `"timeout"` error before its next
  step and runs its compensations; a waiting run is woken to do so (within the
  timeout worker's one-minute sweep). It can't interrupt a step that's running.
- `:queue` — the queue runs start on unless `Durable.start/3` names one.

Unknown options fail the compile.

### Errors

When a step fails, its execution keeps what went wrong as `error`:

- **Raised** (`raise`, a crash in a library) — `type` (the exception
  module), `message`, and `stacktrace`: one frame per line with the app,
  file and line, e.g. `(my_app 0.1.0) lib/my_app/orders.ex:28: ...`.
- **Exited** (a `GenServer.call` timeout, a linked process going down) —
  `type: "exit"`, a readable `message` (`Exception.format_exit/1`) and the
  `stacktrace`. Throws are kept the same way.
- **Returned** — `{:error, reason}` from the step: `reason` itself (a map is
  stored as-is), with no stack, because nothing was raised.

The same applies to compensations and to a branch's `on:` function. A
failed run's `error` is its failing step's. The stack is as deep as the
VM's `:backtrace_depth` (8 frames by default; Phoenix dev raises it to 20).

### API

```elixir
Durable.start(Module, input)
Durable.start(Module, input, queue: :priority, scheduled_at: datetime)
Durable.get_execution(id)
Durable.list_executions(workflow: Module, status: :running)
Durable.cancel(id, "reason")
Durable.send_event(id, "event", payload)
Durable.provide_input(id, "input_name", data)
Durable.list_children(parent_id)

# Operating
Durable.retry(id)                        # failed run: resume from the failed step
Durable.rerun(id, input: new_input)      # finished run: start a fresh copy
Durable.pause_queue(:default, by: user)  # on every node, until resume_queue/2
Durable.list_nodes()                     # heartbeating instances and what they run
Durable.prune()                          # apply the :prune retention now

# Observing
Durable.Stats.overview(since: dt)        # also timeline/1, workflows/1, step_performance/1,
                                         # queues/1, queue_history/1, error_groups/1
Durable.Activity.list()                  # recovered runs, fenced workers, queue pauses…
```

Telemetry events and `Telemetry.Metrics` definitions are documented in
`Durable.Telemetry`.

## Mix Tasks

Durable includes mix tasks for managing workflows from the command line.

```bash
# Show queue status and workflow summary
mix durable.status

# List workflow executions (with filters)
mix durable.list                                         # all executions
mix durable.list --status running                        # filter by status
mix durable.list --workflow MyApp.OrderWorkflow           # filter by workflow
mix durable.list --limit 20 --format json                # limit results, JSON output

# Start a workflow
mix durable.run MyApp.OrderWorkflow                      # no input
mix durable.run MyApp.OrderWorkflow --input '{"id": 123}' # with JSON input
mix durable.run MyApp.OrderWorkflow --queue high_priority  # specific queue

# Cancel a workflow
mix durable.cancel <execution_id>
mix durable.cancel <execution_id> --reason "no longer needed"

# Clean up old executions
mix durable.cleanup --older-than 30d                     # completed/failed older than 30 days
mix durable.cleanup --older-than 7d --status completed   # only completed, older than 7 days
mix durable.cleanup --older-than 24h --dry-run           # preview what would be deleted
```

## Dashboard

[![Hex.pm](https://img.shields.io/hexpm/v/durable_dashboard.svg)](https://hex.pm/packages/durable_dashboard)
[![HexDocs](https://img.shields.io/badge/hex-docs-8f75f0.svg)](https://hexdocs.pm/durable_dashboard)

`durable_dashboard` is a LiveView-first console for monitoring and managing
running workflows. Mount it into your Phoenix router with one line:

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  # ...your existing pipelines and scopes...

  use DurableDashboard.Router, mount: "/dashboard", durable: MyApp.Durable
end
```

The macro adds the dashboard's pipelines, asset routes, and live routes
in-place — no `forward`, no extra endpoint. You get:

- Overview with live status counts and recent executions
- Workflow catalog + an Executions list with a faceted filter bar (workflow,
  status, time range, execution id) driven by shareable URL params
- Execution detail with Summary, ReactFlow graph, Timeline, Logs, I/O, and
  History trace (plus a Family tab for parent/child runs)
- Pending inputs queue
- Schedules list with toggle / trigger actions
- Settings view
- ⌘K command palette — jump to any page, workflow, or recent run

See the [durable_dashboard docs](https://hexdocs.pm/durable_dashboard) for the full
option list and design notes.

## Guides

- [Branching](guides/branching.md) - Conditional flow control
- [Parallel](guides/parallel.md) - Concurrent execution
- [Compensations](guides/compensations.md) - Saga pattern
- [Waiting](guides/waiting.md) - Sleep, events, human input
- [Orchestration](guides/orchestration.md) - Parent/child workflow composition

## License

MIT
