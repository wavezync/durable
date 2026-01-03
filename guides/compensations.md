# Compensations (Saga Pattern)

Handle distributed transactions that need rollback when something fails.

## What Are Compensations?

When a workflow performs actions with external side effects (booking flights, charging payments, sending emails), you often need to **undo** those actions if a later step fails. The saga pattern solves this by defining compensation handlers that run in reverse order when failures occur.

## Quick Example

```elixir
defmodule MyApp.BookTripWorkflow do
  use Durable
  use Durable.Context

  workflow "book_trip" do
    # Step 1: Book flight (with compensation)
    step :book_flight, compensate: :cancel_flight do
      booking = FlightAPI.book(input()["flight"])
      put_context(:flight_id, booking.id)
    end

    # Step 2: Book hotel (with compensation)
    step :book_hotel, compensate: :cancel_hotel do
      booking = HotelAPI.book(input()["hotel"])
      put_context(:hotel_id, booking.id)
    end

    # Step 3: Charge payment (no compensation needed - it's the last step)
    step :charge_payment do
      # If this fails, compensations run automatically!
      PaymentService.charge(get_context(:total))
    end

    # Compensation handlers
    compensate :cancel_flight do
      FlightAPI.cancel(get_context(:flight_id))
    end

    compensate :cancel_hotel do
      HotelAPI.cancel(get_context(:hotel_id))
    end
  end
end
```

**What happens when payment fails:**

1. `:book_flight` completes successfully
2. `:book_hotel` completes successfully
3. `:charge_payment` raises an error
4. Durable automatically runs compensations in **reverse order**:
   - First: `:cancel_hotel` (undo hotel)
   - Then: `:cancel_flight` (undo flight)
5. Workflow status becomes `:compensated`

## DSL Reference

### Defining Compensations

```elixir
compensate :handler_name do
  # Undo logic here
  # Has access to workflow context
end
```

### Linking Steps to Compensations

```elixir
step :my_step, compensate: :my_handler do
  # Step logic
end
```

### Compensation Options

```elixir
compensate :handler_name, retry: [max_attempts: 3, backoff: :exponential] do
  # Compensation with retry
end
```

## Workflow Status States

| Status | Description |
|--------|-------------|
| `:compensating` | Currently running compensation handlers |
| `:compensated` | All compensations completed successfully |
| `:compensation_failed` | One or more compensations failed |

## How It Works

1. **Tracking**: Durable tracks which steps with compensations have completed
2. **Failure**: When any step fails, compensation is triggered
3. **Reverse Order**: Compensations run in LIFO order (last completed first)
4. **Recording**: Each compensation is recorded as a step execution
5. **Continuation**: Compensation failures don't stop the chain - all compensations attempt to run

## Best Practices

### Make Compensations Idempotent

Compensations may run multiple times (retries, manual recovery). Design them to be safe to repeat:

```elixir
compensate :cancel_booking do
  booking_id = get_context(:booking_id)

  # Check if already cancelled before cancelling
  case BookingAPI.get(booking_id) do
    {:ok, %{status: :cancelled}} -> :already_cancelled
    {:ok, booking} -> BookingAPI.cancel(booking_id)
    {:error, :not_found} -> :already_gone
  end
end
```

### Store IDs for Cleanup

Always store resource IDs in context so compensations can find them:

```elixir
step :create_resource, compensate: :delete_resource do
  resource = ExternalAPI.create(params)
  put_context(:resource_id, resource.id)  # Store for compensation
end

compensate :delete_resource do
  ExternalAPI.delete(get_context(:resource_id))
end
```

### Handle Partial Failures

Not all compensations may succeed. Check `compensation_results` for details:

```elixir
{:ok, execution} = Durable.get_execution(workflow_id)

case execution.status do
  :compensated ->
    IO.puts("All compensations succeeded")

  :compensation_failed ->
    IO.puts("Some compensations failed:")
    Enum.each(execution.compensation_results, fn result ->
      IO.inspect(result)
    end)
end
```

## Querying Compensation Results

### Execution Results

```elixir
{:ok, execution} = Durable.get_execution(workflow_id)

# Check compensation status
execution.status              # :compensated or :compensation_failed
execution.compensated_at      # When compensation completed
execution.compensation_results  # Array of results

# Result structure:
# [
#   %{
#     "step" => "book_hotel",
#     "compensation" => "cancel_hotel",
#     "result" => %{"status" => "completed"}
#   },
#   %{
#     "step" => "book_flight",
#     "compensation" => "cancel_flight",
#     "result" => %{"status" => "completed"}
#   }
# ]
```

### Step Executions

```elixir
{:ok, execution} = Durable.get_execution(workflow_id, include_steps: true)

# Find compensation step executions
compensation_steps = Enum.filter(execution.steps, & &1.is_compensation)

Enum.each(compensation_steps, fn step ->
  IO.puts("#{step.step_name}: #{step.status}")
  IO.puts("  Compensating for: #{step.compensation_for}")
  IO.puts("  Duration: #{step.duration_ms}ms")
end)
```

## Complete Example: E-Commerce Order

```elixir
defmodule MyApp.ProcessOrderWorkflow do
  use Durable
  use Durable.Context

  workflow "process_order" do
    step :reserve_inventory, compensate: :release_inventory do
      items = input()["items"]

      reservations = Enum.map(items, fn item ->
        {:ok, res} = Inventory.reserve(item.sku, item.quantity)
        res.id
      end)

      put_context(:reservation_ids, reservations)
    end

    step :charge_customer, compensate: :refund_customer do
      amount = input()["total"]
      {:ok, charge} = Payments.charge(input()["customer_id"], amount)
      put_context(:charge_id, charge.id)
    end

    step :create_shipment do
      # If shipping fails, inventory is released and payment refunded
      {:ok, shipment} = Shipping.create(input()["address"], input()["items"])
      put_context(:shipment_id, shipment.id)
    end

    step :send_confirmation do
      Email.send_order_confirmation(input()["customer_email"], %{
        shipment_id: get_context(:shipment_id),
        charge_id: get_context(:charge_id)
      })
    end

    # Compensations
    compensate :release_inventory do
      Enum.each(get_context(:reservation_ids), fn id ->
        Inventory.release(id)
      end)
    end

    compensate :refund_customer do
      Payments.refund(get_context(:charge_id))
    end
  end
end
```
