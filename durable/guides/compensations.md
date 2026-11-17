# Compensations (Saga Pattern)

Undo what a run already did when it can't go on.

## What Are Compensations?

When a workflow performs actions with external side effects (booking flights, charging payments, sending emails), you often need to **undo** those actions if a later step fails. The saga pattern solves this by defining compensation handlers that run in reverse order when failures occur.

## Quick Example

```elixir
defmodule MyApp.BookTripWorkflow do
  use Durable
  use Durable.Helpers

  workflow "book_trip" do
    # Step 1: Book flight (with compensation)
    step :book_flight, [compensate: :cancel_flight], fn ctx ->
      booking = FlightAPI.book(ctx["flight"])
      {:ok, assign(ctx, :flight_id, booking.id)}
    end

    # Step 2: Book hotel (with compensation)
    step :book_hotel, [compensate: :cancel_hotel], fn ctx ->
      booking = HotelAPI.book(ctx["hotel"])
      {:ok, assign(ctx, :hotel_id, booking.id)}
    end

    # Step 3: Charge payment (no compensation needed - it's the last step)
    step :charge_payment, [retry: [max_attempts: 3]], fn ctx ->
      case PaymentService.charge(ctx.total) do
        {:ok, receipt} -> {:ok, assign(ctx, :receipt, receipt)}
        # The customer isn't paying: release the seat and the room now.
        {:error, :declined} -> {:rollback, "card declined"}
        # Payments are down: retried, and if still down the run is left failed.
        {:error, :timeout} -> {:error, "payments timed out"}
      end
    end

    # Compensation handlers
    compensate :cancel_flight, fn ctx ->
      FlightAPI.cancel(ctx.flight_id)
      {:ok, ctx}
    end

    compensate :cancel_hotel, fn ctx ->
      HotelAPI.cancel(ctx.hotel_id)
      {:ok, ctx}
    end
  end
end
```

**What happens when the card is declined:**

1. `:book_flight` completes successfully
2. `:book_hotel` completes successfully
3. `:charge_payment` returns `{:rollback, "card declined"}`
4. Durable runs compensations in **reverse order**:
   - First: `:cancel_hotel` (undo hotel)
   - Then: `:cancel_flight` (undo flight)
5. Workflow status becomes `:compensated`

**What happens when payments are down:** `:charge_payment` uses its retries and the run ends `:failed`. Nothing is undone: the flight and hotel are still booked. When payments are back, `Durable.retry(id)` carries on from `:charge_payment`. If the customer gives up instead, `Durable.rollback(id)` undoes the bookings.

## When Compensations Run

A run that fails is left as it failed. Compensations run only when something asks:

| Asked by | How |
|----------|-----|
| A step | It returns `{:rollback, reason}`. The run fails now, with no more retries, and is undone |
| You | `Durable.rollback(id)` on a failed run. A worker runs the compensations |
| The workflow | `workflow "book_trip", on_failure: :rollback do` undoes the run on any failure: a step out of retries, `{:fail, reason}`, a timeout |

Use `on_failure: :rollback` when no failure is worth retrying by hand. Otherwise leave the default, `:halt`, and say which failures undo.

A run that was rolled back can't be retried, because the work its later steps depend on is gone. `Durable.retry/2` returns `{:error, :rolled_back}`; `Durable.rerun/2` starts a fresh run.

Until 1.6 every failure rolled back. To keep that, add `on_failure: :rollback` to each workflow that has `compensate:`.

## DSL Reference

### Defining Compensations

```elixir
compensate :handler_name, fn ctx ->
  # Undo logic here
  # Has access to workflow context
  {:ok, ctx}
end
```

### Linking Steps to Compensations

```elixir
step :my_step, [compensate: :my_handler], fn ctx ->
  # Step logic
  {:ok, ctx}
end
```

### Compensation Options

```elixir
compensate :handler_name, [retry: [max_attempts: 3, backoff: :exponential]], fn ctx ->
  # Compensation with retry
  {:ok, ctx}
end
```

### What a Compensation Returns

| Return | Result |
|--------|--------|
| `{:error, reason}`, or a raise | Failed once its retries run out |
| `{:fail, reason}` | Failed now, no retries |
| Anything else | Done |

If a compensation fails, the others still run and the run ends `:compensation_failed`. The reason is in `compensation_results` and on the compensation's step execution.

## Workflow Status States

| Status | Description |
|--------|-------------|
| `:compensating` | Currently running compensation handlers |
| `:compensated` | All compensations completed successfully |
| `:compensation_failed` | One or more compensations failed |

## How It Works

1. **Tracking**: Durable tracks which steps with compensations have completed
2. **Rollback**: A step, `Durable.rollback/2` or `on_failure: :rollback` asks for it
3. **Reverse Order**: Compensations run in LIFO order (last completed first)
4. **Recording**: Each compensation is recorded as a step execution
5. **Continuation**: Compensation failures don't stop the chain - all compensations attempt to run

A step in a `parallel` block can't have `compensate:`, which is a compile error. See [Undoing a Parallel Block](parallel.md#undoing-a-parallel-block).

## Best Practices

### Make Compensations Idempotent

Compensations may run multiple times (retries, manual recovery). Design them to be safe to repeat:

```elixir
compensate :cancel_booking, fn ctx ->
  booking_id = ctx.booking_id

  # Check if already cancelled before cancelling
  case BookingAPI.get(booking_id) do
    {:ok, %{status: :cancelled}} -> {:ok, ctx}
    {:ok, _booking} -> BookingAPI.cancel(booking_id); {:ok, ctx}
    {:error, :not_found} -> {:ok, ctx}
  end
end
```

### Store IDs for Cleanup

Always store resource IDs in data so compensations can find them:

```elixir
step :create_resource, [compensate: :delete_resource], fn ctx ->
  resource = ExternalAPI.create(ctx.params)
  {:ok, assign(ctx, :resource_id, resource.id)}  # Store for compensation
end

compensate :delete_resource, fn ctx ->
  ExternalAPI.delete(ctx.resource_id)
  {:ok, ctx}
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
    step :reserve_inventory, [compensate: :release_inventory], fn ctx ->
      items = ctx["items"]

      reservations = Enum.map(items, fn item ->
        {:ok, res} = Inventory.reserve(item.sku, item.quantity)
        res.id
      end)

      {:ok, assign(ctx, :reservation_ids, reservations)}
    end

    step :charge_customer, [compensate: :refund_customer], fn ctx ->
      amount = ctx["total"]
      {:ok, charge} = Payments.charge(ctx["customer_id"], amount)
      {:ok, assign(ctx, :charge_id, charge.id)}
    end

    step :create_shipment, fn ctx ->
      case Shipping.create(ctx["address"], ctx["items"]) do
        {:ok, shipment} -> {:ok, assign(ctx, :shipment_id, shipment.id)}
        # Can't be shipped there: release the inventory and refund the payment.
        {:error, :undeliverable} -> {:rollback, "address can't be delivered to"}
        # The carrier is down: the run is left failed, to retry.
        {:error, reason} -> {:error, reason}
      end
    end

    step :send_confirmation, fn ctx ->
      Email.send_order_confirmation(ctx["customer_email"], %{
        shipment_id: ctx.shipment_id,
        charge_id: ctx.charge_id
      })
      {:ok, ctx}
    end

    # Compensations
    compensate :release_inventory, fn ctx ->
      Enum.each(ctx.reservation_ids, fn id ->
        Inventory.release(id)
      end)
      {:ok, ctx}
    end

    compensate :refund_customer, fn ctx ->
      Payments.refund(ctx.charge_id)
      {:ok, ctx}
    end
  end
end
```
