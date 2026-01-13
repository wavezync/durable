# Durable

[![Build Status](https://github.com/wavezync/durable/actions/workflows/ci.yml/badge.svg)](https://github.com/wavezync/durable/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/durable.svg)](https://hex.pm/packages/durable)

A durable, resumable workflow engine for Elixir. Similar to Temporal/Inngest.

## Features

- **Pipeline Model** - Data flows from step to step, simple and explicit
- **Resumability** - Sleep, wait for events, wait for human input
- **Branching** - Pattern-matched conditional flow control
- **Parallel** - Run steps concurrently with merge strategies
- **ForEach** - Process collections with configurable concurrency
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
    step :validate, fn order ->
      {:ok, %{
        order_id: order["id"],
        items: order["items"],
        customer_id: order["customer_id"]
      }}
    end

    # Each step receives previous step's output
    step :calculate_total, fn data ->
      total = data.items |> Enum.map(& &1["price"]) |> Enum.sum()
      {:ok, assign(data, :total, total)}
    end

    step :charge_payment, [retry: [max_attempts: 3, backoff: :exponential]], fn data ->
      {:ok, charge} = PaymentService.charge(data.order_id, data.total)
      {:ok, assign(data, :charge_id, charge.id)}
    end

    step :send_confirmation, fn data ->
      EmailService.send_confirmation(data.order_id)
      {:ok, data}
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
    step :request_approval, fn data ->
      result = wait_for_approval("manager",
        prompt: "Approve $#{data["amount"]} expense?",
        timeout: days(3),
        timeout_value: :auto_rejected
      )
      {:ok, assign(data, :decision, result)}
    end

    branch on: fn data -> data.decision end do
      :approved ->
        step :process, fn data ->
          Expenses.reimburse(data["employee_id"], data["amount"])
          {:ok, assign(data, :status, :reimbursed)}
        end

      _ ->
        step :notify_rejection, fn data ->
          Mailer.send_rejection(data["employee_id"])
          {:ok, assign(data, :status, :rejected)}
        end
    end
  end
end

# Approve externally
Durable.provide_input(workflow_id, "manager", :approved)
```

### Parallel Data Fetch

Fetch data concurrently, then combine.

```elixir
defmodule MyApp.DashboardBuilder do
  use Durable
  use Durable.Helpers

  workflow "build_dashboard" do
    step :init, fn input ->
      {:ok, %{user_id: input["user_id"]}}
    end

    parallel do
      step :user, fn data ->
        {:ok, assign(data, :user, Users.get(data.user_id))}
      end

      step :orders, fn data ->
        {:ok, assign(data, :orders, Orders.recent(data.user_id))}
      end

      step :notifications, fn data ->
        {:ok, assign(data, :notifs, Notifications.unread(data.user_id))}
      end
    end

    step :render, fn data ->
      dashboard = Dashboard.build(data.user, data.orders, data.notifs)
      {:ok, assign(data, :dashboard, dashboard)}
    end
  end
end
```

### Batch Processing

Process items with controlled concurrency.

```elixir
defmodule MyApp.BulkEmailer do
  use Durable
  use Durable.Helpers

  workflow "send_campaign" do
    step :load, fn input ->
      recipients = Subscribers.active(input["campaign_id"])
      {:ok, %{campaign_id: input["campaign_id"], recipients: recipients}}
    end

    foreach :send_emails,
      items: fn data -> data.recipients end,
      concurrency: 10,
      on_error: :continue do

      # Foreach steps receive (data, item, index)
      step :send, fn data, recipient, _idx ->
        Mailer.send_campaign(recipient, data.campaign_id)
        {:ok, increment(data, :sent_count)}
      end
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
    step :book_flight, [compensate: :cancel_flight], fn data ->
      booking = Flights.book(data["flight"])
      {:ok, assign(data, :flight, booking)}
    end

    step :book_hotel, [compensate: :cancel_hotel], fn data ->
      booking = Hotels.book(data["hotel"])
      {:ok, assign(data, :hotel, booking)}
    end

    step :charge, fn data ->
      total = data.flight.price + data.hotel.price
      Payments.charge(data["card"], total)
      {:ok, assign(data, :charged, true)}
    end

    compensate :cancel_flight, fn data ->
      Flights.cancel(data.flight.id)
      {:ok, data}
    end

    compensate :cancel_hotel, fn data ->
      Hotels.cancel(data.hotel.id)
      {:ok, data}
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

    step :distribute, fn data ->
      Mailer.send_report(data.report, to: "team@company.com")
      Slack.post_summary(data.report, channel: "#sales")
      {:ok, data}
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
    step :welcome, fn data ->
      Mailer.send_welcome(data["user_id"])
      {:ok, %{user_id: data["user_id"], trial_started_at: data["trial_started_at"]}}
    end

    step :wait_3_days, fn data ->
      sleep(days(3))
      {:ok, data}
    end

    step :check_in, fn data ->
      Mailer.send_tips(data.user_id)
      {:ok, data}
    end

    step :wait_until_trial_ends, fn data ->
      trial_end = DateTime.add(data.trial_started_at, 14, :day)
      schedule_at(trial_end)
      {:ok, data}
    end

    step :convert_or_remind, fn data ->
      if Subscriptions.active?(data.user_id) do
        {:ok, assign(data, :converted, true)}
      else
        Mailer.send_upgrade_reminder(data.user_id)
        {:ok, assign(data, :converted, false)}
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
    step :create_invoice, fn data ->
      invoice = Invoices.create(data["order_id"], data["amount"])
      {:ok, %{order_id: data["order_id"], invoice_id: invoice.id}}
    end

    step :await_payment, fn data ->
      {event, _payload} = wait_for_any(["payment.success", "payment.failed"],
        timeout: days(7),
        timeout_value: {"payment.expired", nil}
      )
      {:ok, assign(data, :result, event)}
    end

    branch on: fn data -> data.result end do
      "payment.success" ->
        step :fulfill, fn data ->
          Orders.fulfill(data.order_id)
          {:ok, assign(data, :status, :fulfilled)}
        end

      _ ->
        step :cancel, fn data ->
          Orders.cancel(data.order_id)
          {:ok, assign(data, :status, :cancelled)}
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

assign(data, :key, value)    # Set a value
assign(data, %{a: 1, b: 2})  # Merge multiple values
update(data, :key, default, fn old -> new end)
append(data, :list, item)    # Append to list
increment(data, :count)      # Increment by 1
increment(data, :count, 5)   # Increment by 5
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
- [ForEach](guides/foreach.md) - Collection processing
- [Compensations](guides/compensations.md) - Saga pattern
- [Waiting](guides/waiting.md) - Sleep, events, human input

## Coming Soon

- Workflow orchestration (parent/child workflows)
- Phoenix LiveView dashboard

## License

MIT
