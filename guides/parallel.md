# Parallel Execution

Run multiple steps concurrently to speed up workflows.

## Basic Usage

```elixir
defmodule MyApp.OnboardingWorkflow do
  use Durable
  use Durable.Helpers

  workflow "onboard_user" do
    step :create_user, fn data ->
      user = Users.create(data)
      {:ok, %{user_id: user.id}}
    end

    # These three steps run concurrently
    parallel do
      step :send_welcome_email, fn data ->
        Mailer.send_welcome(data.user_id)
        {:ok, assign(data, :email_sent, true)}
      end

      step :provision_workspace, fn data ->
        workspace = Workspaces.create(data.user_id)
        {:ok, assign(data, :workspace_id, workspace.id)}
      end

      step :setup_billing, fn data ->
        Billing.setup(data.user_id)
        {:ok, assign(data, :billing_ready, true)}
      end
    end

    # Runs after ALL parallel steps complete
    step :complete, fn data ->
      Logger.info("User onboarded: #{data.user_id}")
      {:ok, data}
    end
  end
end
```

## Options

### Merge Strategy (`:merge`)

Controls how data changes from parallel steps are combined.

| Strategy | Description |
|----------|-------------|
| `:deep_merge` | Deep merge all data (default) |
| `:last_wins` | Last completed step's data wins on conflicts |
| `:collect` | Collect into `%{step_name => data_changes}` |

```elixir
# Deep merge (default) - combines all nested maps
parallel merge: :deep_merge do
  step :a, fn data ->
    {:ok, assign(data, :settings, %{notifications: true})}
  end
  step :b, fn data ->
    {:ok, assign(data, :settings, %{theme: "dark"})}
  end
end
# Result: %{settings: %{notifications: true, theme: "dark"}}

# Collect - keeps results separate
parallel merge: :collect do
  step :fetch_orders, fn data ->
    {:ok, assign(data, :count, Orders.count())}
  end
  step :fetch_users, fn data ->
    {:ok, assign(data, :count, Users.count())}
  end
end
# Result: %{parallel_results: %{fetch_orders: %{count: 10}, fetch_users: %{count: 5}}}
```

### Error Handling (`:on_error`)

Controls what happens when a parallel step fails.

| Strategy | Description |
|----------|-------------|
| `:fail_fast` | Cancel other steps immediately (default) |
| `:complete_all` | Wait for all steps, collect errors |

```elixir
# Fail fast (default) - stop everything on first error
parallel on_error: :fail_fast do
  step :critical_task, fn data ->
    # If this fails, other tasks are cancelled
    {:ok, data}
  end
end

# Complete all - continue despite errors
parallel on_error: :complete_all do
  step :send_sms, fn data ->
    # Even if SMS fails...
    {:ok, data}
  end
  step :send_email, fn data ->
    # ...email still runs
    {:ok, data}
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

  parallel do
    step :fetch_orders, fn data ->
      orders = Orders.recent(limit: 10)
      {:ok, assign(data, :orders, orders)}
    end

    step :fetch_metrics, fn data ->
      metrics = Analytics.daily_metrics()
      {:ok, assign(data, :metrics, metrics)}
    end

    step :fetch_notifications, fn data ->
      notifications = Notifications.unread()
      {:ok, assign(data, :notifications, notifications)}
    end
  end

  step :build_dashboard, fn data ->
    dashboard = %{
      orders: data.orders,
      metrics: data.metrics,
      notifications: data.notifications
    }
    {:ok, assign(data, :dashboard, dashboard)}
  end
end
```

### Independent Operations with Error Tolerance

```elixir
workflow "notify_all" do
  step :prepare, fn data ->
    {:ok, %{user_id: data["user_id"], message: data["message"]}}
  end

  # All notifications run even if some fail
  parallel on_error: :complete_all do
    step :send_email, [retry: [max_attempts: 3]], fn data ->
      Mailer.send(data.user_id, data.message)
      {:ok, data}
    end

    step :send_sms, fn data ->
      SMS.send(data.user_id, data.message)
      {:ok, data}
    end

    step :send_push, fn data ->
      Push.send(data.user_id, data.message)
      {:ok, data}
    end
  end

  step :log_results, fn data ->
    Logger.info("Notifications sent for user #{data.user_id}")
    {:ok, data}
  end
end
```

### Combining with Retry

Individual steps in a parallel block can have their own retry configuration:

```elixir
parallel do
  step :external_api_call, [retry: [max_attempts: 5, backoff: :exponential]], fn data ->
    result = ExternalAPI.fetch_data()
    {:ok, assign(data, :external, result)}
  end

  step :quick_local_task, fn data ->
    result = LocalDB.query()
    {:ok, assign(data, :local, result)}
  end
end
```

## How It Works

1. The parallel block starts all steps concurrently as separate tasks
2. Each step runs independently with its own data snapshot
3. When all steps complete, data is merged based on the merge strategy
4. Execution continues to the next step after the parallel block

## Best Practices

### Keep Parallel Steps Independent

Parallel steps shouldn't depend on each other's data changes:

```elixir
# Good - independent operations
parallel do
  step :a, fn data ->
    {:ok, assign(data, :result_a, compute_a())}
  end
  step :b, fn data ->
    {:ok, assign(data, :result_b, compute_b())}
  end
end

# Bad - step b depends on step a's data
parallel do
  step :a, fn data ->
    {:ok, assign(data, :value, 42)}
  end
  step :b, fn data ->
    # This won't see :value from step a!
    x = data[:value]  # Returns nil
    {:ok, data}
  end
end
```

### Use Appropriate Error Strategy

- Use `:fail_fast` when all steps must succeed (transactions, critical paths)
- Use `:complete_all` when steps are independent (notifications, logging)

### Consider Step Granularity

Group related work into single steps rather than many tiny parallel steps:

```elixir
# Good - logical grouping
parallel do
  step :process_images, fn data ->
    Enum.each(data.images, &process_image/1)
    {:ok, data}
  end
  step :process_documents, fn data ->
    Enum.each(data.documents, &process_doc/1)
    {:ok, data}
  end
end

# Less ideal - too many small parallel steps
parallel do
  step :image_1, fn data -> process_image(data.image_1); {:ok, data} end
  step :image_2, fn data -> process_image(data.image_2); {:ok, data} end
  step :image_3, fn data -> process_image(data.image_3); {:ok, data} end
  # Use foreach for this pattern instead
end
```
