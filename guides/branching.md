# Conditional Branching

Execute different steps based on runtime conditions.

## Basic Usage

The `branch` macro evaluates a condition and executes only the matching clause:

```elixir
defmodule MyApp.DocumentProcessor do
  use Durable
  use Durable.Context

  workflow "process_document" do
    step :classify do
      doc_type = AI.classify(input()["content"])
      put_context(:doc_type, doc_type)
    end

    branch on: get_context(:doc_type) do
      :invoice ->
        step :process_invoice do
          extract_invoice_data()
        end

      :contract ->
        step :process_contract do
          extract_contract_data()
        end

      _ ->
        step :manual_review do
          put_context(:needs_review, true)
        end
    end

    # Runs after ANY branch completes
    step :save do
      save_to_database()
    end
  end
end
```

## Pattern Matching

The `on:` expression is evaluated at runtime, and the result is matched against clause patterns.

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
branch on: get_context(:status) do
  :active -> step :handle_active do ... end
  :pending -> step :handle_pending do ... end
  _ -> step :handle_other do ... end
end

# Matching strings
branch on: input()["format"] do
  "pdf" -> step :process_pdf do ... end
  "docx" -> step :process_docx do ... end
  _ -> step :unsupported do ... end
end

# Matching booleans
branch on: get_context(:is_premium) do
  true -> step :premium_flow do ... end
  false -> step :standard_flow do ... end
end

# Matching integers
branch on: get_context(:tier) do
  1 -> step :tier_one do ... end
  2 -> step :tier_two do ... end
  3 -> step :tier_three do ... end
end
```

## Multiple Steps per Branch

Each branch can contain multiple steps that execute sequentially:

```elixir
branch on: get_context(:order_type) do
  :subscription ->
    step :validate_subscription do
      validate_recurring_payment()
    end

    step :setup_billing do
      create_subscription_billing()
    end

    step :schedule_renewals do
      schedule_monthly_charge()
    end

  :one_time ->
    step :process_payment do
      charge_once()
    end
end
```

## Default Clause

The `_` pattern matches any value not matched by other clauses:

```elixir
branch on: get_context(:priority) do
  :critical ->
    step :alert_oncall do
      PagerDuty.alert()
    end

  :high ->
    step :create_urgent_ticket do
      Tickets.create(priority: :high)
    end

  _ ->
    # Matches :medium, :low, or any other value
    step :create_normal_ticket do
      Tickets.create(priority: :normal)
    end
end
```

## Examples

### Order Processing by Type

```elixir
workflow "process_order" do
  step :load_order do
    order = Orders.get(input()["order_id"])
    put_context(:order, order)
    put_context(:order_type, order.type)
  end

  branch on: get_context(:order_type) do
    :digital ->
      step :generate_download_link do
        link = Downloads.create(get_context(:order))
        put_context(:delivery_method, :download)
        put_context(:download_link, link)
      end

    :physical ->
      step :create_shipment do
        shipment = Shipping.create(get_context(:order))
        put_context(:delivery_method, :shipping)
        put_context(:tracking_number, shipment.tracking)
      end

      step :notify_warehouse do
        Warehouse.queue_pick(get_context(:order))
      end

    :service ->
      step :schedule_appointment do
        slot = Calendar.book(get_context(:order))
        put_context(:delivery_method, :appointment)
        put_context(:appointment, slot)
      end
  end

  step :send_confirmation do
    Email.send_order_confirmation(
      get_context(:order),
      get_context(:delivery_method)
    )
  end
end
```

### User Verification Flow

```elixir
workflow "verify_user" do
  step :check_verification_status do
    user = Users.get(input()["user_id"])
    put_context(:user, user)
    put_context(:verified, user.email_verified and user.phone_verified)
    put_context(:verification_method, user.preferred_verification)
  end

  branch on: get_context(:verified) do
    true ->
      step :already_verified do
        put_context(:result, :already_verified)
      end

    false ->
      # Nested branch for verification method
      branch on: get_context(:verification_method) do
        :email ->
          step :send_email_code do
            code = generate_code()
            Email.send_verification(get_context(:user).email, code)
            put_context(:pending_verification, :email)
          end

        :sms ->
          step :send_sms_code do
            code = generate_code()
            SMS.send(get_context(:user).phone, code)
            put_context(:pending_verification, :sms)
          end

        _ ->
          step :require_manual_verification do
            Support.create_verification_ticket(get_context(:user))
            put_context(:pending_verification, :manual)
          end
      end
  end
end
```

### Amount-Based Approval Routing

```elixir
workflow "expense_routing" do
  step :load_expense do
    expense = Expenses.get(input()["expense_id"])
    put_context(:expense, expense)
    put_context(:amount, expense.amount)
  end

  step :determine_tier do
    amount = get_context(:amount)

    tier = cond do
      amount > 10000 -> :executive
      amount > 1000 -> :manager
      amount > 100 -> :team_lead
      true -> :auto
    end

    put_context(:approval_tier, tier)
  end

  branch on: get_context(:approval_tier) do
    :executive ->
      step :cfo_approval do
        request_approval(:cfo, get_context(:expense))
      end

      step :ceo_approval do
        request_approval(:ceo, get_context(:expense))
      end

    :manager ->
      step :manager_approval do
        request_approval(:manager, get_context(:expense))
      end

    :team_lead ->
      step :team_lead_approval do
        request_approval(:team_lead, get_context(:expense))
      end

    :auto ->
      step :auto_approve do
        Expenses.approve(get_context(:expense), approver: :system)
      end
  end
end
```

## Branch vs Decision

Durable provides two ways to control flow:

| Feature | `branch` | `decision` |
|---------|----------|------------|
| Use case | Execute different step groups | Jump to a specific step |
| Syntax | Pattern matching clauses | Return `{:goto, :step}` |
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
branch on: get_context(:type) do
  :a -> step :handle_a do ... end
  :b -> step :handle_b do ... end
end

# Decision for simple skips
decision :check_skip do
  if get_context(:skip_optional) do
    {:goto, :final_step}
  else
    {:continue}
  end
end

step :optional_step do ... end
step :final_step do ... end
```

## Best Practices

### Always Include a Default Clause

```elixir
branch on: get_context(:status) do
  :active -> step :handle_active do ... end
  :pending -> step :handle_pending do ... end
  _ ->
    # Handle unexpected values gracefully
    step :handle_unknown do
      Logger.warn("Unknown status: #{get_context(:status)}")
      put_context(:error, :unknown_status)
    end
end
```

### Keep Branches Focused

```elixir
# Good - each branch does one thing
branch on: get_context(:payment_method) do
  :card -> step :charge_card do ... end
  :bank -> step :initiate_transfer do ... end
  :crypto -> step :process_crypto do ... end
end

# Avoid - too much logic in branches
branch on: get_context(:type) do
  :a ->
    step :step1 do ... end
    step :step2 do ... end
    step :step3 do ... end
    step :step4 do ... end
    step :step5 do ... end
    # Consider extracting to separate workflow
end
```

### Use Descriptive Context Keys

```elixir
# Good
put_context(:document_type, :invoice)
branch on: get_context(:document_type) do ... end

# Avoid
put_context(:t, :i)
branch on: get_context(:t) do ... end
```
