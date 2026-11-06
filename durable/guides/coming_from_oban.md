# Coming From Oban

Durable runs workflows: a run is a series of steps with retries, waits and
compensations, and it can pause for days. Oban runs jobs. Many Oban setups
are pipelines built from jobs that enqueue the next job, and in Durable one
workflow replaces the chain. This guide maps what you use in Oban to what
does the same thing here.

## At a Glance

| In Oban | In Durable |
|---|---|
| A worker's `perform/1` | A workflow's steps |
| `Oban.insert/2` | `Durable.start/3` |
| `Oban.insert_all/2` | `Durable.start_many/2` (keys are still checked) |
| `unique:` | A workflow key: `key: "order:42"` ([Workflow keys](workflow_keys.md)) |
| `unique:` on a cron job | `@schedule cron: "...", key: "cleanup"` |
| `max_attempts`, `backoff/1` | `retry: [max_attempts: 5, backoff: :exponential]` on a step |
| `job.attempt` | `attempt/0`, `max_attempts/0`, `last_attempt?/0` in `Durable.Context` |
| `{:snooze, seconds}` | `{:snooze, ms}` or `{:snooze, ms, reason}` |
| `{:cancel, reason}` | `{:cancel, reason}` |
| `{:discard, reason}` | `{:fail, reason}` |
| `tags` | `tags: ["account:7"]` on start |
| `Oban.cancel_all_jobs/1` | `Durable.cancel_all([tag: "account:7"], reason)` |
| `assert_enqueued`, `refute_enqueued`, `all_enqueued` | `assert_started`, `refute_started`, `all_started` in `Durable.Testing` |
| `Oban.drain_queue/1` | `Durable.Testing.drain/2` |
| A queue with a `limit` | A queue with a `concurrency` |

## Differences That Bite

- **Priority runs the other way.** Higher `priority:` numbers run first
  (default `0`). In Oban, `0` is the highest priority.
- **Times are in milliseconds.** `{:snooze, 15}` waits 15 ms, not 15 s. Use
  the helpers: `{:snooze, seconds(15)}`.
- **One retry budget per step, not per job.** Each step has its own
  `retry:`. A step that completed isn't run again when a later step fails.
- **Retries wait off the worker.** Between attempts the run goes back on its
  queue until the backoff has passed, as in Oban, so a long backoff holds no
  slot. `max_backoff` defaults to 1 hour.
- **A snooze doesn't use an attempt**, and there's no limit on snoozes. The
  workflow's `timeout:` is what stops a step that snoozes forever.
- **`{:cancel, reason}` in a parallel step cancels the whole workflow**,
  without compensations. Pass `scope: :run` to cancel only that branch.
- **Keys are checked on every start**, `start_many/2` included. Oban's
  `insert_all` on the basic engine skips unique checks.
- **Queue concurrency is per node.** `concurrency: 20` on three nodes runs up
  to 60 at once, as Oban's `limit` does without Oban Pro's global limits.

## Production Settings

Pruning is off by default, and every log line a step writes is stored. See
[Production Settings](../README.md#production-settings) before you go live.
