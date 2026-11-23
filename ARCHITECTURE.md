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
| `workflow_executions` | One row per run: status, queue, context, engine state, lock, deadline, key, tags. This row is also the job |
| `step_executions` | One row per attempt of a step, with its output, error and captured logs |
| `pending_inputs` | Waits for human input |
| `pending_events` | Waits for events, events kept with `buffer: true`, and the internal events that tell a parent its children finished |
| `wait_groups` | `wait_for_any`, `wait_for_all` and parallel blocks |
| `scheduled_workflows` | Cron schedules |
| `queues`, `queue_samples` | Paused queues, and queue depth over time |
| `nodes`, `activity` | Live nodes, and an audit log of operator actions |

A run's `context` is the user's data and nothing else. What the engine itself needs to know about the run (which step a saved result came from, the lanes of its block, the children it called, what its wait was answered with, that it is to be rolled back) is in `engine_state`, a column of its own. The user's data comes from outside, so the engine never reads its state from the context, and drops its own names from the user's data wherever that comes in (`Durable.EngineState`).

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

**Running.** Each claim gets a `Worker`, which runs the executor in a `Task` and sends heartbeats, and traps exits so it outlives that `Task`. The worker settles the result itself and then reports to its poller for the slot. A `Task` that dies is a failed attempt: the worker closes its step row and puts the run back on its queue for the next attempt, or for the next claim to fail it if that was the last. The executor runs one step at a time, saving the context after each, and the engine state with it in the same write. Concurrency is per node: slots are counted per worker process in each poller, and a poller that restarts takes over the workers the last one left. A worker hands the executor its claim's `lock_token`, and runs nothing if the row has another by then. A caller that runs a run itself (`inline: true`, `Durable.Testing`) has no claim, so the executor takes one for it as a poller would (`claimed/3`: `running`, `locked_by`, `locked_at` and a `lock_token`) and refreshes it from a process beside the caller while the run goes on. It runs nothing if a worker's claim is on the row, and if the caller dies the stale sweep finds the run like any other.

**Stopping and resuming.** A run never holds a worker while it waits for time or for someone else. A retry's backoff, a snooze or a move to another queue puts the run back to `pending` with the lock cleared. A wait sets `waiting`. In both cases the step that stopped runs again from the top when the run resumes, so code before a wait runs twice and must be safe to repeat.

## How each feature works

**Steps** return `{:ok, data}`, `{:goto, step, data}`, `{:error, reason}`, `{:fail, reason}`, `{:snooze, ms}` or `{:cancel, reason}`. Waits are thrown as control flow. `{:error, _}`, a raise, an exit or a throw uses the step's retries. `{:fail, _}` skips them.

**Waits.** The wait's rows and the `waiting` status commit in one transaction, so whoever answers finds a run it can resume or finds no wait at all. Events kept for it with `buffer: true` are handed over in that same transaction. A wait that can't be written (a sleep to a time no timestamp holds, a timeout that isn't a number) is the step's failure: its row is closed as failed and the run fails with that error. The answer is merged into the context under the wait's name. When the step runs again, each wait call finds its own row: the n-th wait the step made under that name (or, for `wait_for_any`/`wait_for_all`, those names), n counted from the top of the body on every pass. So a name waited for again, in a later step or after a timeout in the same one, waits for a new answer, and a key of the same name in the run's data is never taken for one. The row says how the wait ended: answered (the context has the value, or the row's copy for an earlier wait of a name asked again in the step; a group's row has what it got), timed out, or cancelled. A run that is retried keeps the answers its step already had, and its waits that timed out, were cancelled, or were closed when the run failed, wait again (`retried_at`). `cancel_wait/2` ends the waits that are open, and a sleep through the same marker `SleepWaker` leaves; a wait the step reaches after that waits like any other. Why a wait was cancelled is the engine's to say, and goes in the engine state: the step's body reads it through its process, never from its data. A wait that timed out returns its call's own `timeout_value` instead; the copy on the wait's row is only there to be shown. `Wait.cancel_wait/2` ends a run's own wait. A run that waits on other runs, a block on its lanes or a `call_workflow` on its child, has none: the call goes down to those that are waiting, and the wait on them is left alone, since resuming a block with its lanes unfinished would fail it and strand them.

**Sleep** is `waiting` with a `scheduled_at`. `SleepWaker` flips due runs to `pending` and stamps a marker in the engine state so the step's `sleep` returns instead of sleeping again.

**Parallel blocks.** A block has a name and holds lanes. Each lane is its own run, with a marker in its engine state naming the lane, and the run executes that lane's steps as a sequence. The parent waits on a wait group with one internal event per lane. Lanes can retry, sleep, wait and call children. The marker stays for as long as the run is kept, and is never in a step's data or a lane's result. The block's run keeps its lanes in its own engine state until their results are saved. A lane's result is what it produced: its final data less every key still equal to what the block started it with, so the block's data is stored once and not once per lane. A block with `on_error: :collect` lets every lane run to its end and puts each under the block's name as `{:ok, data}` or `{:error, reason}`; stored, a pair is a two-item list, and it is turned back into a pair whenever the data is handed to a step, a block's in a lane's data included (`restore_lane_keys/2`), the one thing a step doesn't see as stored. A lane that is cancelled on its own, by its step or by an operator, ends a block that fails fast as a failed lane does. A lane marked `optional: true` is recorded as such with the block's children: its failure doesn't end a block that fails fast, and its place under the block's name is `nil`, or its `default:`. A lane's `timeout:` is a deadline on the lane's own run, the earlier of that and the block's run's; it is kept with the block's children so a retry can set it again, and a lane retried by its own id gets it again from the workflow's code (`retried_deadline/1`). The error says whose deadline it was: the lane's, or the run's when that came first (`lane_timeout/3`). A lane's notice to its block counts only if the lane hasn't been retried since it ended: a retry of the block waits for the lane on the same event, and stamps the lane (`retried_at`) under the block's row lock, which the notice holds when it looks (`if_not_retried/2`).

**Named branches.** The deciding function runs through the step runner as a step that jumps: the arm is what the step's row records. The executor then runs the arm's steps followed by what comes after the block.

**Jumps.** A `{:goto, step, data}` goes forward only. The steps of every arm and every lane sit side by side in the definition, so a jump from outside a branch or a parallel block to a step inside one is refused: the run would go on through the other arms, or run a lane's steps in the block's own run. A step inside an arm can jump ahead in its arm, or out of the block.

**What a save records.** A step's result is saved with the name of the step it came from, in the engine state and in the same write as the result, and for a branch the arm, for a jump its target, and for a parallel block the fact that it finished. A run that comes back to that step, because it was stopped or lost its worker before moving on, continues from what follows. Without this the step would run again on its own result, a branch or a jump would decide again, and a parallel block would start its lanes a second time.

**Child workflows.** The parent waits on an internal event named after the child, and keeps which child it started under each `ref:`, and what that child ended with, in its engine state: nothing in a step's data can stand in for a child. The child commits its final status and then looks for that event. The parent commits its event and then reads the child. Whichever goes second sees the other, so a child that finishes early can't be missed. Both can then tell the parent, and either can be slow to: a notice ends the wait only if the event it read is still pending once it holds the parent's row, so a late one leaves alone a parent that has gone on to another wait. A child is inserted in the same transaction that records it on the parent's row (`record_child/3`), so a parent lost in between doesn't start a second one when its step runs again. Which step called it (`__call_children`, for the dashboard) is recorded in that transaction too: the step that runs again finds its child and doesn't record it a second time.

**Compensations** run in reverse order, in the worker, when a failed run is rolled back. A failure rolls back only if the workflow says `on_failure: :rollback` or the error's type is `"rollback"`, which is what a step's `{:rollback, reason}` becomes and what a block passes up from a lane; otherwise the run is marked failed and nothing is undone. `Durable.rollback/2` puts a failed run back on its queue with the error it failed with under `__rollback__` in its engine state, and the worker that claims it compensates before anything else, so it never runs a step. The marker also holds the status the run had, so a run with nothing to undo goes back to it. `Durable.cancel(id, reason, rollback: true)` queues the same thing for the run it cancelled, in the transaction that cancels it, so a run waiting behind its key never sees it over before the undo; if a worker had that run, the undo is scheduled one heartbeat later, when that worker has stopped and no step of its can still finish. That worker's heartbeat takes the run, back on its queue with the marker, as cancelled, and the step it was running stays open for it: finished in time, it is undone with the rest. With `on_failure: [rollback_after: ms]` a run that halts gets the time it is to be undone in `scheduled_at`, which nothing else reads on a failed run; the timeout sweep rolls back the ones that are due. A lane's own run isn't given one. Each attempt is a `step_executions` row, stopped at its `timeout:` if it has one. Their retries still wait in-process, capped at 30 s, and the worker keeps heartbeating. One compensation failing doesn't stop the others. A rollback that lost its worker part-way, and is asked for again, leaves out the steps whose undo completed (`build_compensation_stack/3`): an undo that finished isn't run twice, and one that was cut short is. Such a run can't be retried (`{:error, :rolled_back}`): some of it is undone.

**Step queues.** `queue` is where the run is claimed now. `home_queue` is where it goes back to, set only while it's away. A move releases the run and wakes the target queue.

**Deadlines.** A run past its `timeout:` fails at its next step boundary, or when `TimeoutWorker` resumes it from a wait. A step still running at the deadline is stopped then and isn't retried; its time limit is what's left to the deadline rounded up to the millisecond, never down, or the step is stopped with the deadline not yet passed and retried. If no live node polls its queue, the sweep hands it to the queue it came from, or to another that's polled, and a worker there fails it. A lane is handed over the same way when the deadline is its own `timeout:`; when it is the block's run's, that run is the one handed over, and it cancels the lane. A run whose code is on no node waits, checked every 30 s, until it's 15 minutes past its deadline, and then fails without compensations.

**Cancelling** clears the run's lock token. The worker's next heartbeat sees the run is cancelled, or that its claim is gone (a cancel with `rollback: true` puts the run straight back on its queue), and kills the step. A heartbeat that finds another token on the row, whatever its status, stops the step the same way. Until then a step can check `cancelled?/0` to stop cleanly.

**Workflow keys.** At most one run holds a key, enforced by a partial unique index on `holds_key`. `on_duplicate: :run_again` keeps one run waiting behind the holder through `runs_after_id`, and a later start gives that run its input, with or without a holder: a holder being rolled back has let the key go. That run takes the key as the claim that came for it (`Keys.hold/5`, on its status and lock token), so one cancelled as it does never holds it.

**Wakes** spare a poller from waiting for its next poll. Outside a transaction a wake is a PubSub broadcast. Inside one, it records the transaction's id and `CommitWaker` asks Postgres with `pg_xact_status` how it ended, then broadcasts on commit and drops it on rollback. Runs that come due later are found by polling.

## When a node dies

| Situation | What recovers it |
|---|---|
| `running`, lock not refreshed for `stale_lock_timeout` (300 s) | `StaleJobRecovery` closes the attempt as failed (`worker_lost`) and sets the run back to `pending`, and the old worker is fenced out by its `lock_token` |
| `waiting` with nothing left that could wake it | `StaleJobRecovery` marks it failed |
| `compensating`, lock not refreshed for `stale_lock_timeout` | `StaleJobRecovery` marks it failed, with the error it had: why it was being undone. Why the rollback stopped is on the undo's row and in a `rollback_interrupted` activity. `Durable.rollback/2` then finishes the job: the undos that completed aren't run again |
| `compensating`, on a node that stops cleanly | The node hands it back with its rollback marker, and the next node to claim it undoes what is left |
| Parent waiting on a child that finished, its notice lost | `StaleJobRecovery` sends the notice again |
| A cancelled run with a wait still open or a run under it still going: whoever cancelled it was lost before closing them | `StaleJobRecovery` closes them (`close_out_lost/2`). A run under it that was retried since is left alone |
| A wait past its timeout | `TimeoutWorker` |

A step whose process dies uses one of its attempts. With attempts left the step runs again, so steps should be idempotent: delivery is at least once. One case is spared: a step that had finished, its row written, when its worker was lost before the run saved the result. The run that comes back takes the result from the row and moves on (`finished_before_lost/5`), which holds what the step returned and what it put in the context. The keys it deleted from the context are not there: the output is the user's data, and nothing in it can say a key was taken out. They are written to the run's engine state under the attempt's row id (`__dropped:<id>`, `StepRunner.record_deleted/3`) just before the row is completed, so a completed row always has them, and the run that takes the row's result drops them from the data it merges the result over. They are named by the row so that another attempt's can't stand in for them, and are gone at the next save (`save_data_as_context/5`). A worker lost inside the body, before the row is written, still runs the step again. With none left (one attempt is the default) the next claim fails the run the normal way. A process that dies outside a step (in a branch's `on:`, a parallel `into:`, or between two steps) has no attempt to use, and nothing says the code is at fault: the run goes back on its queue and carries on from where it was. Each such loss is recorded as a `worker_lost` activity, and the third in a row at one step fails the run, so code that dies every time can't loop for ever. It fails without compensating, since no step failed, and can be retried.

A lost worker uses no attempt, because the step may be fine: one outage can take every lock at once. The step runs again, and after three `worker_lost` rows the next claim fails the run, so a step that takes its node down can't loop forever.

A node that stops cleanly needs none of this. `Queue.Drainer` stops claiming, and each run finishes its current step and goes back on its queue through the same path as a step's `queue:`. What's still running when `shutdown_grace_period` ends has its worker killed, step and all, and then goes back on its queue with its lock token cleared: no step of it is left running beside the next node's, and none holds a connection the hand-back needs. That doesn't use an attempt. At `shutdown_grace_period: 0` the node waits for nothing and hands every run back at once: the `Drainer` is always there, so a clean stop never leaves a run for the stale sweep. A run being rolled back goes back too, to be rolled back: the undo that was cut short runs again from the top, and the ones that completed don't.

## Rules to keep

Each of these was learned from a real bug. Breaking one brings it back.

1. **No session state.** No `LISTEN`, session advisory locks or `SET`. Durable has to work through a transaction-mode connection pooler as well as on direct connections.
2. **Lock order.** Any transaction that changes a wait and its run locks the run first (`Executor.lock_run/2`).
3. **Keys.** Any change to who holds a key takes the per-key advisory lock first (`Keys.lock_key/2`).
4. **Commit a wait with its status.** Never write a wait's rows and `waiting` in separate statements, nor hand it the events kept for it in another (`enter_wait/4`).
5. **Writes to a run, and how an attempt ended, go through the compare-and-set** (`cas_update/3`), on status and the claim's lock token, so a cancel or a takeover wins over a worker that's still running.
6. **Everything stored is made storable first.** Use `sanitize_for_json/1`, `storable_error/1`, `storable_input/1` or `serialize_output/1`. A date or decimal in a `:map` column makes the row unreadable.
7. **Don't make atoms from stored text.** The user's data keeps its string keys. For a stored name of the code's own (a step, a lane, a compensation) use `Context.known_key/1`. Atoms are never freed.
8. **A wake is only a hint.** Losing one must cost no more than the next poll.
9. **Whoever ends a run tells its parent.** A sweep or a worker that fails a run in the executor's place calls `Executor.maybe_notify_parent/4`, or the parent waits forever.
10. **A step is handed its data as it is stored**: string keys at every depth, an atom as its text, a tuple as a list, whether the run went straight on from the last step or was loaded again. `Durable.Executor` puts the data in that form at the one place a step is handed it (`stored/1` in `execute_steps_recursive/6`) and on every save (`save_data_as_context/5`, `release/4`), and what a save passes to the next step is the context it wrote (`passed_on/2`). The engine never makes an atom key out of the user's data. A save still leaves `__string_keys__` in `engine_state` (`record_saved/2`), in the same write as the context, but only as the mark that the run has saved a context (`saved?/1`): its value is no longer read. `__atom_twins__` is no longer written, and is dropped from an old row at its next save.

## Tests

| Command | What it covers |
|---|---|
| `mix test` | Fast suite, inside the SQL sandbox |
| `mix test --only integration` | Live pollers, committed rows, the real clock and real second nodes |
| `mix test --only fuzz` | Hostile values, the public API, generated runs checked against a model, and operator actions racing live runs. `--seed` replays a failure and `FUZZ_RUNS=n` runs more cases |

CI runs the last two both direct and through PgBouncer in transaction mode. Set `INTEGRATION_DB_PORT` to do the same locally.
11. **Whoever closes an attempt's row sends its end event** (`StepRunner.report_closed/5`). A worker that finds its row closed (`Executor.finish_attempt!/2`) stays quiet, so each attempt gets at most one, from any node. A worker killed between closing its row and leaving the span sends none.
12. **The database's clock is read as UTC** (`(NOW() AT TIME ZONE 'UTC')`). Timestamp columns hold UTC in a type with no zone, so a bare `NOW()` is wrong on any server not set to UTC.
13. **Whoever marks a run failed sets `scheduled_at` or clears it.** On a failed run it is when the sweep rolls the run back, and a claim leaves a retry's backoff or a delayed start there.
14. **The rollback marker comes out of `engine_state` in the write that makes the run `compensating`** (`roll_back/3`). A run still `running` without it is one the next claim carries on with.
15. **A run is undone only once nothing under it can still finish a step** (`settles_at/2`). A stopped run's worker hears of it at its next heartbeat, so the undo waits one heartbeat after the last run under it was stopped.
16. **A run being rolled back doesn't hold its key** (`without_key/2`), unless `reuse: :never`. A start with the key must not be handed a run that only undoes.
17. **A cancel leaves a run that carries the rollback marker alone** (`cancel_run/3`). On its queue to be undone it is `pending` like any other run, and cancelled it would end with nothing undone and no way to roll it back or retry it. To a cancel it has ended: `{:error, :already_completed}`.
18. **An attempt's row is written once, `running`, after its start event, and a run has one open at a time.** Written in two steps, a process killed between them left a row nobody closed. A write can still land after whoever cleaned up had looked, so an attempt begins by closing what the run left open (`StepRunner.execute/5`).
19. **A `compensating` run that goes back on its queue gets its rollback marker back** in `engine_state` (`release_node_jobs/2`, and `Executor.connection_lost/3` when its connection drops), and its error is on the row from the moment it is `compensating`. Put back `pending` without the marker, the next claim would run its steps. Whoever fails a `compensating` run in the executor's place (the zombie sweep, a worker whose task died) leaves that error alone (`Postgres.fail_runs/4`): `Durable.rollback/2` ends the run with it.
20. **A column that holds the user's data is a `Durable.Storage.JsonMap`, not a `:map`.** jsonb reads a whole float written the short way (`2.0e6`) back as an integer; the type writes it with its point, so a number has the same type after a save as before.
21. **A function that reads checks its input in `Durable.Query.Opts` and answers in a tuple.** `{:ok, result}`, `{:error, {:invalid_option, key}}` or `{:error, :not_found}`, with a `!` twin made by `Opts.unwrap!/3`. Nothing is clamped, and no input reaches Postgres to be refused there. A new one is added to `test/support/read_functions.ex`, which the contract test and the fuzz test call from.
22. **The engine's state lives in `engine_state`, never in the user's context.** Nothing in a run's context, a step's data or a wait's answer is read as a marker, whatever it is called, and the user's data has the engine's names dropped from it wherever it comes in (`EngineState.strip/1`): a start's input, a step's result, `put_context`, an event's payload, an input's answer. A new marker gets its name in `Durable.EngineState` and is written to the column. A step's body reads and writes the state through its process (`EngineState.current/0`), which the executor fills as the step starts and takes back as it ends (`run_step/4`).
23. **A write to `engine_state` that the struct in hand may not show is forced** (`save_data_as_context/5`, `release/4`, `mark_completed/3`, and `step_stopped/5` for a step that failed for good). Ecto writes a field only if it differs from the struct, and the struct can be ahead of the row: a step's body adds to it (a child started under a `ref:`), and a run that fails on that step and is retried has to find that child, not start another. `mark_failed/4` doesn't write it: a block whose `into:` failed has its lanes dropped from the struct, and keeps them on the row for a retry.
24. **A row is in the old layout until it carries the mark** (`"v"` in `engine_state`). Before the column, the state was in the context. The migration moves it for runs that are over; any other run keeps it there, for a node still on the old code, until an engine with the column loads the run and moves it once (`EngineState.adopt/2`). Only an unmarked row has its context read for state. Whoever loads a run to change it adopts it first. An engine from before the column can't read a marked row's state, so the two must never work the same database at once.
25. **A notice ends a wait only if that wait is still open under the run's lock** (`receive_if_pending/2`). It was read before the lock, and by then the run may be waiting on something else. A block retried in between waits on the same event again, so a lane's notice also checks, under that lock, that the lane wasn't retried since (`if_not_retried/2`); the retry takes the block's row before it writes a lane or an event (`reopen_parallel_block/3`, rule 2).
26. **Nothing runs a run without a claim on its row.** A caller that runs one itself (`inline: true`, `Durable.Testing`) takes a claim as a poller would (`Executor.claimed/3`), in one conditional write on the status and token it read, and refreshes it while it runs (`keeping_claim/3`). With no claim a poller took the run beside the caller and both ran it, and a caller that died left it `running` with no lock, which no sweep looks for. A caller with no token never runs a row that carries a worker's.
27. **A poller has one poll timer.** A timer that has fired can't be cancelled: its `:poll` is in the mailbox, and `schedule_poll/2` takes it out before it sets another. Left there, each `resume` added a chain of polls that never ended.
28. **A node that stops cleanly hands its runs back, whatever its grace period.** The `Drainer` is always started; at `shutdown_grace_period: 0` it waits for nothing. A test that wants a node lost kills it (`Process.exit(pid, :kill)`, `crash_node!/1`): a clean stop is not a crash.
29. **A worker settles its own run.** It acks or nacks by its claim's token (`Worker.settle_and_report/3`) and then tells its poller, which only frees the slot. Settled by the poller, a result sent to one that had just died was dropped: a rollback whose undo died, or a run lost for the third time, stayed locked for the stale sweep. The ack is one conditional write on the token and on the run having ended (`ack_with_retry/5`): a run still `running` keeps its lock, or no sweep would find it.
