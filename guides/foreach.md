# ForEach Loops

Process collections of items with support for sequential or concurrent execution.

## Basic Usage

```elixir
defmodule MyApp.OrderProcessor do
  use Durable
  use Durable.Helpers

  workflow "process_orders" do
    step :fetch_orders, fn _input ->
      orders = Orders.fetch_pending()
      {:ok, %{orders: orders, processed: []}}
    end

    # Process each order sequentially
    foreach :process_each, items: fn data -> data.orders end do
      # Foreach steps receive (data, item, index)
      step :process, fn data, order, _idx ->
        result = Orders.process(order)
        {:ok, append(data, :processed, result)}
      end
    end

    step :summary, fn data ->
      count = length(data.processed)
      Logger.info("Processed #{count} orders")
      {:ok, data}
    end
  end
end
```

## Accessing Item and Index

Inside a foreach block, step functions receive three arguments:

| Argument | Description |
|----------|-------------|
| `data` | The accumulated workflow data |
| `item` | The current item being processed |
| `index` | The 0-based index of the current item |

```elixir
foreach :send_emails, items: fn data -> data.recipients end do
  step :send, fn data, recipient, index ->
    total = length(data.recipients)
    Email.send(recipient, subject: "Email #{index + 1} of #{total}")
    {:ok, increment(data, :sent_count)}
  end
end
```

## Options

### Item Source (`:items`) - Required

A function that extracts the collection from the data:

```elixir
# From data key
foreach :process, items: fn data -> data.my_items end do
  step :work, fn data, item, _idx -> {:ok, data} end
end

# Computed items
foreach :process, items: fn data -> Enum.filter(data.items, & &1.active) end do
  step :work, fn data, item, _idx -> {:ok, data} end
end
```

### Concurrency (`:concurrency`)

Process multiple items simultaneously:

```elixir
# Sequential (default)
foreach :process, items: fn data -> data.items end, concurrency: 1 do
  # Items processed one at a time
  step :work, fn data, item, _idx -> {:ok, data} end
end

# Process 5 items at once
foreach :process, items: fn data -> data.items end, concurrency: 5 do
  # Up to 5 items processed concurrently
  step :work, fn data, item, _idx -> {:ok, data} end
end
```

### Error Handling (`:on_error`)

| Strategy | Description |
|----------|-------------|
| `:fail_fast` | Stop on first error (default) |
| `:continue` | Continue processing, collect errors |

```elixir
# Stop on first failure
foreach :process, items: fn data -> data.items end, on_error: :fail_fast do
  step :work, fn data, item, _idx ->
    # If this fails, remaining items are skipped
    {:ok, data}
  end
end

# Continue despite errors
foreach :process, items: fn data -> data.items end, on_error: :continue do
  step :work, fn data, item, _idx ->
    # Errors are collected, processing continues
    {:ok, data}
  end
end
```

## Examples

### Batch Processing with Concurrency

```elixir
workflow "send_notifications" do
  step :fetch_users, fn _input ->
    users = Users.all_active()
    {:ok, %{users: users, sent_count: 0}}
  end

  # Send to 10 users at a time
  foreach :notify_each, items: fn data -> data.users end, concurrency: 10 do
    step :send, [retry: [max_attempts: 3]], fn data, user, _idx ->
      Notifications.send(user.id, "Weekly update")
      {:ok, increment(data, :sent_count)}
    end
  end

  step :report, fn data ->
    Logger.info("Sent #{data.sent_count} notifications")
    {:ok, data}
  end
end
```

### Processing with Error Tolerance

```elixir
workflow "import_records" do
  step :load_data, fn input ->
    records = CSVParser.parse(input["file_path"])
    {:ok, %{records: records, errors: [], success_count: 0}}
  end

  foreach :import_each,
    items: fn data -> data.records end,
    on_error: :continue do

    step :import, fn data, record, index ->
      case Database.insert(record) do
        {:ok, _} ->
          {:ok, increment(data, :success_count)}
        {:error, reason} ->
          {:ok, append(data, :errors, %{index: index, reason: reason})}
      end
    end
  end

  step :summary, fn data ->
    Logger.info("Imported #{data.success_count} records, #{length(data.errors)} errors")

    data = if data.errors != [] do
      assign(data, :has_errors, true)
    else
      data
    end

    {:ok, data}
  end
end
```

### Multi-Step Processing per Item

```elixir
foreach :process_documents, items: fn data -> data.documents end do
  step :validate, fn data, doc, _idx ->
    if valid?(doc) do
      {:ok, assign(data, :current_valid, true)}
    else
      raise "Invalid document: #{doc.id}"
    end
  end

  step :transform, fn data, doc, _idx ->
    transformed = transform(doc)
    {:ok, assign(data, :current_result, transformed)}
  end

  step :save, fn data, _doc, _idx ->
    result = data.current_result
    Database.save(result)
    {:ok, append(data, :saved_ids, result.id)}
  end
end
```

### Tracking Progress

```elixir
foreach :process_large_batch, items: fn data -> data.items end do
  step :process, fn data, item, index ->
    total = length(data.items)

    if rem(index, 100) == 0 do
      Logger.info("Progress: #{index}/#{total}")
    end

    process(item)
    {:ok, data}
  end
end
```

## Best Practices

### Choose Appropriate Concurrency

```elixir
# External API with rate limits - low concurrency
foreach :call_api, items: fn data -> data.requests end, concurrency: 2 do
  step :call, fn data, req, _idx -> {:ok, data} end
end

# CPU-bound local work - match CPU cores
foreach :process, items: fn data -> data.data end, concurrency: System.schedulers_online() do
  step :work, fn data, item, _idx -> {:ok, data} end
end

# Independent I/O operations - higher concurrency
foreach :fetch, items: fn data -> data.urls end, concurrency: 20 do
  step :download, fn data, url, _idx -> {:ok, data} end
end
```

### Use `:continue` for Non-Critical Items

```elixir
# Sending emails - some failures are acceptable
foreach :send_emails, items: fn data -> data.recipients end, on_error: :continue do
  step :send, fn data, recipient, _idx ->
    case Mailer.send(recipient) do
      :ok -> {:ok, increment(data, :sent)}
      {:error, reason} -> {:ok, append(data, :failed, {recipient, reason})}
    end
  end
end
```

### Combine with Parallel for Complex Pipelines

```elixir
foreach :process_orders, items: fn data -> data.orders end do
  # Each order has multiple independent tasks
  parallel do
    step :update_inventory, fn data, order, _idx ->
      Inventory.reserve(order.items)
      {:ok, data}
    end

    step :notify_warehouse, fn data, order, _idx ->
      Warehouse.notify(order)
      {:ok, data}
    end

    step :send_confirmation, fn data, order, _idx ->
      Email.send_order_confirmation(order)
      {:ok, data}
    end
  end
end
```
