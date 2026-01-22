# Parallel Execution

Run multiple steps concurrently and collect results as tagged tuples.

## Basic Usage

```elixir
defmodule MyApp.OnboardingWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Context

  workflow "onboard_user" do
    step :create_user, fn data ->
      user = Users.create(data)
      {:ok, %{user_id: user.id}}
    end

    # These three steps run concurrently
    parallel do
      step :send_welcome_email, fn data ->
        Mailer.send_welcome(data.user_id)
        {:ok, %{email_sent: true}}
      end

      step :provision_workspace, fn data ->
        workspace = Workspaces.create(data.user_id)
        {:ok, %{workspace_id: workspace.id}}
      end

      step :setup_billing, fn data ->
        Billing.setup(data.user_id)
        {:ok, %{billing_ready: true}}
      end
    end

    # Access results from parallel steps
    step :complete, fn data ->
      results = data[:__results__]

      case {results[:send_welcome_email], results[:provision_workspace]} do
        {{:ok, _}, {:ok, _}} ->
          {:ok, Map.put(data, :onboarded, true)}

        _ ->
          {:error, "Onboarding incomplete"}
      end
    end
  end
end
```

## Results Model

Parallel steps produce results stored in the `__results__` key with tagged tuples:

```elixir
# After parallel block completes, context contains:
%{
  ...original_context,
  __results__: %{
    step_name: {:ok, returned_data} | {:error, reason}
  }
}
```

### Accessing Results

Use `parallel_results/0`, `parallel_result/1`, and `parallel_ok?/1` helpers:

```elixir
step :handle_results, fn ctx ->
  # Get all results
  results = parallel_results()  # => %{payment: {:ok, ...}, delivery: {:error, ...}}

  # Get specific result
  case parallel_result(:payment) do
    {:ok, payment} -> # handle success
    {:error, reason} -> # handle error
  end

  # Check if step succeeded
  if parallel_ok?(:payment) do
    # payment was successful
  end

  {:ok, ctx}
end
```

Or access directly from the context:

```elixir
step :handle_results, fn ctx ->
  case ctx[:__results__][:payment] do
    {:ok, payment} -> {:ok, Map.put(ctx, :payment_id, payment.id)}
    {:error, _} -> {:goto, :handle_payment_failure, ctx}
  end
end
```

## The `into:` Callback

Use `into:` to transform results before passing to the next step:

```elixir
parallel into: fn ctx, results ->
  # ctx = original context (unchanged by parallel steps)
  # results = %{step_name => {:ok, data} | {:error, reason}}

  case {results[:payment], results[:delivery]} do
    {{:ok, payment}, {:ok, delivery}} ->
      # Return transformed context
      {:ok, Map.merge(ctx, %{
        payment_id: payment.id,
        delivery_status: delivery.status
      })}

    {{:ok, _}, {:error, :not_found}} ->
      # Jump to another step
      {:goto, :handle_backorder, ctx}

    _ ->
      # Fail the workflow
      {:error, "Critical failure"}
  end
end do
  step :payment, fn ctx -> {:ok, %{id: 123}} end
  step :delivery, fn ctx -> {:error, :not_found} end
end
```

### `into:` Return Values

| Return | Effect |
|--------|--------|
| `{:ok, ctx}` | Continue to next step with new context |
| `{:error, reason}` | Fail the workflow |
| `{:goto, :step_name, ctx}` | Jump to the named step |

When `into:` is provided, the `__results__` key is NOT added to the context - the `into:` callback controls what the next step receives.

## The `returns:` Option

Customize the key name for a step's result:

```elixir
parallel do
  step :fetch_order, returns: :order do
    fn ctx -> {:ok, %{items: [...]}} end
  end

  step :fetch_user, returns: :user do
    fn ctx -> {:ok, %{name: "John"}} end
  end
end

# Results:
# %{__results__: %{order: {:ok, %{items: [...]}}, user: {:ok, %{name: "John"}}}}
```

This is useful when the step name is verbose but you want a simpler key in results.

## Error Handling

### `:on_error` Option

| Strategy | Description |
|----------|-------------|
| `:fail_fast` | Stop on first error (default) |
| `:complete_all` | Wait for all steps, collect all results |

```elixir
# Fail fast (default) - workflow fails on first error
parallel on_error: :fail_fast do
  step :critical_task, fn ctx ->
    {:ok, ctx}
  end
end

# Complete all - continue despite errors, let next step handle
parallel on_error: :complete_all do
  step :send_sms, fn ctx ->
    case SMS.send(ctx.user_id) do
      :ok -> {:ok, %{sms_sent: true}}
      {:error, e} -> {:error, e}  # Preserved in results
    end
  end

  step :send_email, fn ctx ->
    case Mailer.send(ctx.user_id) do
      :ok -> {:ok, %{email_sent: true}}
      {:error, e} -> {:error, e}  # Preserved in results
    end
  end
end

step :check_notifications, fn ctx ->
  results = ctx[:__results__]
  sms_ok = match?({:ok, _}, results[:send_sms])
  email_ok = match?({:ok, _}, results[:send_email])

  cond do
    sms_ok and email_ok -> {:ok, Map.put(ctx, :all_sent, true)}
    sms_ok or email_ok -> {:ok, Map.put(ctx, :partial_sent, true)}
    true -> {:error, "All notifications failed"}
  end
end
```

## Examples

### Fetching Data from Multiple Sources

```elixir
workflow "dashboard_data" do
  step :init, fn input ->
    {:ok, %{user_id: input["user_id"]}}
  end

  parallel on_error: :complete_all do
    step :fetch_orders, fn ctx ->
      case Orders.recent(limit: 10) do
        {:ok, orders} -> {:ok, %{orders: orders}}
        {:error, e} -> {:error, e}
      end
    end

    step :fetch_metrics, fn ctx ->
      {:ok, %{metrics: Analytics.daily_metrics()}}
    end

    step :fetch_notifications, fn ctx ->
      {:ok, %{notifications: Notifications.unread()}}
    end
  end

  step :build_dashboard, fn ctx ->
    results = ctx[:__results__]

    # Handle partial failures gracefully
    orders = case results[:fetch_orders] do
      {:ok, data} -> data.orders
      {:error, _} -> []
    end

    metrics = case results[:fetch_metrics] do
      {:ok, data} -> data.metrics
      {:error, _} -> %{}
    end

    {:ok, %{
      dashboard: %{orders: orders, metrics: metrics},
      has_errors: Enum.any?(results, fn {_, r} -> match?({:error, _}, r) end)
    }}
  end
end
```

### Conditional Branching Based on Results

```elixir
workflow "order_processing" do
  step :validate, fn input ->
    {:ok, %{order_id: input["order_id"]}}
  end

  parallel into: fn ctx, results ->
    case {results[:check_inventory], results[:check_payment]} do
      {{:ok, inv}, {:ok, pay}} when inv.available and pay.authorized ->
        {:ok, Map.merge(ctx, %{inventory: inv, payment: pay, ready: true})}

      {{:ok, _}, {:error, :card_declined}} ->
        {:goto, :handle_payment_issue, ctx}

      {{:error, :out_of_stock}, _} ->
        {:goto, :handle_backorder, ctx}

      _ ->
        {:error, "Order validation failed"}
    end
  end do
    step :check_inventory, fn ctx ->
      case Inventory.check(ctx.order_id) do
        {:ok, inv} -> {:ok, %{available: inv.quantity > 0, quantity: inv.quantity}}
        {:error, e} -> {:error, e}
      end
    end

    step :check_payment, fn ctx ->
      case Payment.authorize(ctx.order_id) do
        {:ok, auth} -> {:ok, %{authorized: true, auth_code: auth.code}}
        {:error, e} -> {:error, e}
      end
    end
  end

  step :fulfill_order, fn ctx ->
    # Only reached if both checks passed
    {:ok, Map.put(ctx, :fulfilled, true)}
  end

  step :handle_payment_issue, fn ctx ->
    {:ok, Map.put(ctx, :needs_payment_retry, true)}
  end

  step :handle_backorder, fn ctx ->
    {:ok, Map.put(ctx, :backordered, true)}
  end
end
```

### With Retry on Individual Steps

```elixir
parallel do
  step :external_api_call, [retry: [max_attempts: 5, backoff: :exponential]], fn ctx ->
    result = ExternalAPI.fetch_data()
    {:ok, %{external: result}}
  end

  step :quick_local_task, fn ctx ->
    {:ok, %{local: LocalDB.query()}}
  end
end
```

## How It Works

1. The parallel block starts all steps concurrently as separate tasks
2. Each step receives a copy of the current context (steps are isolated)
3. When all steps complete, results are collected into `__results__` map
4. If `into:` is provided, it transforms the results
5. Execution continues to the next step

## Best Practices

### Keep Parallel Steps Independent

Parallel steps shouldn't depend on each other's data:

```elixir
# Good - independent operations
parallel do
  step :a, fn ctx -> {:ok, %{result_a: compute_a()}} end
  step :b, fn ctx -> {:ok, %{result_b: compute_b()}} end
end

# Bad - step b depends on step a's data
parallel do
  step :a, fn ctx -> {:ok, Map.put(ctx, :value, 42)} end
  step :b, fn ctx ->
    # ctx doesn't have :value - steps are isolated!
    x = ctx[:value]  # Returns nil
    {:ok, ctx}
  end
end
```

### Use `into:` for Complex Result Handling

When you need to:
- Transform multiple results into a single value
- Make branching decisions based on results
- Fail early on certain combinations

```elixir
parallel into: fn ctx, results ->
  # Clear logic for handling result combinations
  case {results[:a], results[:b]} do
    {{:ok, a}, {:ok, b}} -> {:ok, combine(ctx, a, b)}
    {{:error, _}, _} -> {:goto, :handle_a_failure, ctx}
    {_, {:error, _}} -> {:goto, :handle_b_failure, ctx}
  end
end do
  step :a, fn ctx -> ... end
  step :b, fn ctx -> ... end
end
```

### Choose the Right Error Strategy

- Use `:fail_fast` when all steps must succeed (transactions, critical paths)
- Use `:complete_all` when steps are independent and you want to handle partial success

### Return Focused Data from Steps

Return only the data the step produces, not the entire context:

```elixir
# Good - return just the new data
step :fetch_user, fn ctx ->
  user = Users.get(ctx.user_id)
  {:ok, %{name: user.name, email: user.email}}
end

# Less ideal - returning modified context
step :fetch_user, fn ctx ->
  user = Users.get(ctx.user_id)
  {:ok, Map.put(ctx, :user, user)}  # Works but adds unnecessary data
end
```
