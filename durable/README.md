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
- **Compensations** - Saga pattern: undo completed steps when a step or you ask
- **Cron Scheduling** - Recurring workflows with cron expressions
- **Reliability** - Automatic retries with exponential/linear/constant backoff, waiting off the worker
- **Run control** - Snooze, fail now or cancel from a step
- **Step queues** - Give a step its own queue and concurrency limit
- **Bulk starts and tags** - Start many runs in one transaction, then find or cancel them by tag
- **Orchestration** - Parent/child workflow composition
- **Workflow keys** - At most one run per key, so duplicate starts return the existing run
- **Persistence** - PostgreSQL-backed execution state

## Installation

```elixir
def deps do
  [{:durable, "~> 2.0"}]
end
```

Durable needs PostgreSQL 13 or newer.

### Upgrading from 1.x

2.0 can't share a database with 1.x nodes. Run the new migration, **stop every
node on 1.x**, and only then start nodes on 2.0. Runs in flight carry on. The
functions that read (`list_executions/1` and the rest) now return
`{:ok, result}`, with a `!` twin for the bare result. Read
[Upgrade Durable](guides/production.md#upgrade-durable) before you deploy: it
has the steps and everything else that changed.

### Upgrading to 2.0.1

A workflow's data now has string keys in every step, at every depth. Before, a
key a step added as an atom was read as `data.total` in later steps. Change
`data.total` to `data["total"]` or `get(data, :total)`, match
`%{"total" => total}` instead of `%{total: total}`, and compare a stored value
with a string (`data["status"] == "approved"`, not `:approved`). No migration,
and runs in flight carry on. See
[From 2.0.0 to 2.0.1](guides/production.md#from-200-to-201).

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
    # First step receives workflow input. Its keys are strings, and stay strings.
    step :validate, fn input ->
      if input["items"] == [],
        do: {:fail, "the order has no items"},
        else: {:ok, assign(input, :order_id, input["id"])}
    end

    # Each step receives what the steps before it returned
    step :calculate_total, fn ctx ->
      total = ctx["items"] |> Enum.map(& &1["price"]) |> Enum.sum()
      {:ok, assign(ctx, :total, total)}
    end

    step :charge_payment, [retry: [max_attempts: 3, backoff: :exponential]], fn ctx ->
      {:ok, charge} = PaymentService.charge(ctx["order_id"], ctx["total"])
      {:ok, assign(ctx, :charge_id, charge.id)}
    end

    step :send_confirmation, fn ctx ->
      EmailService.send_confirmation(ctx["order_id"])
      {:ok, ctx}
    end
  end
end

# Start it
{:ok, id} = Durable.start(MyApp.OrderWorkflow, %{"id" => "order_123", "items" => items})
```

A run's data is saved as JSON after every step, and every step is handed it
as it is stored, whether the run went straight on or was loaded again after a
wait, a retry or a move to another node. So:

- Keys are strings, at every depth: read them as `get(ctx, :id)` or
  `ctx["id"]`. `ctx.id` and `%{id: id} = ctx` never match.
- A step can return a map written with atom keys, and the helpers take a key
  as an atom or a string: `assign(ctx, :total, total)` sets `ctx["total"]`.
- Values come back as JSON holds them: an atom is a string (`:paid` is
  `"paid"`), a tuple is a list, a `DateTime` is ISO 8601 text, a struct is a
  map.

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
      answer = wait_for_approval("manager",
        prompt: "Approve $#{ctx["amount"]} expense?",
        timeout: days(3),
        timeout_value: :no_answer
      )

      # An answer comes back from storage, so its keys are strings.
      # The timeout value comes back exactly as written above.
      decision =
        case answer do
          %{"approved" => true} -> "approved"
          %{"approved" => false} -> "rejected"
          :no_answer -> "auto_rejected"
        end

      {:ok, assign(ctx, :decision, decision)}
    end

    branch on: fn ctx -> ctx["decision"] end do
      "approved" ->
        step :process, fn ctx ->
          Expenses.reimburse(ctx["employee_id"], ctx["amount"])
          {:ok, assign(ctx, :status, "reimbursed")}
        end

      _ ->
        step :notify_rejection, fn ctx ->
          Mailer.send_rejection(ctx["employee_id"])
          {:ok, assign(ctx, :status, "rejected")}
        end
    end
  end
end

# Approve from your code. The dashboard's Inbox sends the same answer.
Durable.provide_input(workflow_id, "manager", %{"approved" => true})
```

### Parallel Data Fetch

Fetch data concurrently, then combine results.

```elixir
defmodule MyApp.DashboardBuilder do
  use Durable
  use Durable.Helpers

  workflow "build_dashboard" do
    # Don't fan out for a user that doesn't exist
    step :init, fn input ->
      if Users.exists?(input["user_id"]),
        do: {:ok, input},
        else: {:fail, "no such user"}
    end

    # Each lookup is a lane of its own; none depends on another
    parallel :lookups do
      step :user, fn ctx ->
        {:ok, %{profile: Users.get(ctx["user_id"])}}
      end

      step :orders, fn ctx ->
        {:ok, %{recent: Orders.recent(ctx["user_id"])}}
      end

      # The page can be built without these
      step :notifications, [optional: true, default: %{unread: []}], fn ctx ->
        {:ok, %{unread: Notifications.unread(ctx["user_id"])}}
      end
    end

    # What each lane produced is under the block's name, by lane
    step :render, fn %{"lookups" => %{"user" => user, "orders" => orders, "notifications" => notifs}} = ctx ->
      dashboard = Dashboard.build(user["profile"], orders["recent"], notifs["unread"])
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
      {:ok, assign(input, :recipients, recipients)}
    end

    step :send_emails, fn ctx ->
      results =
        ctx["recipients"]
        |> Task.async_stream(
          fn recipient ->
            case Mailer.send_campaign(recipient, ctx["campaign_id"]) do
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

Book multiple services, and undo the bookings if the card is declined.

```elixir
defmodule MyApp.TripBooking do
  use Durable
  use Durable.Helpers

  workflow "book_trip" do
    step :book_flight, [compensate: :cancel_flight], fn ctx ->
      booking = Flights.book(ctx["flight"])
      {:ok, ctx |> assign(:flight_booking, booking.id) |> assign(:flight_price, booking.price)}
    end

    step :book_hotel, [compensate: :cancel_hotel], fn ctx ->
      booking = Hotels.book(ctx["hotel"])
      {:ok, ctx |> assign(:hotel_booking, booking.id) |> assign(:hotel_price, booking.price)}
    end

    step :charge, fn ctx ->
      total = ctx["flight_price"] + ctx["hotel_price"]

      case Payments.charge(ctx["card"], total) do
        {:ok, _receipt} -> {:ok, assign(ctx, :charged, true)}
        {:error, :declined} -> {:rollback, "card declined"}
        {:error, reason} -> {:error, reason}
      end
    end

    compensate :cancel_flight, fn ctx ->
      Flights.cancel(ctx["flight_booking"])
      {:ok, ctx}
    end

    compensate :cancel_hotel, fn ctx ->
      Hotels.cancel(ctx["hotel_booking"])
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
      Mailer.send_report(ctx["report"], to: "team@company.com")
      Slack.post_summary(ctx["report"], channel: "#sales")
      {:ok, ctx}
    end
  end
end

# Register in supervision tree
{Durable, repo: MyApp.Repo, scheduled_modules: [MyApp.DailyReport]}
```

A time zone other than UTC needs a time zone database, which Elixir doesn't ship with. Add [`tzdata`](https://hex.pm/packages/tzdata) and set `config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase`.

Add `key: "daily_sales_report"` to `@schedule` so a fire while the last run
is still going doesn't start a second copy. See
[Workflow keys](guides/workflow_keys.md#cron-schedules).

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
      {:ok, ctx}
    end

    step :wait_3_days, fn ctx ->
      sleep(days(3))
      {:ok, ctx}
    end

    step :check_in, fn ctx ->
      Mailer.send_tips(ctx["user_id"])
      {:ok, ctx}
    end

    step :wait_until_trial_ends, fn ctx ->
      # The input is JSON, so the time is ISO 8601 text
      {:ok, started_at, _offset} = DateTime.from_iso8601(ctx["trial_started_at"])
      trial_end = DateTime.add(started_at, 14, :day)
      schedule_at(trial_end)
      {:ok, ctx}
    end

    step :convert_or_remind, fn ctx ->
      if Subscriptions.active?(ctx["user_id"]) do
        {:ok, assign(ctx, :converted, true)}
      else
        Mailer.send_upgrade_reminder(ctx["user_id"])
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
      {:ok, assign(ctx, :invoice_id, invoice.id)}
    end

    step :await_payment, fn ctx ->
      {event, _payload} = wait_for_any(["payment.success", "payment.failed"],
        timeout: days(7),
        timeout_value: {"payment.expired", nil}
      )
      {:ok, assign(ctx, :result, event)}
    end

    branch on: fn ctx -> ctx["result"] end do
      "payment.success" ->
        step :fulfill, fn ctx ->
          Orders.fulfill(ctx["order_id"])
          {:ok, assign(ctx, :status, "fulfilled")}
        end

      _ ->
        step :cancel, fn ctx ->
          Orders.cancel(ctx["order_id"])
          {:ok, assign(ctx, :status, "cancelled")}
        end
    end
  end
end

# Webhook handler sends event
Durable.send_event(workflow_id, "payment.success", %{transaction_id: "txn_123"})
```

## Reference

### Helper Functions

**Best practice: read and write a workflow's data through the helpers.** They
take a key as an atom, the way Elixir code usually names one, and use the
string key the data is stored with. `ctx.total` and `ctx[:total]` don't read
it; `get(ctx, :total)` does, in every step.

```elixir
use Durable.Helpers

# A key is an atom or a string; the data's own keys are strings
get(ctx, :key)              # Read a value: ctx["key"]
get(ctx, [:user, :email])   # Read inside it: ctx["user"]["email"]
get(ctx, :key, default)     # With a default
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

# call_workflow also works inside parallel blocks: each lane waits for its child
parallel :fulfil do
  step :payment, fn data ->
    case call_workflow(MyApp.PaymentWorkflow, %{"amount" => data["total"]}, ref: :pay) do
      {:ok, result} -> {:ok, assign(data, :payment, result)}
      {:error, reason} -> {:error, reason}
    end
  end

  step :shipping, fn data ->
    case call_workflow(MyApp.ShippingWorkflow, %{"id" => data["order_id"]}, ref: :ship) do
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
  sleeps included. A run past it fails with a `"timeout"` error: a step still
  running is stopped, and a waiting run is woken to fail (within the timeout
  worker's one-minute sweep).
- `:on_failure` — `:halt` (default) leaves a failed run as it is, to retry or
  to undo with `Durable.rollback/2`. `:rollback` runs its compensations on any
  failure. `[rollback_after: days(5)]` halts, then rolls back a run nobody
  retried or rolled back in that time. See [Compensations](guides/compensations.md).
- `:queue` — the queue runs start on unless `Durable.start/3` names one. A
  step's own `queue:` moves the run for that step (see
  [Step Queues](#step-queues)).
- `:reuse` — whether a `key:` can start again after its run finished:
  `:after_close` (default), `:after_failure` or `:never`. See
  [Workflow keys](guides/workflow_keys.md).
- `:on_duplicate` — what a start with a taken key does unless the call says:
  `:use_existing` (default, the holder's id), `:error`
  (`{:error, {:key_taken, id}}`), `:cancel_existing` (replace the running
  holder) or `{:send_event, name}` (send it the new input as an event).
- `:debounce` — `[period: ms, timeout: ms]`: keyed starts wait `period`, and
  repeats in that time give the waiting run the newest input.

Unknown options fail the compile.

A definition that can't run doesn't compile either. Each of these is a
`CompileError` that names the step or the workflow:

- a `retry:` that isn't a keyword list, or a `max_attempts`, `backoff`, `base`
  or `max_backoff` in it that can't be used
- a step `timeout:` that isn't a positive number of milliseconds
- a step name that isn't an atom
- a `compensate:` that names no `compensate` in the workflow
- a workflow name that isn't a non-empty string written in place, or the same
  name twice in a module
- a workflow `timeout:` given as a string or a float

What compiles but would be ignored is a warning at its line, so it fails a
`--warnings-as-errors` build: an option a step, a `retry:` or a `compensate`
doesn't take (`retries:` gets a did-you-mean), and a workflow `timeout:` of 0,
a negative number or `:infinity`, which all mean no timeout.

### Retries

```elixir
use Durable.Context

step :charge, [retry: [max_attempts: 5, backoff: :exponential]], fn ctx ->
  attempt()        # 1..5
  max_attempts()   # 5
  last_attempt?()  # true on attempt 5: an error now fails the step
  ...
end
```

A step without `retry:` gets one attempt. An attempt whose process dies
counts like any other. Losing the node or the lock doesn't use one: the step
runs again, and the run fails after losing its worker three times. The count
carries over when a run resumes after a crash, and starts again after
`Durable.retry/2`.

A step that finished isn't run again. If its worker was lost after the step's
row was written, the run takes the result from the row, `put_context` writes
included. A worker lost inside the step's body runs the step again, so a step
with an effect outside your database still has to be safe to repeat.

Between attempts the run is parked: it goes back on its queue until the
backoff has passed (up to `max_backoff`, 1 hour by default), so a long wait
holds no worker.

To wait and try again without using an attempt, snooze:

```elixir
step :export, fn ctx ->
  if Exports.running?(ctx["account_id"]),
    do: {:snooze, seconds(60), "another export is running"},
    else: {:ok, assign(ctx, :file, Exports.run(ctx["account_id"]))}
end
```

When retrying won't help, stop now:

```elixir
step :download, [retry: [max_attempts: 5]], fn ctx ->
  case Downloader.fetch(ctx["url"]) do
    {:ok, file} -> {:ok, assign(ctx, :file, file)}
    {:error, :gone} -> {:fail, "the file is gone"}     # fails now, no more retries
    {:error, :deleted} -> {:cancel, "record deleted"}  # cancelled now, like Durable.cancel/2
    {:error, reason} -> {:error, reason}               # retried
  end
end
```

`{:cancel, reason}` cancels the workflow the step is written in. A
`call_workflow` parent gets it as an error. Pass a scope to cancel less or more:

```elixir
{:cancel, reason, scope: :run}   # in a parallel step: only this branch, an error in the block's results
{:cancel, reason, scope: :root}  # the top run of the tree, through call_workflow parents, and all under it
```

### Step Queues

Give a step its own queue to cap how many runs are in that step at once:

```elixir
# queues: %{documents: [concurrency: 20], downloads: [concurrency: 80],
#           ocr: [concurrency: 10], llm: [concurrency: 20]}
workflow "import_document", queue: :documents do
  step :download,  [queue: :downloads], fn ctx -> ... end
  step :ocr,       [queue: :ocr],       fn ctx -> ... end
  step :summarize, [queue: :llm],       fn ctx -> ... end
  step :save,                           fn ctx -> ... end  # back on :documents
end
```

The run moves to the step's queue before the step and takes a slot there. The
next step without a `queue:` goes back to the queue the run started on. A
retry, snooze or wait stays on the step's queue, and compensations run on the
queue the run is on when it fails.

- `concurrency` is per node: `ocr: [concurrency: 10]` on three nodes allows 30
  OCR steps at once. For an exact total, list the queue in `:queues` only on
  the nodes that should run it.
- Every queue a step names needs a poller on some node, and so does the queue
  the run starts on, even if its first step moves it. A run on a queue no live
  node polls waits there. Past its `timeout:`, the timeout worker's one-minute
  sweep hands it back to the queue it came from, or to another that's polled,
  and it fails there.
- Each move is one more claim. With `:pubsub` configured it happens as soon as
  a slot is free; without it, within that queue's `poll_interval`.
- A finished run's `queue` is the last one it was on.

### Errors

When a step fails, its execution keeps what went wrong as `error`:

- **Raised** (`raise`, a crash in a library) — `type` (the exception
  module), `message`, and `stacktrace`: one frame per line with the app,
  file and line, e.g. `(my_app 0.1.0) lib/my_app/orders.ex:28: ...`.
- **Exited** (a `GenServer.call` timeout, a linked process going down) —
  `type: "exit"`, a readable `message` (`Exception.format_exit/1`) and the
  `stacktrace`. Throws are kept the same way.
- **Returned** — `{:error, reason}` from the step: `reason` itself, with no
  stack, because nothing was raised. A map is stored as it is, and anything
  JSON can't hold is stored in a readable form.

The same applies to compensations and to a branch's `on:` function. A
failed run's `error` is its failing step's. The stack is as deep as the
VM's `:backtrace_depth` (8 frames by default; Phoenix dev raises it to 20).

### Production Settings

Two defaults suit development more than production:

- **Pruning is off** (`prune: nil`), so finished runs and their steps stay
  forever.
- **Every log line a step writes is stored** with its step, at every level.

Something like this keeps the tables small:

```elixir
# In the supervision tree
{Durable,
 repo: MyApp.Repo,
 prune: [
   completed: :timer.hours(24 * 7),
   cancelled: :timer.hours(24 * 7),
   failed: :timer.hours(24 * 30)
 ]}

# config/prod.exs
config :durable, log_capture: [levels: [:warning, :error]]
```

Durable uses no session features, so it works on direct connections and
behind PgBouncer in transaction mode. A PgBouncer older than 1.24 needs
`prepare: :unnamed` on your repo.

See [Running in production](guides/production.md) for Postgres upkeep, deploys
and what to monitor.

### API

```elixir
Durable.start(Module, input)
Durable.start(Module, input, queue: :priority, scheduled_at: datetime)
Durable.start(Module, input, key: "article:42")   # at most one run per key
Durable.start(Module, input, tags: ["account:7"]) # labels, to find runs across workflows
Durable.start_many([{Module, input, key: "row:1"}, {Module, input2}])  # one transaction, keys checked
Durable.get_execution(id)                # {:ok, run} | {:error, :not_found}
Durable.list_executions(workflow: Module, status: :running)  # {:ok, runs}
Durable.list_executions!(tag: "account:7")                   # runs, or raises
Durable.cancel(id, "reason")
Durable.cancel_all([tag: "account:7"], "account closed")  # every open run that matches
Durable.send_event(id, "event", payload) # :ok, or {:error, :not_found} if nothing waits for it
Durable.send_event(id, "event", payload, buffer: true)  # keep it until the run waits
Durable.provide_input(id, "input_name", data)
Durable.cancel_wait(id, reason: "no longer needed")  # the wait returns {:cancelled, reason}
Durable.list_children(parent_id)         # {:ok, runs} | {:error, :not_found}

# Operating
Durable.retry(id)                        # failed run: resume from the failed step
Durable.rerun(id, input: new_input)      # finished run: start a fresh copy
Durable.release_key(id, by: user)        # finished run: let its key start again
Durable.pause_queue(:default, by: user)  # on every node, until resume_queue/2
Durable.drain()                          # this node: stop claiming, finish running steps
Durable.list_nodes()                     # {:ok, nodes}: heartbeating instances and what they run
Durable.prune()                          # apply the :prune retention now

# Observing
Durable.Stats.overview(since: dt)        # {:ok, stats}; also timeline/1, workflows/1,
                                         # step_performance/1, queues/1, queue_history/1,
                                         # error_groups/1
Durable.Activity.list()                  # {:ok, events}: recovered runs, fenced workers, queue pauses…
```

Every function that reads returns `{:ok, result}` or `{:error, reason}`, and has
a twin ending in `!` that returns the result or raises `ArgumentError`. A wrong
option is `{:error, {:invalid_option, key}}` (a negative `:limit`, a status no
run has, an option the function doesn't know: nothing is clamped or ignored),
and an id that names nothing is `{:error, :not_found}`. `Durable.Query.Opts`
has the whole contract.

```elixir
{:ok, runs} = Durable.list_executions(status: :failed, limit: 20)
runs = Durable.list_executions!(status: :failed, limit: 20)
{:error, {:invalid_option, :limit}} = Durable.list_executions(limit: -1)
```

A run's `context` is your data and nothing else. What the engine keeps for a
run is in its own column, and the names it keeps for itself (`__fail__`,
`__rollback__`, `__child:…` and the like) are dropped from a start's input, a
step's result, `put_context`, an event's payload and an input's answer.

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
in-place — no `forward`, no extra endpoint. It works inside a `scope` and at
`/`, and `:as` lets one router mount a dashboard per Durable instance.
Dashboard 2.0 needs Durable 2.0. You get:

- Overview: health over a time range, what's failing and why, queue pressure
- Runs: every run, with a query bar, saved views and bulk retry, rerun and
  cancel. Filters live in the URL, so a search can be shared
- One run: a trace of every attempt, the workflow graph, logs, context, its
  parent and child runs, and its workflow key
- Workflows: runs, failure rate and duration per workflow, with its structure
- Inbox: answer inputs, send events, see what's sleeping
- Keys, Queues & nodes, Schedules, Telemetry and Settings
- ⌘K command palette — jump to any page, workflow, schedule, run or key

See the [dashboard setup](https://durable.wavezync.com/docs/dashboard/) for the
options and [Using the dashboard](https://durable.wavezync.com/docs/using-the-dashboard/)
for what each page is for.

## Guides

- [Branching](guides/branching.md) - Conditional flow control
- [Parallel](guides/parallel.md) - Concurrent execution
- [Compensations](guides/compensations.md) - Saga pattern
- [Waiting](guides/waiting.md) - Sleep, events, human input
- [Orchestration](guides/orchestration.md) - Parent/child workflow composition
- [Workflow keys](guides/workflow_keys.md) - One run per key, duplicate starts, reuse policies
- [Testing](guides/testing.md) - Run and assert on workflows in ExUnit
- [Coming from Oban](guides/coming_from_oban.md) - What maps to what, and what works differently
- [Running in production](guides/production.md) - Settings, Postgres upkeep, deploys and what to monitor
- [Using the dashboard](https://durable.wavezync.com/docs/using-the-dashboard/) - The web console: runs, queues, inbox and more

## License

MIT
