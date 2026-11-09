# Running in production

Durable works with its defaults, but a few of them suit development more than
production, and Postgres needs some help with tables that change this often.
This guide covers what to set before you go live, what to keep an eye on, and
how to deploy without disturbing running work.

The numbers below were measured on a laptop with Postgres 18 in Docker, using a
3-step workflow whose steps do nothing, so they show Durable's own overhead. Use
them as ratios, not as a forecast.

## Before you go live

- **Turn on pruning.** It's off by default, so finished runs stay forever.
- **Stop storing every log line.** By default each step's logs go in the
  database at every level.
- **Give Durable a PubSub**, so new work starts at once and you can poll less.
- **Make steps safe to run twice.** Delivery is at least once.
- **Drain on shutdown**, or each deploy leaves runs stuck for minutes.
- **Tune autovacuum** for the two busiest tables.
- **Report metrics**, and alert on the handful that matter.

This covers the first three:

```elixir
# In the supervision tree
{Durable,
 repo: MyApp.Repo,
 pubsub: MyApp.PubSub,
 queues: %{
   default: [concurrency: 20, poll_interval: 5_000]
 },
 prune: [
   completed: :timer.hours(24 * 7),
   cancelled: :timer.hours(24 * 7),
   failed: :timer.hours(24 * 30)
 ]}

# config/prod.exs
config :durable, log_capture: [levels: [:warning, :error]]
```

## What a run costs

Each 3-step run took 23 queries, one insert and nine updates on its run row, and
three inserts and six updates on its step rows. That's about 3 KB on disk, and
15 dead row versions for Postgres to clean up. More steps and retries add to all
of these.

What you store matters far more than the bookkeeping:

| Run | Stored per run |
|---|---|
| 2 steps, 10 info lines each, default log capture | 7.9 KB of step data |
| The same, with `levels: [:warning, :error]` | 1.6 KB of step data |
| 3 steps carrying a 100 KB payload | 637 KB in all |

Each step stores its input and output, and the run's context is rewritten as it
goes, so a payload is written several times over. Pass an id or an object store
key through your workflow, not the file itself.

## Retention

With `prune:` set, each node runs the pruner once an hour, in batches of 5,000.
Batches skip rows another node has locked, so nodes don't get in each other's
way. Deleting 100,000 runs and their 300,000 step rows took 4 seconds.

- `failed` covers failed, compensated and compensation-failed runs. Statuses you
  leave out are kept forever.
- Steps, inputs and events go with their run. Child runs are pruned on their own
  age.
- Pending, running and waiting runs are never pruned.
- **A pruned run's workflow key is free again.** Keep runs for longer than you
  rely on a key to catch duplicates.

To prune now, call `Durable.prune()`, or press Prune now on the dashboard's
Settings page. For a one-off with different rules, `mix durable.cleanup
--older-than 30d --dry-run` shows what it would delete.

Pruning makes room for new rows rather than shrinking the files. In the test
above, the tables were the same size after the delete, and the indexes kept all
their space even after `VACUUM`. If you cut retention sharply, see
[reindexing](#reindex-after-a-big-cleanup).

Finished runs don't slow down claiming: a claim took 0.41 ms with no history and
0.43 ms with 500,000 finished runs. Retention is about disk, backups and how long
vacuum takes.

## Postgres upkeep

### Tune autovacuum

By default Postgres vacuums a table once about 20% of it is dead. On a large
`workflow_executions` table, that's a lot of dead rows before anything happens.
Lower it for the two tables that change most:

```elixir
defmodule MyApp.Repo.Migrations.TuneDurableVacuum do
  use Ecto.Migration

  def up do
    for table <- ~w(workflow_executions step_executions) do
      execute("""
      ALTER TABLE durable.#{table} SET (
        autovacuum_vacuum_scale_factor = 0.02,
        autovacuum_analyze_scale_factor = 0.02
      )
      """)
    end
  end

  def down do
    for table <- ~w(workflow_executions step_executions) do
      execute("""
      ALTER TABLE durable.#{table} RESET (
        autovacuum_vacuum_scale_factor,
        autovacuum_analyze_scale_factor
      )
      """)
    end
  end
end
```

### Watch for long transactions

An open transaction stops vacuum from removing dead rows anywhere in the
database, and that includes a report or a forgotten console session. With one
snapshot held across 10,000 runs, `VACUUM` could not remove any of the 90,000
dead run rows, and an idle claim read 240 pages instead of 4. That was still
under a millisecond, but it keeps growing until the transaction ends.

```sql
SELECT pid, now() - xact_start AS open_for, state, left(query, 80) AS query
FROM pg_stat_activity
WHERE xact_start < now() - interval '5 minutes'
ORDER BY xact_start;
```

Setting `idle_in_transaction_session_timeout` on your database stops a forgotten
session from doing this.

Your own transactions matter here too, so don't hold one open across a slow call
inside a step.

### Check how the tables are doing

```sql
-- Dead rows, and when each table was last vacuumed
SELECT relname, n_live_tup, n_dead_tup, last_autovacuum
FROM pg_stat_user_tables
WHERE schemaname = 'durable'
ORDER BY n_dead_tup DESC;

-- Size of each table and its indexes
SELECT c.relname,
       pg_size_pretty(pg_relation_size(c.oid)) AS heap,
       pg_size_pretty(pg_indexes_size(c.oid)) AS indexes,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'durable' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;
```

### Reindex after a big cleanup

Indexes can stay large after their rows are gone. If the second query shows
indexes far bigger than the table, rebuild the large ones. This doesn't block
reads or writes:

```sql
REINDEX INDEX CONCURRENTLY
  durable.workflow_executions_queue_status_priority_scheduled_at_index;
```

Avoid `VACUUM FULL` on a live system. It locks the table, so claims stop until it
finishes.

### If a queue builds a deep backlog

Claiming sorts every ready run in the queue, so its cost grows with the backlog:

| Ready runs in the queue | One claim | With the index below |
|---|---|---|
| 100 | 0.4 ms | |
| 10,000 | 11 ms | |
| 100,000 | 83 ms | 0.3 ms |
| 500,000 | 400 ms | 0.3 ms |

Every poll with a free slot pays this cost. If a queue regularly holds tens of
thousands of ready runs, add this index:

```elixir
defmodule MyApp.Repo.Migrations.AddDurableClaimIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists(
      index(
        :workflow_executions,
        ["queue", "priority DESC", "scheduled_at ASC NULLS FIRST", "inserted_at ASC"],
        prefix: "durable",
        name: :workflow_executions_claim_index,
        where: "status = 'pending'",
        concurrently: true
      )
    )
  end
end
```

## Connections

A worker holds a connection only while it runs a query, not for the length of a
step, so the pool doesn't need to match your concurrency. With a concurrency of
50 and steps that do nothing, which is the hardest case for the pool:

| `pool_size` | Runs per second | Wait for a connection (p95) |
|---|---|---|
| 5 | 114 | 20 ms |
| 10 | 215 | 7 ms |
| 20 | 292 | 6 ms |
| 50 | 400 | 2 ms |

No size caused errors, and a small pool only cost throughput. A reasonable start
is about a third of your total concurrency, plus what the rest of your app needs,
since Durable shares your repo's pool with your own queries. Then watch
`queue_time` in your repo's telemetry.

Durable uses no session features, so it runs on direct connections and behind
PgBouncer in transaction mode. A PgBouncer older than 1.24 needs `prepare:
:unnamed` on your repo.

## Queues

- **`concurrency` is per node.** `concurrency: 20` on three nodes runs up to 60 at
  once.
- **A long step holds a slot, a wait doesn't.** Runs on a sleep, event, input,
  retry backoff or snooze free their worker.
- **Keep slow work away from fast work.** Give slow steps their own queue with
  `queue:` on the step, so an hour of OCR can't hold up a payment.
- **Poll less once you have a PubSub.** Every queue on every node runs a claim
  each `poll_interval`, 1 second by default, even when idle. A PubSub wakes pollers
  when a run starts or resumes, so a longer interval only delays work that comes
  due later: sleeps, retries, snoozes and delayed starts. Between nodes, this needs
  your cluster connected.
- **Workers-only and web-only nodes work.** `queue_enabled: false` lets a node
  start runs without working them.
- **Pause a queue in an incident** with `Durable.pause_queue(:name)`. It applies
  on every node until you call `Durable.resume_queue(:name)`.

## Deploys

### Drain on shutdown

Workers don't finish their step when a node stops. The run stays `running` with
its lock until the lock goes stale, 300 seconds by default, and a sweep that runs
every 60 seconds puts it back on the queue. That's up to about six minutes for
each run caught by a deploy, and the step runs again from the start.

To avoid that, stop claiming and wait for running steps before the app shuts
down:

```elixir
# lib/my_app/application.ex
@impl true
def prep_stop(state) do
  tasks =
    for queue <- Map.keys(Durable.Config.queues()) do
      Task.async(fn -> Durable.Queue.Manager.drain(Durable, queue, 25_000) end)
    end

  Task.await_many(tasks, 30_000)
  state
end
```

Set your platform's shutdown grace period longer than this. In Kubernetes that's
`terminationGracePeriodSeconds`, which is 30 seconds by default. Skip this on
nodes with `queue_enabled: false`.

A step that outlasts the timeout falls back to the takeover above. If your steps
run long, you can shorten that with a smaller `stale_lock_timeout`, keeping it
several times `heartbeat_interval`. A worker whose lock was taken over is fenced
out, so two copies can't both record a result.

### Make steps safe to run twice

A crash, or a takeover like the one above, runs the step again. Use an
idempotency key when you call a payment API, and upserts rather than inserts.

### Upgrade Durable

When a release adds migrations:

```bash
mix durable.gen.upgrade -r MyApp.Repo
mix ecto.migrate
```

Migrate before the new code starts, because a node can fail to boot against an
older schema. `mix durable.migrations -r MyApp.Repo --check` fails when the
database is behind, so you can put it in a deploy gate. The dashboard's Settings
page shows the same thing.

### Change a workflow with runs in flight

A run resumes on whatever code is deployed. New steps after where it stopped are
picked up. If you rename or remove the step a run stopped at, it fails with
`definition_changed` and doesn't compensate. Put the step back and call
`Durable.retry/2`, or keep the old step until those runs have finished.

## What Durable does on its own

| Job | How often | Runs on |
|---|---|---|
| Delete finished runs past `prune:` | Hourly | Every node, if `prune:` is set |
| Put runs with a stale lock back on the queue | Every 60 s | Worker nodes |
| Time out waits and overdue runs | Every 60 s | Worker nodes |
| Wake sleeping runs | Every 1 s | Worker nodes |
| Fire cron schedules | Every 60 s | Worker nodes, one claims each fire |
| Delete queue samples and activity older than 7 days | With each sample | Every node |
| Forget nodes unseen for a day | With each heartbeat | Every node |

## Watching it

Add `Durable.Telemetry.metrics/0` to your reporter:

```elixir
def metrics, do: my_metrics() ++ Durable.Telemetry.metrics()
```

These are the ones worth an alert:

| Watch | Where | Means |
|---|---|---|
| Oldest ready run | `oldest_ready_at` from `Durable.Stats.queues/1` | Work is waiting longer than it should: add capacity, or look for a stuck queue |
| Ready backlog | `ready` from `Durable.Stats.queues/1` | Not keeping up. Past about 10,000, claims get slower too |
| Failed runs | `durable.workflow.stop.count`, `status: :failed` | The usual signal, per workflow |
| Recovered runs | `durable.queue.stale_recovered.count` | Expected around a deploy without a drain. Otherwise a node crashed |
| Fenced workers | `durable.queue.worker_fenced.count` | A run was taken over while its worker was still going, usually because heartbeats weren't getting through |
| Failed acks | `[:durable, :queue, :ack_failed]` event | A finished job couldn't be released after retries |
| Turned-off schedules | `schedule_disabled` in `Durable.Activity.list/1` | A cron schedule kept failing and stopped firing |
| Dead rows | The SQL above | Vacuum isn't keeping up, or a long transaction is blocking it |

The [dashboard](https://durable.wavezync.com/docs/using-the-dashboard/) shows most
of this on its Queues & nodes page, with recoveries and fenced workers listed for
the last day.

`mix durable.doctor` reports stuck state: waiting runs nothing can wake, stale
locks, stalled compensations and schedules that were turned off. `--fix` runs the
same recovery as the background sweep. `mix durable.status` gives a quick summary.
Mix tasks aren't available inside a release, so run these from somewhere that has
Mix and can reach the database, such as a CI job.

## Housekeeping

| When | Do |
|---|---|
| Before each deploy | `mix durable.migrations --check` |
| On each Durable upgrade | `mix durable.gen.upgrade`, then `mix ecto.migrate` |
| Weekly | Look at dead rows, table sizes and failed runs that nobody has handled |
| Monthly | Check retention still fits: disk growth against what you keep |
| After changing retention | Check index sizes, and reindex if they're far bigger than the tables |
| In an incident | `mix durable.doctor`, then the Queues & nodes page |
