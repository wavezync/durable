# Plan

What's next for Durable, in order. For how it works today, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Next

### 1. Release `durable`, then the dashboard

Release `durable` first. It has a new migration, so apps need to run it. The dashboard's next release has to require that `durable` release: its telemetry catalog must match the engine's events exactly, and its pages read the new run fields.

### 2. Workflow versioning

Pin each run to the version of the workflow it started on. Today a run resumes on whatever is deployed, and fails if its current step is gone.

Still to decide:

- **API:** several `workflow "order", version: N` blocks in one module, or one module per version?
- **Release:** it needs a new column, so a minor release with an upgrade note, or wait for 2.0?
- **Missing version:** fail the run, or fall back to the latest version if the run's current step exists there?

### 3. Global concurrency and broker adapters

Queue limits are per node today, by decision. Cluster-wide limits come later through an adapter, along with adapters for Kafka, RabbitMQ, NATS and Redis to raise throughput.

Proposed, not agreed: PostgreSQL stays the store, brokers carry dispatch only, and limits are a separate lease (acquire, extend, release). Whatever shape it takes, cluster-wide limits shouldn't go into the claim SQL, or every adapter has to reimplement them.

`Durable.Queue.Adapter` is poll-shaped today, and the executor's state writes aren't behind it. A plain 3-step run measured 19 writes plus an ack, of which only the claim and the ack are queue traffic, so a broker alone won't remove the load on Postgres.

## Later

- **`each`:** an iteration primitive, with its own context per iteration so concurrent writes can't race
- **Decisions inside `parallel` blocks**
- **Real `prefix:` support:** several isolated instances in one database. Today anything but `"durable"` is refused at boot. Doing it means removing `@schema_prefix`, which breaks apps that query Durable's schemas with their own repo
- **`Durable.Testing.drain/2` firing wait timeouts:** the timeout worker only runs with queues on

## Known limits

- Queue concurrency is per node
- `goto` only jumps forward
- A step that waits runs again from the top when it resumes, and each step can sleep only once
- A run gets one event per name
- A run resumes on the deployed workflow, and fails if its current step no longer exists
- A step with a `timeout:`, or in a workflow with one, runs in its own process, so `self()` isn't the worker
- Compensation retries wait in-process, holding the worker, capped at 30 s
- Wakes need a PubSub. Without one, runs are claimed on the next poll
- PostgreSQL 13 or newer. PgBouncer older than 1.24 needs `prepare: :unnamed`
