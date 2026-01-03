# Durable

[![Build Status](https://github.com/wavezync/durable/actions/workflows/ci.yml/badge.svg)](https://github.com/wavezync/durable/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/durable.svg)](https://hex.pm/packages/durable)

A durable, resumable workflow engine for Elixir. Similar to Temporal/Inngest.

## Features

- **Declarative DSL** - Clean macro-based workflow definitions
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
  use Durable.Context

  workflow "process_order" do
    step :charge, retry: [max_attempts: 3, backoff: :exponential] do
      {:ok, charge} = Payments.charge(input().order)
      put_context(:charge_id, charge.id)
    end

    step :notify do
      Mailer.send_receipt(input().email, get_context(:charge_id))
    end
  end
end

# Start it
{:ok, id} = Durable.start(MyApp.OrderWorkflow, %{order: order, email: "user@example.com"})
```

## Examples

### Approval Workflow

Wait for human approval with timeout fallback.

```elixir
defmodule MyApp.ExpenseApproval do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "expense_approval" do
    step :request_approval do
      result = wait_for_approval("manager",
        prompt: "Approve $#{input().amount} expense?",
        timeout: days(3),
        timeout_value: :auto_rejected
      )
      put_context(:decision, result)
    end

    branch on: get_context(:decision) do
      :approved -> step :process, do: Expenses.reimburse(input().employee_id, input().amount)
      _ -> step :notify_rejection, do: Mailer.send_rejection(input().employee_id)
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
  use Durable.Context

  workflow "build_dashboard" do
    parallel do
      step :user, do: put_context(:user, Users.get(input().user_id))
      step :orders, do: put_context(:orders, Orders.recent(input().user_id))
      step :notifications, do: put_context(:notifs, Notifications.unread(input().user_id))
    end

    step :render do
      Dashboard.build(get_context(:user), get_context(:orders), get_context(:notifs))
    end
  end
end
```

### Batch Processing

Process items with controlled concurrency.

```elixir
defmodule MyApp.BulkEmailer do
  use Durable
  use Durable.Context

  workflow "send_campaign" do
    step :load do
      put_context(:recipients, Subscribers.active(input().campaign_id))
    end

    foreach :send_emails, items: :recipients, concurrency: 10, on_error: :continue do
      step :send do
        Mailer.send_campaign(current_item(), input().campaign_id)
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
  use Durable.Context

  workflow "book_trip" do
    step :book_flight, compensate: :cancel_flight do
      put_context(:flight, Flights.book(input().flight))
    end

    step :book_hotel, compensate: :cancel_hotel do
      put_context(:hotel, Hotels.book(input().hotel))
    end

    step :charge do
      total = get_context(:flight).price + get_context(:hotel).price
      Payments.charge(input().card, total)
    end

    compensate :cancel_flight, do: Flights.cancel(get_context(:flight).id)
    compensate :cancel_hotel, do: Hotels.cancel(get_context(:hotel).id)
  end
end
```

### Scheduled Reports

Run daily at 9am.

```elixir
defmodule MyApp.DailyReport do
  use Durable
  use Durable.Scheduler.DSL
  use Durable.Context

  @schedule cron: "0 9 * * *", timezone: "America/New_York"
  workflow "daily_sales_report" do
    step :generate do
      report = Reports.sales_summary(Date.utc_today())
      put_context(:report, report)
    end

    step :distribute do
      Mailer.send_report(get_context(:report), to: "team@company.com")
      Slack.post_summary(get_context(:report), channel: "#sales")
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
  use Durable.Context
  use Durable.Wait

  workflow "trial_reminder" do
    step :welcome do
      Mailer.send_welcome(input().user_id)
    end

    step :wait_3_days do
      sleep(days(3))
    end

    step :check_in do
      Mailer.send_tips(input().user_id)
    end

    step :wait_until_trial_ends do
      trial_end = DateTime.add(input().trial_started_at, 14, :day)
      schedule_at(trial_end)
    end

    step :convert_or_remind do
      if Subscriptions.active?(input().user_id) do
        put_context(:converted, true)
      else
        Mailer.send_upgrade_reminder(input().user_id)
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
  use Durable.Context
  use Durable.Wait

  workflow "payment_flow" do
    step :create_invoice do
      invoice = Invoices.create(input().order_id, input().amount)
      put_context(:invoice_id, invoice.id)
    end

    step :await_payment do
      {event, _payload} = wait_for_any(["payment.success", "payment.failed"],
        timeout: days(7),
        timeout_value: {"payment.expired", nil}
      )
      put_context(:result, event)
    end

    branch on: get_context(:result) do
      "payment.success" -> step :fulfill, do: Orders.fulfill(input().order_id)
      _ -> step :cancel, do: Orders.cancel(input().order_id)
    end
  end
end

# Webhook handler sends event
Durable.send_event(workflow_id, "payment.success", %{transaction_id: "txn_123"})
```

## Reference

### Context

```elixir
input()                       # Initial workflow input
get_context(:key)             # Get value
get_context(:key, default)    # With default
put_context(:key, value)      # Set value
append_context(:list, item)   # Append to list
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
