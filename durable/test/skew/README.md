# Clock-skew swarm

Three Durable nodes in Docker containers on the test Postgres, one with the
right clock (`zero`), one ahead (`ahead`) and one behind (`behind`), skewed with
libfaketime. The BEAM's monotonic clock is left alone, so only the wall clock
is off. An orchestrator container starts runs on chosen nodes, cancels them
from others, and checks what happened. Each run marks what it did in
`skew.marks`, stamped by the database's `clock_timestamp()`, so every check
reads one clock.

```bash
test/skew/run.sh                     # skews of 0, 1, 4 and 40 s, about 12 minutes
SKEWS="4" ROUND_SECONDS=70 test/skew/run.sh
```

It needs Docker and the test Postgres (`docker compose up -d` at the repo root,
container `durable-postgres-1`). It joins that container's network
(`SKEW_NETWORK`, default `durable_default`) and uses its own database,
`durable_skew`, dropped and made again for each round. Output goes to
`SKEW_OUT` (default `/tmp/durable-skew`): `results.txt` and each node's log.
The script exits non-zero if any check failed. It's not part of `mix test` or CI.

Nodes run with `stale_lock_timeout: 3`, `heartbeat_interval: 500`, and the
timeout and stale sweeps a few times a second, so a round is short. A round
checks:

| Check | What |
|---|---|
| `step-once` | A 7 s step on each node runs once: no two attempts overlap |
| `key-once` | A run cancelled mid-step, then a run of its key (a new start, a `run_again` waiting behind it, a `rollback: true` cancel), with the worker, the canceller and the starter on different nodes: the two never run at once |
| `undo-after-step` | The undo of a `rollback: true` cancel starts after the step it cancelled has stopped |
| `sleep-on-time`, `snooze-on-time`, `retry-on-time`, `event-timeout-on-time` | A 2 s sleep, snooze, retry backoff and `wait_for_event` timeout, written on each node, end within 500 ms of when they were due |
| `deadline-on-time` | A `timeout: 2_500` workflow started on one node and run on another is stopped within 500 ms of its deadline |
| `retried-wait-on-time` | A run whose 2 s wait timed out, retried on each node: its step waits 2 s again, no more and no less |
| `schedule-once-on-time` | A `* * * * *` schedule fires once a minute, within 1.5 s |
| `nodes-alive` | Every node sees all three as alive |

Before `Durable.Clock` (ARCHITECTURE.md, rule 33), a 1 s skew broke `key-once`
and every timing check, 4 s broke `step-once`, `undo-after-step` and
`schedule-once-on-time` too, and 40 s `nodes-alive`.
