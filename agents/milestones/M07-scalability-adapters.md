# M07: Scalability Adapters

**Status:** Not Started
**Priority:** Low
**Effort:** 2 weeks
**Dependencies:** M05 (soft — message bus pattern informs adapter design)

## Motivation

PostgreSQL is an excellent default queue backend, but high-throughput deployments (10K+ jobs/second) benefit from purpose-built message brokers. Redis provides lower latency for queue operations; RabbitMQ provides advanced routing and back-pressure. The existing `Durable.Queue.Adapter` behaviour makes this pluggable — we just need implementations.

Additionally, multi-node deployments need leader election for the cron scheduler to prevent duplicate scheduling.

## Scope

### In Scope

- `Durable.Queue.Adapters.Redis` — Redis-backed queue adapter
- Leader election for scheduler — `Durable.Scheduler.LeaderElection`
- Optional dependency: `redix`

### Out of Scope

- RabbitMQ adapter (lower priority, can follow same pattern later)
- Kafka/NATS adapters (niche use cases)
- Redis message bus adapter (separate from queue — could be quick follow-up)
- Benchmarking suite (useful but separate effort)
- Automatic adapter selection / multi-backend

## Architecture & Design

### Redis Queue Adapter

Implements `Durable.Queue.Adapter` using Redis sorted sets for priority queuing:

```
lib/durable/queue/adapters/redis.ex
```

#### Redis Data Structures

- **Job queue**: Sorted set per queue name — `durable:queue:{name}` with score = priority + scheduled_at
- **Job data**: Hash per job — `durable:job:{id}` with serialized job fields
- **Processing set**: Set of currently-processing job IDs — `durable:processing:{name}`
- **Dead letter**: List for exhausted retries — `durable:dead:{name}`

#### Key Operations

```
enqueue    → ZADD durable:queue:{name} {score} {job_id}
             HSET durable:job:{id} {fields...}

fetch_jobs → ZPOPMIN durable:queue:{name} {limit}  (atomic pop)
             SADD durable:processing:{name} {job_id}

ack        → SREM durable:processing:{name} {job_id}
             DEL durable:job:{id}

nack       → SREM durable:processing:{name} {job_id}
             ZADD durable:queue:{name} {new_score} {job_id}

reschedule → ZADD durable:queue:{name} {future_score} {job_id}
```

#### Connection Management

```elixir
defmodule Durable.Queue.Adapters.Redis do
  @behaviour Durable.Queue.Adapter

  # Uses Redix for connection
  # Connection pool via Durable.Supervisor
  # Configurable: host, port, database, pool_size, password, ssl
end
```

Configuration:
```elixir
{Durable,
  repo: MyApp.Repo,
  queue_adapter: Durable.Queue.Adapters.Redis,
  queue_adapter_opts: [
    host: "localhost",
    port: 6379,
    pool_size: 5,
    database: 0
  ],
  queues: %{default: [concurrency: 50]}
}
```

#### Stale Job Recovery

A periodic check (like the existing Postgres stale job recovery):
- Scan `durable:processing:{name}` for jobs older than `stale_lock_timeout`
- Move back to queue with incremented attempt count
- Use Redis `WATCH`/`MULTI` for atomicity, or Lua script

### Leader Election

For cron scheduler — ensures only one node runs the scheduler tick:

```
lib/durable/scheduler/leader_election.ex
```

#### PostgreSQL-based (default)

Use advisory locks — already supported by Ecto:

```elixir
defmodule Durable.Scheduler.LeaderElection do
  @behaviour Durable.Scheduler.LeaderElection.Strategy

  # Default: PostgreSQL advisory lock
  # pg_try_advisory_lock(lock_key) → true/false
  # Lock auto-releases on disconnect
  # No additional dependencies
end
```

#### Redis-based (when using Redis adapter)

```elixir
defmodule Durable.Scheduler.LeaderElection.Redis do
  @behaviour Durable.Scheduler.LeaderElection.Strategy

  # SET lock_key node_id NX EX ttl
  # Periodic renewal
  # Automatic expiry on node death
end
```

### Configuration Integration

Update `Durable.Config` NimbleOptions schema:

```elixir
[
  queue_adapter: [
    type: :atom,
    default: Durable.Queue.Adapters.Postgres,
    doc: "Queue adapter module"
  ],
  queue_adapter_opts: [
    type: :keyword_list,
    default: [],
    doc: "Options passed to queue adapter start_link"
  ],
  leader_election: [
    type: :atom,
    default: Durable.Scheduler.LeaderElection,
    doc: "Leader election strategy for scheduler"
  ]
]
```

## Implementation Plan

1. **Redis adapter core** — `lib/durable/queue/adapters/redis.ex`
   - Implement `Durable.Queue.Adapter` callbacks
   - Enqueue, fetch (ZPOPMIN), ack, nack, reschedule
   - Connection setup via Redix

2. **Redis stale job recovery** — extend redis adapter
   - Periodic scan of processing set
   - Lua script for atomic move-back

3. **Configuration** — update `lib/durable/config.ex`
   - Add `queue_adapter`, `queue_adapter_opts` options
   - Update supervisor to start adapter-specific processes

4. **Supervisor integration** — update `lib/durable/supervisor.ex`
   - Conditionally start Redix pool for Redis adapter
   - Pass adapter config to Queue.Manager

5. **Leader election behaviour** — `lib/durable/scheduler/leader_election.ex`
   - Define strategy behaviour
   - PostgreSQL advisory lock implementation (default)

6. **Redis leader election** — `lib/durable/scheduler/leader_election/redis.ex`
   - SET NX EX pattern
   - Renewal GenServer

7. **Scheduler integration** — update `lib/durable/scheduler.ex`
   - Use leader election before running tick
   - Configurable strategy

## Testing Strategy

- `test/durable/queue/adapters/redis_test.exs` — integration tests (requires Redis):
  - Enqueue and fetch ordering (priority)
  - Ack removes job completely
  - Nack re-queues with updated priority
  - Concurrent fetch doesn't double-deliver
  - Stale job recovery moves stuck jobs
  - Tag with `@tag :redis` to skip when Redis unavailable
- `test/durable/scheduler/leader_election_test.exs`:
  - Advisory lock acquired by first caller
  - Second caller fails to acquire
  - Lock released on disconnect
- `test/durable/queue/adapters/redis_integration_test.exs`:
  - Full workflow execution through Redis queue
  - Multiple workers, concurrent processing
- Mirror the existing `test/durable/queue/adapters/postgres_test.exs` test structure

## Acceptance Criteria

- [ ] Redis adapter implements all `Durable.Queue.Adapter` callbacks
- [ ] Jobs enqueued to Redis are fetchable with correct priority ordering
- [ ] Concurrent workers don't process the same job (atomic ZPOPMIN)
- [ ] Stale jobs in Redis are recovered after timeout
- [ ] Leader election prevents duplicate cron scheduling across nodes
- [ ] PostgreSQL advisory lock is the default leader election strategy
- [ ] Configuration accepts `queue_adapter: Durable.Queue.Adapters.Redis`
- [ ] Redix is an optional dependency (not required for Postgres users)
- [ ] All existing Postgres-based tests still pass
- [ ] `mix credo --strict` passes

## Open Questions

- Should we use a Redis connection pool library (like `nimble_pool`) or Redix's built-in pooling?
- Lua scripts vs MULTI/EXEC for atomic operations — which is simpler to maintain?
- Should the Redis adapter store job data in the PostgreSQL database (hybrid) or fully in Redis?
- Do we need a migration path guide for switching from Postgres to Redis adapter?

## References

- `lib/durable/queue/adapter.ex` — behaviour to implement
- `lib/durable/queue/adapters/postgres.ex` — reference implementation
- `test/durable/queue/adapters/postgres_test.exs` — test structure to mirror
- `lib/durable/queue/stale_job_recovery.ex` — stale job pattern for Postgres
- `lib/durable/scheduler.ex` — scheduler that needs leader election
- `lib/durable/config.ex` — NimbleOptions configuration
- Redix documentation — Redis client for Elixir
