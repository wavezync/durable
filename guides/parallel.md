# Parallel Execution

Run multiple steps concurrently to speed up workflows.

## Basic Usage

```elixir
defmodule MyApp.OnboardingWorkflow do
  use Durable
  use Durable.Context

  workflow "onboard_user" do
    step :create_user do
      user = Users.create(input())
      put_context(:user_id, user.id)
    end

    # These three steps run concurrently
    parallel do
      step :send_welcome_email do
        Mailer.send_welcome(get_context(:user_id))
        put_context(:email_sent, true)
      end

      step :provision_workspace do
        workspace = Workspaces.create(get_context(:user_id))
        put_context(:workspace_id, workspace.id)
      end

      step :setup_billing do
        Billing.setup(get_context(:user_id))
        put_context(:billing_ready, true)
      end
    end

    # Runs after ALL parallel steps complete
    step :complete do
      Logger.info("User onboarded: #{get_context(:user_id)}")
    end
  end
end
```

## Options

### Merge Strategy (`:merge`)

Controls how context changes from parallel steps are combined.

| Strategy | Description |
|----------|-------------|
| `:deep_merge` | Deep merge all contexts (default) |
| `:last_wins` | Last completed step's context wins on conflicts |
| `:collect` | Collect into `%{step_name => context_changes}` |

```elixir
# Deep merge (default) - combines all nested maps
parallel merge: :deep_merge do
  step :a do
    put_context(:settings, %{notifications: true})
  end
  step :b do
    put_context(:settings, %{theme: "dark"})
  end
end
# Result: %{settings: %{notifications: true, theme: "dark"}}

# Collect - keeps results separate
parallel merge: :collect do
  step :fetch_orders do
    put_context(:count, Orders.count())
  end
  step :fetch_users do
    put_context(:count, Users.count())
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
  step :critical_task do
    # If this fails, other tasks are cancelled
  end
end

# Complete all - continue despite errors
parallel on_error: :complete_all do
  step :send_sms do
    # Even if SMS fails...
  end
  step :send_email do
    # ...email still runs
  end
end
```

## Examples

### Fetching Data from Multiple Sources

```elixir
workflow "dashboard_data" do
  parallel do
    step :fetch_orders do
      orders = Orders.recent(limit: 10)
      put_context(:orders, orders)
    end

    step :fetch_metrics do
      metrics = Analytics.daily_metrics()
      put_context(:metrics, metrics)
    end

    step :fetch_notifications do
      notifications = Notifications.unread()
      put_context(:notifications, notifications)
    end
  end

  step :build_dashboard do
    %{
      orders: get_context(:orders),
      metrics: get_context(:metrics),
      notifications: get_context(:notifications)
    }
  end
end
```

### Independent Operations with Error Tolerance

```elixir
workflow "notify_all" do
  step :prepare do
    put_context(:user_id, input()["user_id"])
    put_context(:message, input()["message"])
  end

  # All notifications run even if some fail
  parallel on_error: :complete_all do
    step :send_email, retry: [max_attempts: 3] do
      Mailer.send(get_context(:user_id), get_context(:message))
    end

    step :send_sms do
      SMS.send(get_context(:user_id), get_context(:message))
    end

    step :send_push do
      Push.send(get_context(:user_id), get_context(:message))
    end
  end

  step :log_results do
    Logger.info("Notifications sent for user #{get_context(:user_id)}")
  end
end
```

### Combining with Retry

Individual steps in a parallel block can have their own retry configuration:

```elixir
parallel do
  step :external_api_call, retry: [max_attempts: 5, backoff: :exponential] do
    ExternalAPI.fetch_data()
  end

  step :quick_local_task do
    LocalDB.query()
  end
end
```

## How It Works

1. The parallel block starts all steps concurrently as separate tasks
2. Each step runs independently with its own context snapshot
3. When all steps complete, contexts are merged based on the merge strategy
4. Execution continues to the next step after the parallel block

## Best Practices

### Keep Parallel Steps Independent

Parallel steps shouldn't depend on each other's context changes:

```elixir
# Good - independent operations
parallel do
  step :a do
    put_context(:result_a, compute_a())
  end
  step :b do
    put_context(:result_b, compute_b())
  end
end

# Bad - step b depends on step a's context
parallel do
  step :a do
    put_context(:value, 42)
  end
  step :b do
    # This won't see :value from step a!
    x = get_context(:value)  # Returns nil
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
  step :process_images do
    Enum.each(images, &process_image/1)
  end
  step :process_documents do
    Enum.each(documents, &process_doc/1)
  end
end

# Less ideal - too many small parallel steps
parallel do
  step :image_1 do process_image(image_1) end
  step :image_2 do process_image(image_2) end
  step :image_3 do process_image(image_3) end
  # Use foreach for this pattern instead
end
```
