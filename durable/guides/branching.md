# Conditional Branching

Execute different steps based on runtime conditions.

## Basic Usage

The `branch` macro evaluates a condition function and executes only the matching clause:

```elixir
defmodule MyApp.DocumentProcessor do
  use Durable
  use Durable.Helpers

  workflow "process_document" do
    step :classify, fn ctx ->
      doc_type = AI.classify(ctx["content"])
      {:ok, assign(ctx, :doc_type, doc_type)}
    end

    branch on: fn ctx -> ctx.doc_type end do
      :invoice ->
        step :process_invoice, fn ctx ->
          {:ok, assign(ctx, :extracted, extract_invoice_data(ctx))}
        end

      :contract ->
        step :process_contract, fn ctx ->
          {:ok, assign(ctx, :extracted, extract_contract_data(ctx))}
        end

      _ ->
        step :manual_review, fn ctx ->
          {:ok, assign(ctx, :needs_review, true)}
        end
    end

    # Runs after ANY branch completes
    step :save, fn ctx ->
      save_to_database(ctx)
      {:ok, ctx}
    end
  end
end
```

## Pattern Matching

The `on:` option takes a function that returns a value. That value is matched against clause patterns.

### Supported Patterns

| Pattern | Example |
|---------|---------|
| Atoms | `:invoice`, `:pending`, `:active` |
| Strings | `"pdf"`, `"high"` |
| Integers | `1`, `2`, `100` |
| Booleans | `true`, `false` |
| Default | `_` (matches anything) |

```elixir
# Matching atoms
branch on: fn ctx -> ctx.status end do
  :active ->
    step :handle_active, fn ctx -> {:ok, ctx} end
  :pending ->
    step :handle_pending, fn ctx -> {:ok, ctx} end
  _ ->
    step :handle_other, fn ctx -> {:ok, ctx} end
end

# Matching strings
branch on: fn ctx -> ctx.format end do
  "pdf" ->
    step :process_pdf, fn ctx -> {:ok, ctx} end
  "docx" ->
    step :process_docx, fn ctx -> {:ok, ctx} end
  _ ->
    step :unsupported, fn ctx -> {:ok, ctx} end
end

# Matching booleans
branch on: fn ctx -> ctx.is_premium end do
  true ->
    step :premium_flow, fn ctx -> {:ok, ctx} end
  false ->
    step :standard_flow, fn ctx -> {:ok, ctx} end
end

# Matching integers
branch on: fn ctx -> ctx.tier end do
  1 ->
    step :tier_one, fn ctx -> {:ok, ctx} end
  2 ->
    step :tier_two, fn ctx -> {:ok, ctx} end
  3 ->
    step :tier_three, fn ctx -> {:ok, ctx} end
end
```

## Multiple Steps per Branch

Each branch can contain multiple steps that execute sequentially:

```elixir
branch on: fn ctx -> ctx.order_type end do
  :subscription ->
    step :validate_subscription, fn ctx ->
      {:ok, assign(ctx, :validated, validate_recurring_payment(ctx))}
    end

    step :setup_billing, fn ctx ->
      {:ok, assign(ctx, :billing, create_subscription_billing(ctx))}
    end

    step :schedule_renewals, fn ctx ->
      {:ok, assign(ctx, :renewal_scheduled, schedule_monthly_charge(ctx))}
    end

  :one_time ->
    step :process_payment, fn ctx ->
      {:ok, assign(ctx, :charged, charge_once(ctx))}
    end
end
```

## Default Clause

The `_` pattern matches any value not matched by other clauses:

```elixir
branch on: fn ctx -> ctx.priority end do
  :critical ->
    step :alert_oncall, fn ctx ->
      PagerDuty.alert()
      {:ok, ctx}
    end

  :high ->
    step :create_urgent_ticket, fn ctx ->
      Tickets.create(priority: :high)
      {:ok, ctx}
    end

  _ ->
    # Matches :medium, :low, or any other value
    step :create_normal_ticket, fn ctx ->
      Tickets.create(priority: :normal)
      {:ok, ctx}
    end
end
```

## Examples

### Order Processing by Type

```elixir
workflow "process_order" do
  step :load_order, fn ctx ->
    order = Orders.get(ctx["order_id"])
    {:ok, %{order: order, order_type: order.type}}
  end

  branch on: fn ctx -> ctx.order_type end do
    :digital ->
      step :generate_download_link, fn ctx ->
        link = Downloads.create(ctx.order)
        {:ok, ctx
        |> assign(:delivery_method, :download)
        |> assign(:download_link, link)}
      end

    :physical ->
      step :create_shipment, fn ctx ->
        shipment = Shipping.create(ctx.order)
        {:ok, ctx
        |> assign(:delivery_method, :shipping)
        |> assign(:tracking_number, shipment.tracking)}
      end

      step :notify_warehouse, fn ctx ->
        Warehouse.queue_pick(ctx.order)
        {:ok, ctx}
      end

    :service ->
      step :schedule_appointment, fn ctx ->
        slot = Calendar.book(ctx.order)
        {:ok, ctx
        |> assign(:delivery_method, :appointment)
        |> assign(:appointment, slot)}
      end
  end

  step :send_confirmation, fn ctx ->
    Email.send_order_confirmation(ctx.order, ctx.delivery_method)
    {:ok, ctx}
  end
end
```

### User Verification Flow

```elixir
workflow "verify_user" do
  step :check_verification_status, fn ctx ->
    user = Users.get(ctx["user_id"])
    {:ok, %{
      user: user,
      verified: user.email_verified and user.phone_verified,
      verification_method: user.preferred_verification
    }}
  end

  branch on: fn ctx -> ctx.verified end do
    true ->
      step :already_verified, fn ctx ->
        {:ok, assign(ctx, :result, :already_verified)}
      end

    false ->
      # Nested branch for verification method
      branch on: fn ctx -> ctx.verification_method end do
        :email ->
          step :send_email_code, fn ctx ->
            code = generate_code()
            Email.send_verification(ctx.user.email, code)
            {:ok, assign(ctx, :pending_verification, :email)}
          end

        :sms ->
          step :send_sms_code, fn ctx ->
            code = generate_code()
            SMS.send(ctx.user.phone, code)
            {:ok, assign(ctx, :pending_verification, :sms)}
          end

        _ ->
          step :require_manual_verification, fn ctx ->
            Support.create_verification_ticket(ctx.user)
            {:ok, assign(ctx, :pending_verification, :manual)}
          end
      end
  end
end
```

### Amount-Based Approval Routing

```elixir
workflow "expense_routing" do
  step :load_expense, fn ctx ->
    expense = Expenses.get(ctx["expense_id"])
    {:ok, %{expense: expense, amount: expense.amount}}
  end

  step :determine_tier, fn ctx ->
    tier = cond do
      ctx.amount > 10000 -> :executive
      ctx.amount > 1000 -> :manager
      ctx.amount > 100 -> :team_lead
      true -> :auto
    end
    {:ok, assign(ctx, :approval_tier, tier)}
  end

  branch on: fn ctx -> ctx.approval_tier end do
    :executive ->
      step :cfo_approval, fn ctx ->
        request_approval(:cfo, ctx.expense)
        {:ok, ctx}
      end

      step :ceo_approval, fn ctx ->
        request_approval(:ceo, ctx.expense)
        {:ok, ctx}
      end

    :manager ->
      step :manager_approval, fn ctx ->
        request_approval(:manager, ctx.expense)
        {:ok, ctx}
      end

    :team_lead ->
      step :team_lead_approval, fn ctx ->
        request_approval(:team_lead, ctx.expense)
        {:ok, ctx}
      end

    :auto ->
      step :auto_approve, fn ctx ->
        Expenses.approve(ctx.expense, approver: :system)
        {:ok, ctx}
      end
  end
end
```

## Branch vs Decision

Durable provides two ways to control flow:

| Feature | `branch` | `decision` |
|---------|----------|------------|
| Use case | Execute different step groups | Jump to a specific step |
| Syntax | Pattern matching clauses | Return `{:goto, :step, ctx}` |
| Multiple steps | Yes, per clause | No, single jump target |
| Readability | High, reads top-to-bottom | Lower, requires tracing jumps |

**Use `branch` when:**
- You have distinct paths with different steps
- Each path may have multiple steps
- You want readable, maintainable code

**Use `decision` when:**
- You need to skip certain steps
- You have simple conditional jumps
- The workflow is linear with occasional skips

```elixir
# Prefer branch for distinct paths
branch on: fn ctx -> ctx.type end do
  :a ->
    step :handle_a, fn ctx -> {:ok, ctx} end
  :b ->
    step :handle_b, fn ctx -> {:ok, ctx} end
end

# Decision for simple skips
decision :check_skip, fn ctx ->
  if ctx.skip_optional do
    {:goto, :final_step, ctx}
  else
    {:ok, ctx}
  end
end

step :optional_step, fn ctx -> {:ok, ctx} end
step :final_step, fn ctx -> {:ok, ctx} end
```

## Best Practices

### Always Include a Default Clause

```elixir
branch on: fn ctx -> ctx.status end do
  :active ->
    step :handle_active, fn ctx -> {:ok, ctx} end
  :pending ->
    step :handle_pending, fn ctx -> {:ok, ctx} end
  _ ->
    # Handle unexpected values gracefully
    step :handle_unknown, fn ctx ->
      Logger.warning("Unknown status: #{ctx.status}")
      {:ok, assign(ctx, :error, :unknown_status)}
    end
end
```

### Keep Branches Focused

```elixir
# Good - each branch does one thing
branch on: fn ctx -> ctx.payment_method end do
  :card ->
    step :charge_card, fn ctx -> {:ok, ctx} end
  :bank ->
    step :initiate_transfer, fn ctx -> {:ok, ctx} end
  :crypto ->
    step :process_crypto, fn ctx -> {:ok, ctx} end
end

# Avoid - too much logic in branches
branch on: fn ctx -> ctx.type end do
  :a ->
    step :step1, fn ctx -> {:ok, ctx} end
    step :step2, fn ctx -> {:ok, ctx} end
    step :step3, fn ctx -> {:ok, ctx} end
    step :step4, fn ctx -> {:ok, ctx} end
    step :step5, fn ctx -> {:ok, ctx} end
    # Consider extracting to separate workflow
end
```

### Use Descriptive Keys

```elixir
# Good
step :classify, fn ctx ->
  {:ok, assign(ctx, :document_type, :invoice)}
end
branch on: fn ctx -> ctx.document_type end do ... end

# Avoid
step :classify, fn ctx ->
  {:ok, assign(ctx, :t, :i)}
end
branch on: fn ctx -> ctx.t end do ... end
```
