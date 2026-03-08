# Workflow Orchestration

Compose workflows by calling child workflows from parent steps.

## Setup

```elixir
defmodule MyApp.MyWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Context
  use Durable.Orchestration  # Import orchestration functions
end
```

## `call_workflow/3` — Synchronous Child

Start a child workflow and wait for its result. The parent suspends until the child completes or fails.

```elixir
workflow "order_pipeline" do
  step :charge, fn data ->
    case call_workflow(MyApp.PaymentWorkflow, %{"amount" => data.total},
           timeout: hours(1)) do
      {:ok, result} ->
        {:ok, assign(data, :payment_id, result["payment_id"])}
      {:error, reason} ->
        {:error, "Payment failed: #{inspect(reason)}"}
    end
  end
end
```

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `:ref` | Reference name for idempotency | Module name |
| `:timeout` | Max wait time in ms | None (wait forever) |
| `:timeout_value` | Value returned on timeout | `:child_timeout` |
| `:queue` | Queue for child workflow | `"default"` |

**Return values:**

| Child Status | Return |
|-------------|--------|
| Completed | `{:ok, child_context}` |
| Failed | `{:error, error_info}` |
| Cancelled | `{:error, error_info}` |
| Timeout | `{:ok, timeout_value}` |

### How It Works

1. Parent step calls `call_workflow(ChildModule, input)`
2. Child workflow execution is created with `parent_workflow_id` set
3. Parent suspends (like `wait_for_event`)
4. Child runs in the queue independently
5. When child completes/fails, parent is automatically notified
6. Parent resumes and `call_workflow` returns the result

## `start_workflow/3` — Fire-and-Forget

Start a child workflow without waiting. Parent continues immediately.

```elixir
workflow "onboarding" do
  step :send_emails, fn data ->
    {:ok, welcome_id} = start_workflow(MyApp.EmailWorkflow,
      %{"to" => data.email, "template" => "welcome"},
      ref: :welcome_email
    )
    {:ok, assign(data, :welcome_workflow_id, welcome_id)}
  end

  step :next_step, fn data ->
    # Parent continues — doesn't wait for email to send
    {:ok, data}
  end
end
```

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `:ref` | Reference name for idempotency | Module name |
| `:queue` | Queue for child workflow | `"default"` |

### Idempotency

Both functions are idempotent on resume. If the parent workflow crashes and restarts:

- `call_workflow` — Won't create a duplicate child. If the child already completed, returns the result immediately.
- `start_workflow` — Won't create a duplicate child. Returns the same `child_id`.

The `:ref` option controls idempotency grouping. Use different refs to create multiple children of the same type:

```elixir
step :send_multiple, fn data ->
  {:ok, _} = start_workflow(MyApp.EmailWorkflow,
    %{"template" => "welcome"}, ref: :welcome)

  {:ok, _} = start_workflow(MyApp.EmailWorkflow,
    %{"template" => "getting_started"}, ref: :getting_started)

  {:ok, data}
end
```

## Cascade Cancellation

Cancelling a parent automatically cancels all active children:

```elixir
# This cancels the parent AND any pending/running/waiting children
Durable.cancel(parent_workflow_id, "User cancelled order")
```

Children that already completed are not affected.

## Querying Children

List child workflows for a parent:

```elixir
# All children
children = Durable.list_children(parent_workflow_id)

# Filter by status
running = Durable.list_children(parent_workflow_id, status: :running)
completed = Durable.list_children(parent_workflow_id, status: :completed)
```

## Examples

### Order Pipeline

A parent workflow that calls payment and notification children:

```elixir
defmodule MyApp.PaymentWorkflow do
  use Durable
  use Durable.Context

  workflow "charge" do
    step :process, fn _data ->
      amount = input()["amount"]
      put_context(:payment_id, "pay_#{:rand.uniform(10_000)}")
      put_context(:charged, amount)
    end
  end
end

defmodule MyApp.EmailWorkflow do
  use Durable
  use Durable.Context

  workflow "send_email" do
    step :deliver, fn _data ->
      to = input()["to"]
      template = input()["template"]
      Mailer.deliver(to, template)
      put_context(:delivered, true)
    end
  end
end

defmodule MyApp.OrderWorkflow do
  use Durable
  use Durable.Context
  use Durable.Orchestration
  use Durable.Helpers

  workflow "process_order" do
    step :validate, fn _data ->
      order = input()
      put_context(:order_id, order["id"])
      put_context(:total, order["total"])
      put_context(:email, order["email"])
    end

    # Synchronous — wait for payment result
    step :charge_payment, fn data ->
      case call_workflow(MyApp.PaymentWorkflow,
             %{"amount" => data.total}, timeout: hours(1)) do
        {:ok, result} ->
          {:ok, assign(data, :payment_id, result["payment_id"])}
        {:error, reason} ->
          {:error, "Payment failed: #{inspect(reason)}"}
      end
    end

    # Fire-and-forget — email sent independently
    step :send_confirmation, fn data ->
      {:ok, email_id} = start_workflow(MyApp.EmailWorkflow,
        %{"to" => data.email, "template" => "order_confirmed"},
        ref: :confirmation_email
      )
      {:ok, assign(data, :email_workflow_id, email_id)}
    end

    step :complete, fn data ->
      {:ok, assign(data, :status, "completed")}
    end
  end
end

# Start the pipeline
{:ok, id} = Durable.start(MyApp.OrderWorkflow, %{
  "id" => "order_123",
  "total" => 99.99,
  "email" => "user@example.com"
})
```

### Nested Workflows (A → B → C)

Workflows can call children that call their own children:

```elixir
defmodule MyApp.StepC do
  use Durable
  use Durable.Context

  workflow "step_c" do
    step :work, fn _data ->
      put_context(:c_result, "done")
    end
  end
end

defmodule MyApp.StepB do
  use Durable
  use Durable.Context
  use Durable.Orchestration

  workflow "step_b" do
    step :call_c, fn data ->
      case call_workflow(MyApp.StepC, %{}) do
        {:ok, result} ->
          {:ok, assign(data, :c_result, result["c_result"])}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end

defmodule MyApp.StepA do
  use Durable
  use Durable.Context
  use Durable.Orchestration

  workflow "step_a" do
    step :call_b, fn data ->
      case call_workflow(MyApp.StepB, %{}) do
        {:ok, result} ->
          {:ok, assign(data, :b_result, result)}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
```

### Error Handling

Handle child failures gracefully with branching:

```elixir
workflow "resilient_order" do
  step :try_payment, fn data ->
    result = call_workflow(MyApp.PaymentWorkflow,
      %{"amount" => data.total}, timeout: minutes(30))

    case result do
      {:ok, payment} ->
        {:ok, data |> assign(:payment, payment) |> assign(:payment_status, :success)}
      {:error, _reason} ->
        {:ok, assign(data, :payment_status, :failed)}
    end
  end

  branch on: fn ctx -> ctx.payment_status end do
    :success ->
      step :fulfill, fn data ->
        {:ok, assign(data, :fulfilled, true)}
      end

    :failed ->
      step :notify_failure, fn data ->
        Mailer.send_payment_failure(data.email)
        {:ok, assign(data, :fulfilled, false)}
      end
  end
end
```

## `call_workflow` Inside `parallel` Blocks

`call_workflow` works inside `parallel` blocks. Child workflows are executed **inline (synchronously)** within the parallel task, so the result is available immediately — no suspend/resume cycle.

```elixir
workflow "enrich_order" do
  step :init, fn input ->
    {:ok, %{order_id: input["order_id"]}}
  end

  parallel on_error: :complete_all do
    step :enrich_customer, fn data ->
      case call_workflow(MyApp.CustomerLookup, %{"id" => data.order_id}, ref: :customer) do
        {:ok, result} -> {:ok, assign(data, :customer, result)}
        {:error, reason} -> {:error, reason}
      end
    end

    step :enrich_inventory, fn data ->
      case call_workflow(MyApp.InventoryCheck, %{"id" => data.order_id}, ref: :inventory) do
        {:ok, result} -> {:ok, assign(data, :inventory, result)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  step :process, fn data ->
    results = data[:__results__]
    # Handle results from parallel call_workflow steps...
    {:ok, data}
  end
end
```

**How it works:** When `call_workflow` detects it's inside a parallel block, it creates the child execution and runs it synchronously via `Executor.execute_workflow` instead of throwing to suspend. The parent's process state is saved beforehand and restored after the child completes.

**Limitation:** Child workflows that use waits (`sleep`, `wait_for_event`, etc.) are not supported inside parallel blocks — they will return an error since the inline execution cannot suspend.

## Limitations

- Child workflows with waits (`sleep`, `wait_for_event`) cannot be used inside `parallel` blocks
- Child workflows run in the queue system — they're not executed inline by default (except in parallel blocks)
- The `:timeout` option requires the timeout checker to be running (same as `wait_for_event`)

## Best Practices

### Use Meaningful Refs

```elixir
# Good — clear what each child does
start_workflow(MyApp.EmailWorkflow, input, ref: :welcome_email)
start_workflow(MyApp.EmailWorkflow, input, ref: :receipt_email)

# Avoid — will collide if calling same module twice
start_workflow(MyApp.EmailWorkflow, input1)
start_workflow(MyApp.EmailWorkflow, input2)  # Returns first child's ID!
```

### Handle Both Success and Failure

```elixir
# Good — handles both cases
case call_workflow(MyApp.PaymentWorkflow, input) do
  {:ok, result} -> handle_success(result)
  {:error, reason} -> handle_failure(reason)
end

# Risky — crashes on child failure
{:ok, result} = call_workflow(MyApp.PaymentWorkflow, input)
```

### Set Timeouts for call_workflow

```elixir
# Good — won't wait forever
call_workflow(MyApp.SlowService, input, timeout: hours(2))

# Risky — waits indefinitely if child hangs
call_workflow(MyApp.SlowService, input)
```
