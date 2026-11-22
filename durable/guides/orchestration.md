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

`child_context` is the child's own data: every key its steps returned or put
in the context, with string keys. It holds none of the engine's bookkeeping.

The child is a run like any other, so its workflow's own `timeout:` applies to
it: a child past it fails, and the parent gets `{:error, error_info}`.

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

A parent that runs out of its `timeout:` cancels its children the same way:
the ones it was waiting on with `call_workflow`, and the ones it started with
`start_workflow` and never waited for. They end `cancelled`, with the reason
`parent_cancelled`. A parent that fails for any other reason leaves its
`start_workflow` children running.

A run that timed out waiting for its child can be retried. `Durable.retry/2`
puts the child the timeout cancelled back to work, with its own `timeout:` in
full again, and the parent waits for it as before.

A cancel passes over a child that is queued to be rolled back: its rollback
finishes.

## Querying Children

List child workflows for a parent:

```elixir
# All children
{:ok, children} = Durable.list_children(parent_workflow_id)

# Filter by status
{:ok, running} = Durable.list_children(parent_workflow_id, status: :running)

# The ! form returns the list, and raises for an id that isn't a run
completed = Durable.list_children!(parent_workflow_id, status: :completed)
```

## Examples

### Order Pipeline

A parent workflow that calls payment and notification children:

```elixir
defmodule MyApp.PaymentWorkflow do
  use Durable
  use Durable.Helpers

  workflow "charge", timeout: minutes(30) do
    # The first step gets the child's input
    step :process, [retry: [max_attempts: 3]], fn %{"amount" => amount} ->
      {:ok, charge} = Payments.charge(amount)
      {:ok, %{payment_id: charge.id, charged: amount}}
    end
  end
end

defmodule MyApp.EmailWorkflow do
  use Durable
  use Durable.Helpers

  workflow "send_email" do
    step :deliver, fn %{"to" => to, "template" => template} = email ->
      Mailer.deliver(to, template)
      {:ok, assign(email, :delivered, true)}
    end
  end
end

defmodule MyApp.OrderWorkflow do
  use Durable
  use Durable.Orchestration
  use Durable.Helpers

  workflow "process_order" do
    # The input's keys are strings, and stay strings in every step
    step :validate, fn order ->
      if order["total"] > 0,
        do: {:ok, assign(order, :order_id, order["id"])},
        else: {:fail, "nothing to charge"}
    end

    # Synchronous — wait for payment result
    step :charge_payment, fn data ->
      case call_workflow(MyApp.PaymentWorkflow,
             %{"amount" => data["total"]}, timeout: hours(1)) do
        {:ok, result} ->
          {:ok, assign(data, :payment_id, result["payment_id"])}
        {:error, reason} ->
          {:error, "Payment failed: #{inspect(reason)}"}
      end
    end

    # Fire-and-forget — email sent independently
    step :send_confirmation, fn data ->
      {:ok, email_id} = start_workflow(MyApp.EmailWorkflow,
        %{"to" => data["email"], "template" => "order_confirmed"},
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
  use Durable.Helpers

  workflow "step_c" do
    step :work, fn data ->
      {:ok, assign(data, :c_result, "done")}
    end
  end
end

defmodule MyApp.StepB do
  use Durable
  use Durable.Helpers
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
  use Durable.Helpers
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
      %{"amount" => data["total"]}, timeout: minutes(30))

    case result do
      {:ok, payment} ->
        {:ok, data |> assign(:payment, payment) |> assign(:payment_status, "success")}
      {:error, _reason} ->
        {:ok, assign(data, :payment_status, "failed")}
    end
  end

  branch on: fn ctx -> ctx.payment_status end do
    "success" ->
      step :fulfill, fn data ->
        {:ok, assign(data, :fulfilled, true)}
      end

    "failed" ->
      step :notify_failure, fn data ->
        Mailer.send_payment_failure(data["email"])
        {:ok, assign(data, :fulfilled, false)}
      end
  end
end
```

## `call_workflow` Inside `parallel` Blocks

`call_workflow` works inside `parallel` blocks. Each lane is its own run, so it waits for its child the way any step does: the lane suspends, the child runs on the queue, and the lane resumes with the result. The block finishes once every lane has.

```elixir
workflow "enrich_order" do
  # The run's input is %{"order_id" => ...}; every lane starts from it
  parallel :enrich, on_error: :collect do
    step :customer, fn data ->
      case call_workflow(MyApp.CustomerLookup, %{"id" => data["order_id"]}, ref: :customer) do
        {:ok, result} -> {:ok, assign(data, :customer, result)}
        {:error, reason} -> {:error, reason}
      end
    end

    step :inventory, fn data ->
      case call_workflow(MyApp.InventoryCheck, %{"id" => data["order_id"]}, ref: :inventory) do
        {:ok, result} -> {:ok, assign(data, :inventory, result)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Each lane is {:ok, what it added} or {:error, reason}
  step :process, fn %{enrich: %{customer: customer, inventory: inventory}} = data ->
    {:ok, assign(data, :ready, match?({{:ok, _}, {:ok, _}}, {customer, inventory}))}
  end
end
```

A child called from a lane can wait like any workflow: sleep, wait for an event or input, or call workflows of its own.

## Limitations

- Child workflows run on the queue, like any run
- A child's input must be a map: anything else raises `ArgumentError` in the calling step
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
