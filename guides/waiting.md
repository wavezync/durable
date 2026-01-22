# Wait Primitives

Suspend workflows to wait for time, events, or human input.

## Setup

```elixir
defmodule MyApp.MyWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait  # Import wait functions
end
```

## Duration Helpers

Use these helpers to specify durations:

```elixir
seconds(30)   # 30 seconds in ms
minutes(5)    # 5 minutes in ms
hours(2)      # 2 hours in ms
days(1)       # 1 day in ms
```

## Sleep Functions

### `sleep/1` - Duration-Based Sleep

Suspend the workflow for a specific duration.

```elixir
workflow "delayed_task" do
  step :start, fn ctx ->
    Logger.info("Starting task")
    {:ok, ctx}
  end

  step :wait, fn ctx ->
    sleep(minutes(30))
    {:ok, ctx}
  end

  step :continue, fn ctx ->
    Logger.info("Resumed after 30 minutes")
    {:ok, ctx}
  end
end
```

**Duration examples:**

| Duration | Code |
|----------|------|
| 30 seconds | `sleep(seconds(30))` |
| 5 minutes | `sleep(minutes(5))` |
| 2 hours | `sleep(hours(2))` |
| 1 day | `sleep(days(1))` |

### `schedule_at/1` - Time-Based Sleep

Suspend until a specific datetime.

```elixir
step :schedule, fn ctx ->
  # Wake up at midnight UTC
  schedule_at(~U[2025-12-25 00:00:00Z])
  {:ok, ctx}
end

# Or use time helpers
step :wait_until_business_hours, fn ctx ->
  schedule_at(next_business_day(hour: 9))
  {:ok, ctx}
end

step :wait_for_monday, fn ctx ->
  schedule_at(next_weekday(:monday, hour: 9))
  {:ok, ctx}
end
```

### Time Helpers

Use these with `schedule_at/1`:

| Helper | Description | Example |
|--------|-------------|---------|
| `next_business_day/0,1` | Next Mon-Fri | `next_business_day(hour: 9)` |
| `next_weekday/1,2` | Next specific day | `next_weekday(:friday, hour: 17)` |
| `end_of_day/0,1` | End of current day | `end_of_day()` |

```elixir
# Wake up at 9am on the next business day
schedule_at(next_business_day(hour: 9))

# Wake up at 5pm next Friday
schedule_at(next_weekday(:friday, hour: 17))

# Wake up at end of today
schedule_at(end_of_day())
```

## Event Waiting

### `wait_for_event/2` - Single Event

Suspend until an external system sends an event.

```elixir
workflow "payment_flow" do
  step :initiate_payment, fn ctx ->
    payment = Payments.create(ctx["amount"])
    {:ok, assign(ctx, :payment_id, payment.id)}
  end

  step :await_confirmation, fn ctx ->
    result = wait_for_event("payment_confirmed",
      timeout: minutes(15),
      timeout_value: :timeout
    )
    {:ok, assign(ctx, :payment_result, result)}
  end

  step :process_result, fn ctx ->
    case ctx.payment_result do
      :timeout -> handle_timeout()
      %{status: "success"} -> handle_success()
      _ -> handle_failure()
    end
    {:ok, ctx}
  end
end
```

**Options:**

| Option | Description |
|--------|-------------|
| `:timeout` | Max wait time (e.g., `minutes(15)`) |
| `:timeout_value` | Value returned on timeout |

### `wait_for_any/2` - First Event Wins

Wait for any one of multiple events. Returns `{event_name, payload}`.

```elixir
workflow "order_status" do
  step :await_result, fn ctx ->
    {event, payload} = wait_for_any(["success", "failure", "cancelled"],
      timeout: hours(24),
      timeout_value: {:timeout, nil}
    )
    {:ok, ctx
    |> assign(:result_event, event)
    |> assign(:result_data, payload)}
  end

  step :handle_result, fn ctx ->
    case ctx.result_event do
      "success" -> process_success(ctx.result_data)
      "failure" -> process_failure(ctx.result_data)
      "cancelled" -> process_cancellation()
    end
    {:ok, ctx}
  end
end
```

### `wait_for_all/2` - All Events Required

Wait for all specified events. Returns `%{event_name => payload}`.

```elixir
workflow "multi_approval" do
  step :await_approvals, fn ctx ->
    results = wait_for_all(["manager_approval", "legal_approval", "finance_approval"],
      timeout: days(7),
      timeout_value: {:timeout, :partial}
    )
    {:ok, assign(ctx, :approvals, results)}
  end

  step :process_approvals, fn ctx ->
    case ctx.approvals do
      {:timeout, :partial} ->
        handle_incomplete_approvals()
      %{} = all_approvals ->
        if Enum.all?(all_approvals, fn {_k, v} -> v.approved end) do
          proceed_with_request()
        else
          reject_request()
        end
    end
    {:ok, ctx}
  end
end
```

### Sending Events

From your application code (webhook handler, API endpoint, etc.):

```elixir
# Send event to resume workflow
Durable.Wait.send_event(
  workflow_id,
  "payment_confirmed",
  %{status: "success", transaction_id: "txn_123"}
)
```

## Human-in-the-Loop

### `wait_for_input/2` - Generic Human Input

Suspend until a human provides input.

```elixir
workflow "approval_flow" do
  step :prepare_request, fn ctx ->
    {:ok, %{request: ctx}}
  end

  step :await_approval, fn ctx ->
    result = wait_for_input("manager_approval",
      type: :approval,
      prompt: "Approve this request?",
      timeout: days(3),
      timeout_value: :auto_rejected
    )
    {:ok, assign(ctx, :approval, result)}
  end

  step :process_decision, fn ctx ->
    status = case ctx.approval do
      :auto_rejected -> :rejected_timeout
      %{approved: true} -> :approved
      _ -> :rejected
    end
    {:ok, assign(ctx, :status, status)}
  end
end
```

**Options:**

| Option | Description |
|--------|-------------|
| `:type` | Input type (see below) |
| `:prompt` | Message to show user |
| `:metadata` | Additional data for UI |
| `:timeout` | Max wait time |
| `:timeout_value` | Value on timeout |
| `:fields` | Field definitions for forms |
| `:choices` | Options for choice inputs |

**Input types:**

| Type | Use Case |
|------|----------|
| `:approval` | Simple yes/no decision |
| `:form` | Structured data entry |
| `:single_choice` | Pick one option |
| `:free_text` | Open text input |

### Convenience Wrappers

#### `wait_for_approval/2`

Wait for an approval decision. Returns `:approved` or `:rejected`.

```elixir
step :manager_review, fn ctx ->
  result = wait_for_approval("expense_approval",
    prompt: "Approve expense for $500?",
    metadata: %{employee: "John", amount: 500},
    timeout: days(3),
    timeout_value: :auto_approved
  )
  {:ok, assign(ctx, :approved, result == :approved)}
end
```

#### `wait_for_choice/2`

Wait for a single choice selection.

```elixir
step :select_shipping, fn ctx ->
  method = wait_for_choice("shipping_method",
    prompt: "Select shipping method:",
    choices: [
      %{value: :express, label: "Express ($15)"},
      %{value: :standard, label: "Standard (Free)"}
    ],
    timeout: hours(24),
    timeout_value: :standard
  )
  {:ok, assign(ctx, :shipping, method)}
end
```

#### `wait_for_text/2`

Wait for text input.

```elixir
step :get_reason, fn ctx ->
  reason = wait_for_text("rejection_reason",
    prompt: "Please provide a reason for rejection:",
    timeout: hours(4),
    timeout_value: "No reason provided"
  )
  {:ok, assign(ctx, :reason, reason)}
end
```

#### `wait_for_form/2`

Wait for form submission.

```elixir
step :collect_details, fn ctx ->
  result = wait_for_form("equipment_request",
    prompt: "Please specify equipment needs",
    fields: [
      %{name: :laptop, type: :select, options: ["MacBook Pro", "ThinkPad X1"], required: true},
      %{name: :monitor, type: :select, options: ["24 inch", "27 inch", "None"], required: false},
      %{name: :notes, type: :text, required: false}
    ],
    timeout: days(7)
  )
  {:ok, assign(ctx, :equipment, result)}
end
```

### Providing Input

From your application (admin UI, API, etc.):

```elixir
# Provide human input to resume workflow
Durable.Wait.provide_input(
  workflow_id,
  "manager_approval",
  %{approved: true, comment: "Looks good"}
)
```

### Listing Pending Inputs

Find workflows waiting for human input:

```elixir
# Get all pending inputs
pending = Durable.Wait.list_pending_inputs()

# Filter by status
pending = Durable.Wait.list_pending_inputs(status: :pending)

# Filter by timeout
soon = Durable.Wait.list_pending_inputs(
  timeout_before: DateTime.add(DateTime.utc_now(), 3600)
)
```

## Examples

### Multi-Stage Approval

```elixir
workflow "expense_approval" do
  step :submit, fn ctx ->
    {:ok, %{expense: ctx, amount: ctx["amount"]}}
  end

  step :manager_review, fn ctx ->
    if ctx.amount > 1000 do
      result = wait_for_approval("manager_approval",
        prompt: "Approve expense of $#{ctx.amount}?",
        timeout: days(2)
      )
      {:ok, assign(ctx, :manager_approved, result == :approved)}
    else
      {:ok, assign(ctx, :manager_approved, true)}
    end
  end

  step :finance_review, fn ctx ->
    if ctx.amount > 5000 and ctx.manager_approved do
      result = wait_for_approval("finance_approval",
        timeout: days(3)
      )
      {:ok, assign(ctx, :finance_approved, result == :approved)}
    else
      {:ok, assign(ctx, :finance_approved, true)}
    end
  end

  step :finalize, fn ctx ->
    if ctx.manager_approved and ctx.finance_approved do
      Expenses.approve(ctx.expense)
    else
      Expenses.reject(ctx.expense)
    end
    {:ok, ctx}
  end
end
```

### Webhook Integration

```elixir
workflow "order_fulfillment" do
  step :create_shipment, fn ctx ->
    shipment = Shipping.create(ctx["order_id"])
    {:ok, %{
      shipment_id: shipment.id,
      tracking_number: shipment.tracking,
      order_id: ctx["order_id"]
    }}
  end

  step :await_delivery, fn ctx ->
    # Wait for webhook from shipping provider
    event = wait_for_event("shipment_delivered",
      timeout: days(14),
      timeout_value: :lost_package
    )
    {:ok, assign(ctx, :delivery_status, event)}
  end

  step :handle_delivery, fn ctx ->
    case ctx.delivery_status do
      :lost_package ->
        Support.create_ticket("Lost package", ctx.shipment_id)
      %{status: "delivered"} ->
        Orders.mark_complete(ctx.order_id)
      _ ->
        Logger.warning("Unexpected delivery status")
    end
    {:ok, ctx}
  end
end

# In your webhook controller:
def handle_shipping_webhook(conn, %{"tracking" => tracking, "status" => "delivered"} = params) do
  workflow_id = lookup_workflow_by_tracking(tracking)

  Durable.Wait.send_event(workflow_id, "shipment_delivered", %{
    status: "delivered",
    delivered_at: params["timestamp"]
  })

  json(conn, %{ok: true})
end
```

### Scheduled Reminders

```elixir
workflow "subscription_renewal" do
  step :check_expiry, fn ctx ->
    subscription = Subscriptions.get(ctx["subscription_id"])
    {:ok, %{subscription: subscription, expires_at: subscription.expires_at}}
  end

  step :wait_for_reminder_time, fn ctx ->
    reminder_time = DateTime.add(ctx.expires_at, -7, :day)  # 7 days before
    schedule_at(reminder_time)
    {:ok, ctx}
  end

  step :send_reminder, fn ctx ->
    Mailer.send_renewal_reminder(ctx.subscription.user_email)
    {:ok, ctx}
  end

  step :await_renewal, fn ctx ->
    renewal = wait_for_event("subscription_renewed",
      timeout: days(7),
      timeout_value: :not_renewed
    )
    {:ok, assign(ctx, :renewal_result, renewal)}
  end

  step :handle_result, fn ctx ->
    case ctx.renewal_result do
      :not_renewed ->
        Subscriptions.expire(ctx.subscription.id)
      _ ->
        Logger.info("Subscription renewed")
    end
    {:ok, ctx}
  end
end
```

### Parallel Approvals

```elixir
workflow "contract_approval" do
  step :submit_contract, fn ctx ->
    {:ok, %{contract: ctx}}
  end

  step :await_all_approvals, fn ctx ->
    # Wait for all three departments to approve
    results = wait_for_all(["legal", "finance", "management"],
      timeout: days(5),
      timeout_value: {:timeout, :incomplete}
    )
    {:ok, assign(ctx, :approval_results, results)}
  end

  step :finalize, fn ctx ->
    status = case ctx.approval_results do
      {:timeout, :incomplete} -> :timed_out
      approvals ->
        all_approved = Enum.all?(approvals, fn {_, v} -> v["approved"] end)
        if all_approved, do: :approved, else: :rejected
    end
    {:ok, assign(ctx, :status, status)}
  end
end
```

### Race Condition Handling

```elixir
workflow "payment_with_timeout" do
  step :await_payment_or_cancel, fn ctx ->
    # First event wins
    {event, event_data} = wait_for_any(["payment_received", "user_cancelled", "fraud_detected"],
      timeout: hours(1),
      timeout_value: {:timeout, nil}
    )
    {:ok, ctx
    |> assign(:result_event, event)
    |> assign(:result_data, event_data)}
  end

  step :handle_result, fn ctx ->
    case ctx.result_event do
      "payment_received" -> complete_order()
      "user_cancelled" -> refund_if_needed()
      "fraud_detected" -> flag_for_review()
      :timeout -> expire_order()
    end
    {:ok, ctx}
  end
end
```

## Best Practices

### Always Handle Timeouts

```elixir
step :await_response, fn ctx ->
  result = wait_for_input("approval",
    timeout: days(7),
    timeout_value: :timed_out  # Always provide a timeout value
  )

  case result do
    :timed_out -> handle_timeout()
    response -> handle_response(response)
  end
  {:ok, assign(ctx, :response, result)}
end
```

### Use Meaningful Event Names

```elixir
# Good - descriptive and namespaced
wait_for_event("payment.confirmed")
wait_for_event("shipment.delivered")
wait_for_event("user.verified_email")

# Avoid - too generic
wait_for_event("done")
wait_for_event("event")
```

### Store Data Before Waiting

```elixir
step :prepare_and_wait, fn ctx ->
  # Save important data before suspending
  ctx = ctx
  |> assign(:prepared_at, DateTime.utc_now())
  |> assign(:request_details, ctx)

  # Now wait
  wait_for_input("approval")
  {:ok, ctx}
end
```

### Use Convenience Wrappers

```elixir
# Good - clear intent
wait_for_approval("manager_approval", prompt: "Approve?")
wait_for_choice("priority", choices: [...])
wait_for_text("comments")
wait_for_form("details", fields: [...])

# Also works but less clear
wait_for_input("approval", type: :approval)
```
