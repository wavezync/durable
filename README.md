# Durable

[![Build Status](https://github.com/wavezync/durable/actions/workflows/ci.yml/badge.svg)](https://github.com/wavezync/durable/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/durable.svg)](https://hex.pm/packages/durable)

A durable, resumable workflow engine for Elixir. Similar to Temporal/Inngest.

## Features

- **Pipeline Model** - Context flows from step to step, simple and explicit
- **Resumability** - Sleep, wait for events, wait for human input
- **Branching** - Pattern-matched conditional flow control
- **Parallel** - Run steps concurrently with result collection
- **Compensations** - Saga pattern with automatic rollback
- **Cron Scheduling** - Recurring workflows with cron expressions
- **Reliability** - Automatic retries with exponential/linear/constant backoff
- **Persistence** - PostgreSQL-backed execution state

## Installation

```elixir
def deps do
  [{:durable, "~> 0.0.0-alpha"}]
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

### API

```elixir
Durable.start(Module, input)
Durable.start(Module, input, queue: :priority, scheduled_at: datetime)
Durable.get_execution(id)
Durable.list_executions(workflow: Module, status: :running)
Durable.cancel(id, "reason")
Durable.send_event(id, "event", payload)
Durable.provide_input(id, "input_name", data)
```

## Guides

- [Branching](guides/branching.md) - Conditional flow control
- [Parallel](guides/parallel.md) - Concurrent execution
- [Compensations](guides/compensations.md) - Saga pattern
- [Waiting](guides/waiting.md) - Sleep, events, human input

## Coming Soon

- Workflow orchestration (parent/child workflows)
- Phoenix LiveView dashboard

## License

MIT
