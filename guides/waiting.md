# Wait Primitives

Suspend workflows to wait for time, events, or human input.

## Setup

```elixir
defmodule MyApp.MyWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait  # Import wait functions
end
```

## Sleep Functions

### `sleep_for/1` - Duration-Based Sleep

Suspend the workflow for a specific duration.

```elixir
workflow "delayed_task" do
  step :start do
    Logger.info("Starting task")
  end

  step :wait do
    sleep_for(minutes: 30)
  end

  step :continue do
    Logger.info("Resumed after 30 minutes")
  end
end
```

**Duration options:**

| Option | Example |
|--------|---------|
| `:seconds` | `sleep_for(seconds: 30)` |
| `:minutes` | `sleep_for(minutes: 5)` |
| `:hours` | `sleep_for(hours: 2)` |
| `:days` | `sleep_for(days: 1)` |

### `sleep_until/1` - Time-Based Sleep

Suspend until a specific datetime.

```elixir
step :schedule do
  # Wake up at midnight UTC
  sleep_until(~U[2025-12-25 00:00:00Z])
end

# Or calculate dynamically
step :wait_until_business_hours do
  next_9am = calculate_next_9am()
  sleep_until(next_9am)
end
```

## Event Waiting

### `wait_for_event/2` - External Events

Suspend until an external system sends an event.

```elixir
workflow "payment_flow" do
  step :initiate_payment do
    payment = Payments.create(input()["amount"])
    put_context(:payment_id, payment.id)
  end

  step :await_confirmation do
    result = wait_for_event("payment_confirmed",
      timeout: minutes(15),
      timeout_value: :timeout
    )

    put_context(:payment_result, result)
  end

  step :process_result do
    case get_context(:payment_result) do
      :timeout -> handle_timeout()
      %{status: "success"} -> handle_success()
      _ -> handle_failure()
    end
  end
end
```

**Options:**

| Option | Description |
|--------|-------------|
| `:timeout` | Max wait time (e.g., `minutes(15)`) |
| `:timeout_value` | Value returned on timeout |

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

### `wait_for_input/2` - Human Input

Suspend until a human provides input.

```elixir
workflow "approval_flow" do
  step :prepare_request do
    put_context(:request, input())
  end

  step :await_approval do
    result = wait_for_input("manager_approval",
      timeout: days(3),
      timeout_value: :auto_rejected
    )

    put_context(:approval, result)
  end

  step :process_decision do
    case get_context(:approval) do
      :auto_rejected ->
        put_context(:status, :rejected_timeout)
      %{approved: true} ->
        put_context(:status, :approved)
      _ ->
        put_context(:status, :rejected)
    end
  end
end
```

**Options:**

| Option | Description |
|--------|-------------|
| `:type` | Input type (see below) |
| `:prompt` | Message to show user |
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
| `:multi_choice` | Pick multiple options |
| `:free_text` | Open text input |

### Form Input Example

```elixir
step :collect_details do
  result = wait_for_input("equipment_request",
    type: :form,
    prompt: "Please specify equipment needs",
    fields: [
      %{name: :laptop, type: :select, options: ["MacBook Pro", "ThinkPad X1"]},
      %{name: :monitor, type: :select, options: ["24 inch", "27 inch", "None"]},
      %{name: :notes, type: :text, required: false}
    ]
  )

  put_context(:equipment, result)
end
```

### Choice Input Example

```elixir
step :select_priority do
  priority = wait_for_input("priority_selection",
    type: :single_choice,
    prompt: "Select issue priority",
    choices: [
      %{value: :critical, label: "Critical - System down"},
      %{value: :high, label: "High - Major impact"},
      %{value: :medium, label: "Medium - Some impact"},
      %{value: :low, label: "Low - Minor issue"}
    ]
  )

  put_context(:priority, priority)
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
  step :submit do
    put_context(:expense, input())
    put_context(:amount, input()["amount"])
  end

  step :manager_review do
    if get_context(:amount) > 1000 do
      result = wait_for_input("manager_approval",
        type: :approval,
        prompt: "Approve expense of $#{get_context(:amount)}?",
        timeout: days(2)
      )
      put_context(:manager_approved, result[:approved] || false)
    else
      put_context(:manager_approved, true)
    end
  end

  step :finance_review do
    if get_context(:amount) > 5000 and get_context(:manager_approved) do
      result = wait_for_input("finance_approval",
        type: :approval,
        timeout: days(3)
      )
      put_context(:finance_approved, result[:approved] || false)
    else
      put_context(:finance_approved, true)
    end
  end

  step :finalize do
    if get_context(:manager_approved) and get_context(:finance_approved) do
      Expenses.approve(get_context(:expense))
    else
      Expenses.reject(get_context(:expense))
    end
  end
end
```

### Webhook Integration

```elixir
workflow "order_fulfillment" do
  step :create_shipment do
    shipment = Shipping.create(input()["order_id"])
    put_context(:shipment_id, shipment.id)
    put_context(:tracking_number, shipment.tracking)
  end

  step :await_delivery do
    # Wait for webhook from shipping provider
    event = wait_for_event("shipment_delivered",
      timeout: days(14),
      timeout_value: :lost_package
    )

    put_context(:delivery_status, event)
  end

  step :handle_delivery do
    case get_context(:delivery_status) do
      :lost_package ->
        Support.create_ticket("Lost package", get_context(:shipment_id))
      %{status: "delivered"} ->
        Orders.mark_complete(input()["order_id"])
      _ ->
        Logger.warn("Unexpected delivery status")
    end
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
  step :check_expiry do
    subscription = Subscriptions.get(input()["subscription_id"])
    put_context(:subscription, subscription)
    put_context(:expires_at, subscription.expires_at)
  end

  step :wait_for_reminder_time do
    expires_at = get_context(:expires_at)
    reminder_time = DateTime.add(expires_at, -7, :day)  # 7 days before

    sleep_until(reminder_time)
  end

  step :send_reminder do
    subscription = get_context(:subscription)
    Mailer.send_renewal_reminder(subscription.user_email)
  end

  step :await_renewal do
    renewal = wait_for_event("subscription_renewed",
      timeout: days(7),
      timeout_value: :not_renewed
    )

    put_context(:renewal_result, renewal)
  end

  step :handle_result do
    case get_context(:renewal_result) do
      :not_renewed ->
        Subscriptions.expire(get_context(:subscription).id)
      _ ->
        Logger.info("Subscription renewed")
    end
  end
end
```

## Best Practices

### Always Handle Timeouts

```elixir
step :await_response do
  result = wait_for_input("approval",
    timeout: days(7),
    timeout_value: :timed_out  # Always provide a timeout value
  )

  case result do
    :timed_out -> handle_timeout()
    response -> handle_response(response)
  end
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

### Store Context Before Waiting

```elixir
step :prepare_and_wait do
  # Save important data before suspending
  put_context(:prepared_at, DateTime.utc_now())
  put_context(:request_details, input())

  # Now wait
  wait_for_input("approval")
end
```
