# Compensations (Saga Pattern)

Handle distributed transactions that need rollback when something fails.

## What Are Compensations?

When a workflow performs actions with external side effects (booking flights, charging payments, sending emails), you often need to **undo** those actions if a later step fails. The saga pattern solves this by defining compensation handlers that run in reverse order when failures occur.

## Quick Example

```elixir
defmodule MyApp.BookTripWorkflow do
  use Durable
  use Durable.Helpers

  workflow "book_trip" do
    # Step 1: Book flight (with compensation)
    step :book_flight, [compensate: :cancel_flight], fn data ->
      booking = FlightAPI.book(data["flight"])
      {:ok, assign(data, :flight_id, booking.id)}
    end

    # Step 2: Book hotel (with compensation)
    step :book_hotel, [compensate: :cancel_hotel], fn data ->
      booking = HotelAPI.book(data["hotel"])
      {:ok, assign(data, :hotel_id, booking.id)}
    end

    # Step 3: Charge payment (no compensation needed - it's the last step)
    step :charge_payment, fn data ->
      # If this fails, compensations run automatically!
      PaymentService.charge(data.total)
      {:ok, data}
    end

    # Compensation handlers
    compensate :cancel_flight, fn data ->
      FlightAPI.cancel(data.flight_id)
      {:ok, data}
    end

    compensate :cancel_hotel, fn data ->
      HotelAPI.cancel(data.hotel_id)
      {:ok, data}
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
compensate :handler_name, fn data ->
  # Undo logic here
  # Has access to workflow data
  {:ok, data}
end
```

### Linking Steps to Compensations

```elixir
step :my_step, [compensate: :my_handler], fn data ->
  # Step logic
  {:ok, data}
end
```

### Compensation Options

```elixir
compensate :handler_name, [retry: [max_attempts: 3, backoff: :exponential]], fn data ->
  # Compensation with retry
  {:ok, data}
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
compensate :cancel_booking, fn data ->
  booking_id = data.booking_id

  # Check if already cancelled before cancelling
  case BookingAPI.get(booking_id) do
    {:ok, %{status: :cancelled}} -> {:ok, data}
    {:ok, _booking} -> BookingAPI.cancel(booking_id); {:ok, data}
    {:error, :not_found} -> {:ok, data}
  end
end
```

### Store IDs for Cleanup

Always store resource IDs in data so compensations can find them:

```elixir
step :create_resource, [compensate: :delete_resource], fn data ->
  resource = ExternalAPI.create(data.params)
  {:ok, assign(data, :resource_id, resource.id)}  # Store for compensation
end

compensate :delete_resource, fn data ->
  ExternalAPI.delete(data.resource_id)
  {:ok, data}
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
  use Durable.Helpers

  workflow "process_order" do
    step :reserve_inventory, [compensate: :release_inventory], fn data ->
      items = data["items"]

      reservations = Enum.map(items, fn item ->
        {:ok, res} = Inventory.reserve(item.sku, item.quantity)
        res.id
      end)

      {:ok, assign(data, :reservation_ids, reservations)}
    end

    step :charge_customer, [compensate: :refund_customer], fn data ->
      amount = data["total"]
      {:ok, charge} = Payments.charge(data["customer_id"], amount)
      {:ok, assign(data, :charge_id, charge.id)}
    end

    step :create_shipment, fn data ->
      # If shipping fails, inventory is released and payment refunded
      {:ok, shipment} = Shipping.create(data["address"], data["items"])
      {:ok, assign(data, :shipment_id, shipment.id)}
    end

    step :send_confirmation, fn data ->
      Email.send_order_confirmation(data["customer_email"], %{
        shipment_id: data.shipment_id,
        charge_id: data.charge_id
      })
      {:ok, data}
    end

    # Compensations
    compensate :release_inventory, fn data ->
      Enum.each(data.reservation_ids, fn id ->
        Inventory.release(id)
      end)
      {:ok, data}
    end

    compensate :refund_customer, fn data ->
      Payments.refund(data.charge_id)
      {:ok, data}
    end
  end
end
```
