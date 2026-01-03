# ForEach Loops

Process collections of items with support for sequential or concurrent execution.

## Basic Usage

```elixir
defmodule MyApp.OrderProcessor do
  use Durable
  use Durable.Context

  workflow "process_orders" do
    step :fetch_orders do
      orders = Orders.fetch_pending()
      put_context(:orders, orders)
    end

    # Process each order sequentially
    foreach :process_each, items: :orders do
      step :process do
        order = current_item()
        result = Orders.process(order)
        append_context(:processed, result)
      end
    end

    step :summary do
      count = length(get_context(:processed, []))
      Logger.info("Processed #{count} orders")
    end
  end
end
```

## Accessing Current Item

Inside a foreach block, use these functions from `Durable.Context`:

| Function | Description |
|----------|-------------|
| `current_item()` | The current item being processed |
| `current_index()` | The 0-based index of the current item |

```elixir
foreach :send_emails, items: :recipients do
  step :send do
    recipient = current_item()
    index = current_index()

    Email.send(recipient, subject: "Email #{index + 1} of #{length(get_context(:recipients))}")
  end
end
```

## Options

### Item Source (`:items`) - Required

Specifies where to get the collection:

```elixir
# From context key
foreach :process, items: :my_items do
  # ...
end

# From MFA tuple (called at runtime)
foreach :process, items: {Orders, :fetch_pending, []} do
  # ...
end
```

### Concurrency (`:concurrency`)

Process multiple items simultaneously:

```elixir
# Sequential (default)
foreach :process, items: :items, concurrency: 1 do
  # Items processed one at a time
end

# Process 5 items at once
foreach :process, items: :items, concurrency: 5 do
  # Up to 5 items processed concurrently
end
```

### Error Handling (`:on_error`)

| Strategy | Description |
|----------|-------------|
| `:fail_fast` | Stop on first error (default) |
| `:continue` | Continue processing, collect errors |

```elixir
# Stop on first failure
foreach :process, items: :items, on_error: :fail_fast do
  step :work do
    # If this fails, remaining items are skipped
  end
end

# Continue despite errors
foreach :process, items: :items, on_error: :continue do
  step :work do
    # Errors are collected, processing continues
  end
end
```

### Collecting Results (`:collect_as`)

Store each iteration's result in a list:

```elixir
foreach :transform, items: :raw_data, collect_as: :transformed do
  step :transform do
    item = current_item()
    # Return value is collected
    String.upcase(item.name)
  end
end

step :use_results do
  results = get_context(:transformed)  # List of transformed values
end
```

## Examples

### Batch Processing with Concurrency

```elixir
workflow "send_notifications" do
  step :fetch_users do
    users = Users.all_active()
    put_context(:users, users)
  end

  # Send to 10 users at a time
  foreach :notify_each, items: :users, concurrency: 10 do
    step :send, retry: [max_attempts: 3] do
      user = current_item()
      Notifications.send(user.id, "Weekly update")
      increment_context(:sent_count)
    end
  end

  step :report do
    Logger.info("Sent #{get_context(:sent_count, 0)} notifications")
  end
end
```

### Processing with Error Tolerance

```elixir
workflow "import_records" do
  step :load_data do
    records = CSVParser.parse(input()["file_path"])
    put_context(:records, records)
    put_context(:errors, [])
  end

  foreach :import_each,
    items: :records,
    on_error: :continue do

    step :import do
      record = current_item()
      index = current_index()

      case Database.insert(record) do
        {:ok, _} ->
          increment_context(:success_count)
        {:error, reason} ->
          append_context(:errors, %{index: index, reason: reason})
      end
    end
  end

  step :summary do
    success = get_context(:success_count, 0)
    errors = get_context(:errors, [])

    Logger.info("Imported #{success} records, #{length(errors)} errors")

    if errors != [] do
      put_context(:has_errors, true)
    end
  end
end
```

### Dynamic Item Fetching with MFA

```elixir
defmodule MyApp.PaginatedProcessor do
  use Durable
  use Durable.Context

  workflow "process_all_pages" do
    step :init do
      put_context(:page, 1)
      put_context(:processed, [])
    end

    # Fetch items dynamically using MFA
    foreach :process_batch,
      items: {__MODULE__, :fetch_page, []},
      concurrency: 5 do

      step :process do
        item = current_item()
        result = process_item(item)
        append_context(:processed, result)
      end
    end
  end

  def fetch_page do
    # Called at runtime to get items
    page = Durable.Context.get_context(:page)
    API.fetch_items(page: page, limit: 100)
  end
end
```

### Multi-Step Processing per Item

```elixir
foreach :process_documents, items: :documents do
  step :validate do
    doc = current_item()

    if valid?(doc) do
      put_context(:current_valid, true)
    else
      raise "Invalid document: #{doc.id}"
    end
  end

  step :transform do
    doc = current_item()
    transformed = transform(doc)
    put_context(:current_result, transformed)
  end

  step :save do
    result = get_context(:current_result)
    Database.save(result)
    append_context(:saved_ids, result.id)
  end
end
```

## Best Practices

### Choose Appropriate Concurrency

```elixir
# External API with rate limits - low concurrency
foreach :call_api, items: :requests, concurrency: 2 do
  # ...
end

# CPU-bound local work - match CPU cores
foreach :process, items: :data, concurrency: System.schedulers_online() do
  # ...
end

# Independent I/O operations - higher concurrency
foreach :fetch, items: :urls, concurrency: 20 do
  # ...
end
```

### Track Progress for Long Lists

```elixir
foreach :process_large_batch, items: :items do
  step :process do
    index = current_index()
    total = length(get_context(:items))

    if rem(index, 100) == 0 do
      Logger.info("Progress: #{index}/#{total}")
    end

    process(current_item())
  end
end
```

### Use `:continue` for Non-Critical Items

```elixir
# Sending emails - some failures are acceptable
foreach :send_emails, items: :recipients, on_error: :continue do
  step :send do
    recipient = current_item()

    case Mailer.send(recipient) do
      :ok -> increment_context(:sent)
      {:error, reason} -> append_context(:failed, {recipient, reason})
    end
  end
end
```

### Combine with Parallel for Complex Pipelines

```elixir
foreach :process_orders, items: :orders do
  # Each order has multiple independent tasks
  parallel do
    step :update_inventory do
      Inventory.reserve(current_item().items)
    end

    step :notify_warehouse do
      Warehouse.notify(current_item())
    end

    step :send_confirmation do
      Email.send_order_confirmation(current_item())
    end
  end
end
```
