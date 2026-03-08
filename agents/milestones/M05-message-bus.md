# M05: Message Bus

**Status:** Not Started
**Priority:** Medium
**Effort:** 1.5 weeks
**Dependencies:** None

## Motivation

Durable currently has no mechanism for real-time notifications when workflow/step state changes. External systems (UIs, monitoring, other services) must poll the database. A message bus enables push-based updates for the Phoenix Dashboard (M06), external integrations, and custom event-driven architectures. PostgreSQL `pg_notify` provides a zero-dependency default; Phoenix.PubSub enables in-app subscribers.

## Scope

### In Scope

- `Durable.MessageBus` behaviour (publish/subscribe contract)
- `Durable.MessageBus.PgNotify` adapter — PostgreSQL LISTEN/NOTIFY
- `Durable.MessageBus.PhoenixPubSub` adapter — optional dependency
- Executor integration — publish events on state transitions
- Event types: workflow_started, workflow_completed, workflow_failed, step_started, step_completed, step_failed, step_waiting, workflow_cancelled
- Configuration via supervision tree options

### Out of Scope

- Redis Pub/Sub adapter (M07)
- RabbitMQ adapter (M07)
- Custom user-defined events (users can add their own publisher in steps)
- Event persistence / event sourcing
- Guaranteed delivery (best-effort pub/sub)

## Architecture & Design

### Module Layout

```
lib/durable/message_bus.ex                    # Behaviour definition
lib/durable/message_bus/pg_notify.ex          # PostgreSQL LISTEN/NOTIFY adapter
lib/durable/message_bus/phoenix_pubsub.ex     # Phoenix.PubSub adapter
lib/durable/message_bus/log.ex                # Logger-only adapter (default/fallback)
```

### Behaviour

```elixir
defmodule Durable.MessageBus do
  @type topic :: String.t()
  @type message :: map()

  @callback start_link(opts :: keyword()) :: GenServer.on_start()
  @callback publish(topic(), message()) :: :ok | {:error, term()}
  @callback subscribe(topic()) :: :ok | {:error, term()}
  @callback unsubscribe(topic()) :: :ok | {:error, term()}
end
```

### Topic Naming

```
durable:workflow:<workflow_id>          # All events for a workflow
durable:workflow:<workflow_id>:steps    # Step events only
durable:workflows                      # All workflow lifecycle events
```

### Event Format

```elixir
%{
  event: :step_completed,
  workflow_id: "uuid",
  workflow_module: "MyApp.OrderWorkflow",
  workflow_name: "process_order",
  step: :charge_payment,
  timestamp: ~U[2026-03-09 12:00:00Z],
  data: %{
    status: :completed,
    duration_ms: 234,
    attempt: 1
  }
}
```

### PgNotify Adapter

Uses PostgreSQL `LISTEN`/`NOTIFY` via a dedicated Postgrex connection (already a dependency via Ecto):

- **Publisher**: `NOTIFY channel, payload` via `Ecto.Adapters.SQL.query/3`
- **Listener**: GenServer wrapping `Postgrex.Notifications.listen/3`
- Subscribers register with the GenServer process; it forwards matching notifications
- Payload limited to 8KB — serialize as JSON, truncate large data
- Channel mapping: `durable_events` (single channel, filter by topic in payload)

```elixir
defmodule Durable.MessageBus.PgNotify do
  use GenServer
  @behaviour Durable.MessageBus

  # Starts a Postgrex.Notifications connection
  # Listens on "durable_events" channel
  # Maintains subscriber registry (ETS or map)
  # On notification: decode JSON, match topic, forward to subscribers
end
```

### Phoenix.PubSub Adapter

Thin wrapper around `Phoenix.PubSub.broadcast/3` and `Phoenix.PubSub.subscribe/2`:

```elixir
defmodule Durable.MessageBus.PhoenixPubSub do
  @behaviour Durable.MessageBus

  # Delegates to Phoenix.PubSub
  # Requires :pubsub_name in config
  # No GenServer needed — PubSub already running
end
```

Optional dependency in `mix.exs`:
```elixir
{:phoenix_pubsub, "~> 2.0", optional: true}
```

### Log Adapter (Default)

For when no message bus is configured — just logs events at debug level:

```elixir
defmodule Durable.MessageBus.Log do
  @behaviour Durable.MessageBus
  # publish/2 -> Logger.debug(...)
  # subscribe/1, unsubscribe/1 -> :ok (no-op)
end
```

### Executor Integration

Add publish calls to `Durable.Executor` and `Durable.Executor.StepRunner` at state transition points:

```elixir
# In executor, after step completes:
Durable.MessageBus.publish(
  "durable:workflow:#{workflow_id}",
  %{event: :step_completed, step: step_name, ...}
)
```

Use `Durable.Config` to resolve the configured message bus module.

### Configuration

```elixir
{Durable,
  repo: MyApp.Repo,
  message_bus: Durable.MessageBus.PgNotify,
  message_bus_opts: [],
  # or
  message_bus: Durable.MessageBus.PhoenixPubSub,
  message_bus_opts: [pubsub_name: MyApp.PubSub]
}
```

Default: `Durable.MessageBus.Log` (no external dependencies needed).

## Implementation Plan

1. **Behaviour definition** — `lib/durable/message_bus.ex`
   - Define callbacks
   - Add convenience functions that delegate to configured adapter
   - `Durable.MessageBus.publish/2`, `subscribe/1`, `unsubscribe/1`

2. **Log adapter** — `lib/durable/message_bus/log.ex`
   - Minimal implementation for default/testing use
   - No process needed

3. **PgNotify adapter** — `lib/durable/message_bus/pg_notify.ex`
   - GenServer with Postgrex.Notifications connection
   - Subscriber registry
   - JSON encode/decode for payloads
   - Handle connection recovery on disconnect

4. **Phoenix.PubSub adapter** — `lib/durable/message_bus/phoenix_pubsub.ex`
   - Thin delegation layer
   - Guard: check Phoenix.PubSub is available at compile time

5. **Configuration** — update `lib/durable/config.ex`
   - Add `:message_bus` and `:message_bus_opts` to NimbleOptions schema
   - Default to `Durable.MessageBus.Log`

6. **Supervisor integration** — update `lib/durable/supervisor.ex`
   - Start message bus process (for PgNotify) as child
   - Skip for stateless adapters (Log, PhoenixPubSub)

7. **Executor integration** — update `lib/durable/executor.ex` and `lib/durable/executor/step_runner.ex`
   - Publish events at state transitions
   - Keep publish calls non-blocking (don't fail workflow on bus error)

## Testing Strategy

- `test/durable/message_bus/pg_notify_test.exs` — integration test with real Postgres:
  - Subscribe, publish, verify message received
  - Multiple subscribers on same topic
  - Unsubscribe stops delivery
  - Connection recovery
- `test/durable/message_bus/phoenix_pubsub_test.exs` — unit test with test PubSub:
  - Start a Phoenix.PubSub in test setup
  - Subscribe, publish, verify
- `test/durable/message_bus/log_test.exs` — verify logging behavior
- `test/durable/message_bus/integration_test.exs` — run a workflow with message bus enabled, verify events published for each state transition
- Use `Durable.DataCase` for DB tests

## Acceptance Criteria

- [ ] `Durable.MessageBus` behaviour is defined with `publish/2`, `subscribe/1`, `unsubscribe/1`
- [ ] PgNotify adapter sends/receives messages via PostgreSQL NOTIFY/LISTEN
- [ ] Phoenix.PubSub adapter delegates correctly (tested with real PubSub)
- [ ] Log adapter logs events at debug level
- [ ] Running a workflow publishes events: started, step_started, step_completed, completed
- [ ] Subscribers receive events in near-real-time
- [ ] Message bus errors don't crash workflows (non-blocking publish)
- [ ] Configuration via supervision tree `:message_bus` option
- [ ] Message bus process supervised and restarts on crash
- [ ] `mix credo --strict` passes

## Open Questions

- Should we support wildcard subscriptions (e.g., `durable:workflow:*`)?
- Should PgNotify use one channel per workflow or a single channel with routing?
- Should events include the full context or just keys that changed?
- Buffer/batch publishes within a single step execution, or publish immediately?

## References

- `agents/arch.md` — "Message Bus" section for behaviour design
- `lib/durable/config.ex` — NimbleOptions configuration pattern
- `lib/durable/supervisor.ex` — supervision tree for adding message bus child
- `lib/durable/executor.ex` — state transition points for event publishing
- Postgrex documentation — `Postgrex.Notifications` for pg_notify
- Phoenix.PubSub documentation — adapter delegation pattern
