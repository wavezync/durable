# Conditional Branching

Execute different steps based on runtime conditions.

## Basic Usage

The `branch` macro evaluates a condition function and executes only the matching clause:

```elixir
defmodule MyApp.DocumentProcessor do
  use Durable
  use Durable.Helpers

  workflow "process_document" do
    step :classify, fn data ->
      doc_type = AI.classify(data["content"])
      {:ok, assign(data, :doc_type, doc_type)}
    end

    branch on: fn data -> data.doc_type end do
      :invoice ->
        step :process_invoice, fn data ->
          {:ok, assign(data, :extracted, extract_invoice_data(data))}
        end

      :contract ->
        step :process_contract, fn data ->
          {:ok, assign(data, :extracted, extract_contract_data(data))}
        end

      _ ->
        step :manual_review, fn data ->
          {:ok, assign(data, :needs_review, true)}
        end
    end

    # Runs after ANY branch completes
    step :save, fn data ->
      save_to_database(data)
      {:ok, data}
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
branch on: fn data -> data.status end do
  :active ->
    step :handle_active, fn data -> {:ok, data} end
  :pending ->
    step :handle_pending, fn data -> {:ok, data} end
  _ ->
    step :handle_other, fn data -> {:ok, data} end
end

# Matching strings
branch on: fn data -> data.format end do
  "pdf" ->
    step :process_pdf, fn data -> {:ok, data} end
  "docx" ->
    step :process_docx, fn data -> {:ok, data} end
  _ ->
    step :unsupported, fn data -> {:ok, data} end
end

# Matching booleans
branch on: fn data -> data.is_premium end do
  true ->
    step :premium_flow, fn data -> {:ok, data} end
  false ->
    step :standard_flow, fn data -> {:ok, data} end
end

# Matching integers
branch on: fn data -> data.tier end do
  1 ->
    step :tier_one, fn data -> {:ok, data} end
  2 ->
    step :tier_two, fn data -> {:ok, data} end
  3 ->
    step :tier_three, fn data -> {:ok, data} end
end
```

## Multiple Steps per Branch

Each branch can contain multiple steps that execute sequentially:

```elixir
branch on: fn data -> data.order_type end do
  :subscription ->
    step :validate_subscription, fn data ->
      {:ok, assign(data, :validated, validate_recurring_payment(data))}
    end

    step :setup_billing, fn data ->
      {:ok, assign(data, :billing, create_subscription_billing(data))}
    end

    step :schedule_renewals, fn data ->
      {:ok, assign(data, :renewal_scheduled, schedule_monthly_charge(data))}
    end

  :one_time ->
    step :process_payment, fn data ->
      {:ok, assign(data, :charged, charge_once(data))}
    end
end
```

## Default Clause

The `_` pattern matches any value not matched by other clauses:

```elixir
branch on: fn data -> data.priority end do
  :critical ->
    step :alert_oncall, fn data ->
      PagerDuty.alert()
      {:ok, data}
    end

  :high ->
    step :create_urgent_ticket, fn data ->
      Tickets.create(priority: :high)
      {:ok, data}
    end

  _ ->
    # Matches :medium, :low, or any other value
    step :create_normal_ticket, fn data ->
      Tickets.create(priority: :normal)
      {:ok, data}
    end
end
```

## Examples

### Order Processing by Type

```elixir
workflow "process_order" do
  step :load_order, fn data ->
    order = Orders.get(data["order_id"])
    {:ok, %{order: order, order_type: order.type}}
  end

  branch on: fn data -> data.order_type end do
    :digital ->
      step :generate_download_link, fn data ->
        link = Downloads.create(data.order)
        {:ok, data
        |> assign(:delivery_method, :download)
        |> assign(:download_link, link)}
      end

    :physical ->
      step :create_shipment, fn data ->
        shipment = Shipping.create(data.order)
        {:ok, data
        |> assign(:delivery_method, :shipping)
        |> assign(:tracking_number, shipment.tracking)}
      end

      step :notify_warehouse, fn data ->
        Warehouse.queue_pick(data.order)
        {:ok, data}
      end

    :service ->
      step :schedule_appointment, fn data ->
        slot = Calendar.book(data.order)
        {:ok, data
        |> assign(:delivery_method, :appointment)
        |> assign(:appointment, slot)}
      end
  end

  step :send_confirmation, fn data ->
    Email.send_order_confirmation(data.order, data.delivery_method)
    {:ok, data}
  end
end
```

### User Verification Flow

```elixir
workflow "verify_user" do
  step :check_verification_status, fn data ->
    user = Users.get(data["user_id"])
    {:ok, %{
      user: user,
      verified: user.email_verified and user.phone_verified,
      verification_method: user.preferred_verification
    }}
  end

  branch on: fn data -> data.verified end do
    true ->
      step :already_verified, fn data ->
        {:ok, assign(data, :result, :already_verified)}
      end

    false ->
      # Nested branch for verification method
      branch on: fn data -> data.verification_method end do
        :email ->
          step :send_email_code, fn data ->
            code = generate_code()
            Email.send_verification(data.user.email, code)
            {:ok, assign(data, :pending_verification, :email)}
          end

        :sms ->
          step :send_sms_code, fn data ->
            code = generate_code()
            SMS.send(data.user.phone, code)
            {:ok, assign(data, :pending_verification, :sms)}
          end

        _ ->
          step :require_manual_verification, fn data ->
            Support.create_verification_ticket(data.user)
            {:ok, assign(data, :pending_verification, :manual)}
          end
      end
  end
end
```

### Amount-Based Approval Routing

```elixir
workflow "expense_routing" do
  step :load_expense, fn data ->
    expense = Expenses.get(data["expense_id"])
    {:ok, %{expense: expense, amount: expense.amount}}
  end

  step :determine_tier, fn data ->
    tier = cond do
      data.amount > 10000 -> :executive
      data.amount > 1000 -> :manager
      data.amount > 100 -> :team_lead
      true -> :auto
    end
    {:ok, assign(data, :approval_tier, tier)}
  end

  branch on: fn data -> data.approval_tier end do
    :executive ->
      step :cfo_approval, fn data ->
        request_approval(:cfo, data.expense)
        {:ok, data}
      end

      step :ceo_approval, fn data ->
        request_approval(:ceo, data.expense)
        {:ok, data}
      end

    :manager ->
      step :manager_approval, fn data ->
        request_approval(:manager, data.expense)
        {:ok, data}
      end

    :team_lead ->
      step :team_lead_approval, fn data ->
        request_approval(:team_lead, data.expense)
        {:ok, data}
      end

    :auto ->
      step :auto_approve, fn data ->
        Expenses.approve(data.expense, approver: :system)
        {:ok, data}
      end
  end
end
```

## Branch vs Decision

Durable provides two ways to control flow:

| Feature | `branch` | `decision` |
|---------|----------|------------|
| Use case | Execute different step groups | Jump to a specific step |
| Syntax | Pattern matching clauses | Return `{:goto, :step, data}` |
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
branch on: fn data -> data.type end do
  :a ->
    step :handle_a, fn data -> {:ok, data} end
  :b ->
    step :handle_b, fn data -> {:ok, data} end
end

# Decision for simple skips
decision :check_skip, fn data ->
  if data.skip_optional do
    {:goto, :final_step, data}
  else
    {:ok, data}
  end
end

step :optional_step, fn data -> {:ok, data} end
step :final_step, fn data -> {:ok, data} end
```

## Best Practices

### Always Include a Default Clause

```elixir
branch on: fn data -> data.status end do
  :active ->
    step :handle_active, fn data -> {:ok, data} end
  :pending ->
    step :handle_pending, fn data -> {:ok, data} end
  _ ->
    # Handle unexpected values gracefully
    step :handle_unknown, fn data ->
      Logger.warning("Unknown status: #{data.status}")
      {:ok, assign(data, :error, :unknown_status)}
    end
end
```

### Keep Branches Focused

```elixir
# Good - each branch does one thing
branch on: fn data -> data.payment_method end do
  :card ->
    step :charge_card, fn data -> {:ok, data} end
  :bank ->
    step :initiate_transfer, fn data -> {:ok, data} end
  :crypto ->
    step :process_crypto, fn data -> {:ok, data} end
end

# Avoid - too much logic in branches
branch on: fn data -> data.type end do
  :a ->
    step :step1, fn data -> {:ok, data} end
    step :step2, fn data -> {:ok, data} end
    step :step3, fn data -> {:ok, data} end
    step :step4, fn data -> {:ok, data} end
    step :step5, fn data -> {:ok, data} end
    # Consider extracting to separate workflow
end
```

### Use Descriptive Keys

```elixir
# Good
step :classify, fn data ->
  {:ok, assign(data, :document_type, :invoice)}
end
branch on: fn data -> data.document_type end do ... end

# Avoid
step :classify, fn data ->
  {:ok, assign(data, :t, :i)}
end
branch on: fn data -> data.t end do ... end
```
