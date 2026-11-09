# Architecture

How Durable works today. For what's coming next, see [PLAN.md](PLAN.md). For how to use it, see the [guides](durable/guides) and [durable/README.md](durable/README.md).

Durable is a library. An app adds it to its supervision tree and gives it an Ecto repo. There's no separate server: every node of the app runs the engine, and PostgreSQL is the only shared state.

## Repository

| Path | What it is |
|---|---|
| `durable/` | The engine, published to Hex |
| `durable_dashboard/` | Phoenix LiveView dashboard, published separately. It uses the engine's public API and PubSub events, with one React island for the workflow graph. Its visual rules are in `durable_dashboard/DESIGN.md` |
| `examples/phoenix_demo/` | A Phoenix app wired up to both |
| `site/` | The website. Its docs pages render the packages' own markdown files |

## Processes

Each `{Durable, ...}` instance starts this tree on every node:

```
Durable.Supervisor
├── Phoenix.PubSub          only with pubsub: :start
├── Task.Supervisor
├── NodeRegistry            records this node and its queues; a node unseen for 30 s is missing
├── Queue.Sampler           samples queue depth for the dashboard
├── Queue.CommitWaker       only with a PubSub; wakes pollers after a transaction commits
├── Pruner                  only with prune:
│
│   the rest only when queue_enabled is true
├── Queue.Manager
│   ├── StaleJobRecovery    every 60 s
│   ├── for each queue
│   │   ├── DynamicSupervisor → Worker → Task (one per claimed run)
│   │   └── Poller
│   └── Drainer             stopped first; stops claiming and waits, on every queue at once
├── Wait.TimeoutWorker      every 60 s
├── Wait.SleepWaker
└── Scheduler               every 60 s by default
```

## Data

All tables live in the `durable` schema.

| Table | Holds |
|---|---|
| `workflow_executions` | One row per run: status, queue, context, lock, deadline, key, tags. This row is also the job |
| `step_executions` | One row per attempt of a step, with its output, error and captured logs |
| `pending_inputs` | Waits for human input |
| `pending_events` | Waits for events, events kept with `buffer: true`, and the internal events that tell a parent its children finished |
| `wait_groups` | `wait_for_any`, `wait_for_all` and parallel blocks |
| `scheduled_workflows` | Cron schedules |
| `queues`, `queue_samples` | Paused queues, and queue depth over time |
| `nodes`, `activity` | Live nodes, and an audit log of operator actions |

## Life of a run

```
             claim                finish
 pending ───────────▶ running ───────────▶ completed
    ▲                  │  │  │
    │  retry, snooze,  │  │  └──▶ cancelled
    └── move queue ◀───┘  │
    ▲                     ├─ wait ─▶ waiting ─ answered, timed out or woken ─▶ pending
    │                     │
    │                     └─ step fails for good ─▶ failed
    │                                          or ─▶ compensating ─▶ compensated
    │                                                             or compensation_failed
    └── recovered when its node dies
```

**Claiming.** A poller claims due runs with `FOR UPDATE SKIP LOCKED`, up to its free slots, by priority and then by when each became ready (`COALESCE(scheduled_at, inserted_at)`), so a retry that has come due isn't behind runs started after it. The claim sets `running`, the lock, and a new `lock_token`. Paused queues and runs waiting behind a key's holder are skipped.

**Running.** Each claim gets a `Worker`, which runs the executor in a `Task` and sends heartbeats, and traps exits so it outlives that `Task`. A `Task` that dies is a failed attempt: the worker closes its step row and puts the run back on its queue for the next attempt, or for the next claim to fail it if that was the last. The executor runs one step at a time, saving the context after each. Concurrency is per node: slots are counted per worker process in each poller.

**Stopping and resuming.** A run never holds a worker while it waits for time or for someone else. A retry's backoff, a snooze or a move to another queue puts the run back to `pending` with the lock cleared. A wait sets `waiting`. In both cases the step that stopped runs again from the top when the run resumes, so code before a wait runs twice and must be safe to repeat.

## How each feature works

**Steps** return `{:ok, data}`, `{:goto, step, data}`, `{:error, reason}`, `{:fail, reason}`, `{:snooze, ms}` or `{:cancel, reason}`. Waits are thrown as control flow. `{:error, _}`, a raise, an exit or a throw uses the step's retries. `{:fail, _}` skips them.

**Waits.** The wait's rows and the `waiting` status commit in one transaction, so whoever answers finds a run it can resume or finds no wait at all. The answer is merged into the context, and when the step runs again the wait finds it there and returns it.

**Sleep** is `waiting` with a `scheduled_at`. `SleepWaker` flips due runs to `pending` and stamps a marker so the step's `sleep` returns instead of sleeping again.

**Parallel blocks.** Each branch is its own run, with a marker in its context saying which step it is. The parent waits on a wait group with one internal event per branch. Branches can retry, sleep, wait and call children.

**Child workflows.** The parent waits on an internal event named after the child. The child commits its final status and then looks for that event. The parent commits its event and then reads the child. Whichever goes second sees the other, so a child that finishes early can't be missed.

**Compensations** run in reverse order, in the worker, after a step fails for good. Each attempt is a `step_executions` row. Their retries still wait in-process, capped at 30 s, and the worker keeps heartbeating. One compensation failing doesn't stop the others.

**Step queues.** `queue` is where the run is claimed now. `home_queue` is where it goes back to, set only while it's away. A move releases the run and wakes the target queue.

**Deadlines.** A run past its `timeout:` fails at its next step boundary, or when `TimeoutWorker` resumes it from a wait. If no live node polls its queue, the sweep hands it to the queue it came from, or to another that's polled, and a worker there fails it.

**Cancelling** clears the run's lock token. The worker's next heartbeat sees the run is cancelled and kills the step. Until then a step can check `cancelled?/0` to stop cleanly.

**Workflow keys.** At most one run holds a key, enforced by a partial unique index on `holds_key`. `on_duplicate: :run_again` keeps one run waiting behind the holder through `runs_after_id`.

**Wakes** spare a poller from waiting for its next poll. Outside a transaction a wake is a PubSub broadcast. Inside one, it records the transaction's id and `CommitWaker` asks Postgres with `pg_xact_status` how it ended, then broadcasts on commit and drops it on rollback. Runs that come due later are found by polling.

## When a node dies

| Situation | What recovers it |
|---|---|
| `running`, lock not refreshed for `stale_lock_timeout` (300 s) | `StaleJobRecovery` closes the attempt as failed (`worker_lost`) and sets the run back to `pending`, and the old worker is fenced out by its `lock_token` |
| `waiting` with nothing left that could wake it | `StaleJobRecovery` marks it failed |
| `compensating`, lock not refreshed for `stale_lock_timeout` | `StaleJobRecovery` marks it failed |
| Parent waiting on a child that finished, its notice lost | `StaleJobRecovery` sends the notice again |
| A wait past its timeout | `TimeoutWorker` |

A step whose process dies uses one of its attempts. With attempts left the step runs again, so steps should be idempotent: delivery is at least once. With none left (one attempt is the default) the next claim fails the run the normal way.

A lost worker uses no attempt, because the step may be fine: one outage can take every lock at once. The step runs again, and after three `worker_lost` rows the next claim fails the run, so a step that takes its node down can't loop forever.

A node that stops cleanly needs none of this. `Queue.Drainer` stops claiming, and each run finishes its current step and goes back on its queue through the same path as a step's `queue:`. What's still running when `shutdown_grace_period` ends goes back on its queue before its worker is killed, with its lock token cleared. That doesn't use an attempt.

## Rules to keep

Each of these was learned from a real bug. Breaking one brings it back.

1. **No session state.** No `LISTEN`, session advisory locks or `SET`. Durable has to work through a transaction-mode connection pooler as well as on direct connections.
2. **Lock order.** Any transaction that changes a wait and its run locks the run first (`Executor.lock_run/2`).
3. **Keys.** Any change to who holds a key takes the per-key advisory lock first (`Keys.lock_key/2`).
4. **Commit a wait with its status.** Never write a wait's rows and `waiting` in separate statements (`enter_wait/3`).
5. **Writes to a run, and how an attempt ended, go through the compare-and-set** (`cas_update/3`), on status and the claim's lock token, so a cancel or a takeover wins over a worker that's still running.
6. **Everything stored is made storable first.** Use `sanitize_for_json/1`, `storable_error/1`, `storable_input/1` or `serialize_output/1`. A date or decimal in a `:map` column makes the row unreadable.
7. **Don't make atoms from stored text.** Use `Context.known_key/1`. Atoms are never freed.
8. **A wake is only a hint.** Losing one must cost no more than the next poll.
9. **Whoever ends a run tells its parent.** A sweep or a worker that fails a run in the executor's place calls `Executor.maybe_notify_parent/4`, or the parent waits forever.
10. **A context save records its key shapes** (`save_data_as_context/3`, `release/4`), and `restore_keys/1` reads them, so a step sees the same data however the run got back to it.

## Tests

| Command | What it covers |
|---|---|
| `mix test` | Fast suite, inside the SQL sandbox |
| `mix test --only integration` | Live pollers, committed rows, the real clock and real second nodes |
| `mix test --only fuzz` | Hostile values, the public API, generated runs checked against a model, and operator actions racing live runs. `--seed` replays a failure and `FUZZ_RUNS=n` runs more cases |

CI runs the last two both direct and through PgBouncer in transaction mode. Set `INTEGRATION_DB_PORT` to do the same locally.
11. **Whoever closes an attempt's row sends its end event** (`StepRunner.report_closed/5`). A worker that finds its row closed (`Executor.finish_attempt!/2`) stays quiet, so each attempt gets exactly one, from any node.
12. **The database's clock is read as UTC** (`(NOW() AT TIME ZONE 'UTC')`). Timestamp columns hold UTC in a type with no zone, so a bare `NOW()` is wrong on any server not set to UTC.
