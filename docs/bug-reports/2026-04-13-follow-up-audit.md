# Follow-up Audit: Serialization, State-Machine, and Context Footguns

**Date:** 2026-04-13
**Scope:** Systematic sweep after fixing the 4 bugs in `2026-04-12-parallel-context-and-serialization.md`. Three audit axes: (A) serialization write-paths, (B) state-machine dead-ends, (C) context-flow surprises.

## TL;DR

**16 additional issues found**, clustered around the same 4 root causes (silent serialization crashes, state dead-ends, unexpected context loss, missing recovery paths). **2 are critical enough to warrant immediate fixes.** Full severity-ordered list below.

---

## 🔴 CRITICAL — must fix next

### C-1. `put_context/2` silently loses data between steps

**Status:** ✅ Fixed (2026-04-13). `save_data_as_context/3` now merges the full process-dict into the persisted context; step return wins on collision. `handle_decision_result/8` also passes the merged `exec.context` forward instead of the goto's raw new_data, so context survives across `{:goto, ...}` boundaries (closes H-6 too).

**Files:** `lib/durable/executor.ex:1117-1141` (`save_data_as_context/3`), `lib/durable/context.ex`

`put_context(:foo, "bar")` in one step is **not** visible to the next step unless the user ALSO returns `:foo` in their step output:

```elixir
step :s1, fn data ->
  put_context(:charge_id, "ch_1")   # ← silently discarded at save time
  {:ok, %{completed: true}}           # ← only this map is persisted
end

step :s2, fn data ->
  get_context(:charge_id)             # ← returns nil!
end
```

`save_data_as_context/3` only merges **orchestration keys** (`__child:*`, `__fire_forget:*`) from the process dict. Every other user-written key is dropped.

This is the single biggest usability bug in the library. It makes the `put_context` / `get_context` API a footgun: it *looks* like it persists state, but only works if the user also threads the data through return values — at which point you might as well just use `data[:foo]`.

**Evidence it's already hurting the docs:** `examples/phoenix_demo/lib/phoenix_demo/workflows/document_workflow.ex` uses `put_context` heavily, and "works" only because the user also returned those same keys in `{:ok, %{filename: …, path: …, …}}`. A developer copying the pattern without including the keys in the return would silently lose state.

**Fix:** In `save_data_as_context/3`, merge ALL user keys from the process dict (not just orchestration keys) into `data` before persisting:

```elixir
defp save_data_as_context(config, execution, data) do
  process_ctx = Process.get(:durable_context, %{})
  merged =
    process_ctx
    |> Map.merge(atomize_keys(data))   # step return wins over prior writes
    |> sanitize_for_json()

  execution |> Ecto.Changeset.change(context: merged) |> Repo.update(config)
end
```

The step's return value takes precedence over `put_context` writes on key collision, which matches user intuition.

### C-2. `:timeout_value` in `wait_for_*` crashes JSONB storage

**Status:** ✅ Fixed (2026-04-13). `serialize_timeout_value/1` now routes both the `is_map(value)` and the catch-all `__value__` paths through `sanitize_for_json/1`. Tuples become lists, PIDs/refs become inspect strings, atoms still go through the `__atom__` round-trip helper.

**Files:** `lib/durable/executor.ex:1520, 1551, 1590, 1607` (`serialize_timeout_value/1`)

The entire `wait_for_event / wait_for_input / wait_for_any / wait_for_all / call_workflow` family accepts a `:timeout_value` option. Users naturally pass idiomatic Elixir tuples:

```elixir
wait_for_approval("manager_ok", timeout: hours(3), timeout_value: {:error, :timeout})
wait_for_input("feedback", timeout_value: {:ok, :auto_accepted})
```

`serialize_timeout_value/1` wraps the value in `%{"__value__" => value}` but doesn't run `sanitize_for_json/1` on it. The tuple leaks straight into `PendingInput.timeout_value` / `PendingEvent.timeout_value` (both `:map` fields) and crashes `Repo.insert` at setup time — before the workflow even enters `:waiting`.

**Fix:** Pipe through the sanitizer:

```elixir
defp serialize_timeout_value(value), do: %{"__value__" => sanitize_for_json(value)}
```

On the deserialize side (`wait/timeout_worker.ex:128-131`), the inverse isn't needed — tuples become lists via the sanitizer, and user code in `wait_for_*` returns values already pattern-matchable as `["error", :timeout]` (or we change the contract to always return sanitized shapes).

---

## 🟠 HIGH — fix in next batch

### H-1. `provide_input/3` writes user-supplied data without sanitization
**Status:** ✅ Fixed (2026-04-13) in PR 2. `Durable.Wait.provide_input/4` now sanitizes `data` once at the API boundary; both the `PendingInput.response` write and the downstream `resume_workflow/3` call see a JSONB-safe payload.
**File:** `lib/durable/wait.ex:547`

### H-2. `send_event/3` writes user payload without sanitization
**Status:** ✅ Fixed (2026-04-13) in PR 2. Same pattern as H-1 applied to `Durable.Wait.send_event/4`.
**File:** `lib/durable/wait.ex:575`

### H-3. `StepRunner.fail_step_execution` doesn't sanitize the error
**Status:** ✅ Fixed (2026-04-13) in PR 2. `fail_step_execution/5` now runs the error map through `Executor.sanitize_for_json/1` before the changeset.
**File:** `lib/durable/executor/step_runner.ex:292`

### H-4. `StepRunner.serialize_output` is shallow
**Status:** ✅ Fixed (2026-04-13) in PR 2. The custom case-clause logic is replaced with a recursive call to `Executor.sanitize_for_json/1`, with non-map outputs wrapped under `:value`. Nested tuples in step outputs are now handled at any depth.
**File:** `lib/durable/executor/step_runner.ex:322`

### H-5. Retries reset `put_context` state
**Status:** ✅ Fixed (2026-04-13) in PR 3. `StepRunner.execute_with_retry/6` now merges the existing process dict instead of overwriting on retry attempts, so prior `put_context` writes survive into subsequent attempts.
**File:** `lib/durable/executor/step_runner.ex:50-106`
On retry, `Process.put(:durable_context, data)` (line 56) overwrites any `put_context` writes from the failed attempt. Users expect retry-aware state like:

```elixir
step :flaky, retry: [max_attempts: 3], fn data ->
  count = (get_context(:attempt) || 0) + 1
  put_context(:attempt, count)   # ← resets to 1 every retry
  ...
end
```

**Fix:** At the top of `execute_with_retry/6`, merge `data` with the existing process dict instead of overwriting. Combined with C-1's fix, this gives retries genuine state continuity.

### H-6. Decision `{:goto, step, new_data}` loses prior context
**Status:** ✅ Fixed (2026-04-13) as part of PR 1. `handle_decision_result/8` now passes the merged `exec.context` (after `save_data_as_context/3`) to the next step instead of the goto's raw `new_data`. Prior `put_context` writes survive the goto.
**File:** `lib/durable/executor.ex:378+` (`handle_decision_result`)
If prior steps did `put_context(:foo, 1)` and a decision returns `{:goto, :later, %{bar: 2}}`, step `:later` sees only `%{bar: 2}` — `foo` is gone. Same root cause as C-1. The fix for C-1 handles this automatically.

### H-7. `resume_workflow/3` doesn't sanitize `additional_context`
**Status:** ✅ Fixed (2026-04-13) in PR 2. `Executor.resume_workflow/3` sanitizes `additional_context` before merging it into `execution.context`. This is the safety net for any future caller that bypasses the API boundary sanitization.
**File:** `lib/durable/executor.ex:160-171`

---

## 🟡 MEDIUM — address after serialization sweep

### M-1. No zombie detector for `:compensating` state
**Status:** ✅ Fixed (2026-04-13) in PR 5. `recover_zombie_workflows/2` now also catches `:compensating` workflows past the stale timeout with no running compensation `StepExecution`. Tests assert healthy compensating workflows with a live step are preserved.
**File:** `lib/durable/executor.ex:1455-1470`
The zombie detector we built only covers `:waiting`. If a compensation handler crashes mid-rollback (or the save after compensation fails), the workflow stays `:compensating` forever. **Fix:** Extend `recover_zombie_workflows/2` to also detect `:compensating` workflows older than the stale timeout with no active compensation step.

### M-2. PendingInput timeout can orphan a workflow
**Status:** ✅ Fixed (2026-04-13) in PR 4. `handle_input_timeout/2` now uses `Ecto.Multi` via new helpers `atomic_resume_after_timeout/4` and `atomic_cancel_after_timeout/4`. The PendingInput transition and the parent workflow's `:pending` flip happen in one transaction; a DB blip between the two rolls back both.
**File:** `lib/durable/wait/timeout_worker.ex:120+`
`TimeoutWorker` marks the input `:timeout` and then calls `resume_workflow/3`. If the resume fails (DB blip, crash between the two updates), the input is `:timeout` but the workflow is still `:waiting` — and now the zombie detector won't fire (it requires no-pending-inputs). **Fix:** Wrap the two updates in a transaction, OR set the workflow to `:pending` as part of the same update statement using `Ecto.Multi`.

### M-3. Child completion with failed parent notification
**Status:** ✅ Fixed (2026-04-13) in PR 4. `notify_orchestration_parent/4` now calls `atomic_fulfill_event_and_resume_parent/4`, which wraps the PendingEvent update and the parent workflow's context merge + `:pending` flip in a single `Ecto.Multi`. Orphan child completions (parent already cancelled/completed) are tolerated with a no-op and logged.
**File:** `lib/durable/executor.ex:1339-1356`
Child updates `PendingEvent` to `:received`, then calls `resume_workflow/3` on parent. If resume fails, parent stays `:waiting` with a consumed event. **Fix:** Use `Ecto.Multi` to couple both updates, OR make resume retry with backoff on transient failures.

### M-4. `WaitGroup` partial completion ambiguity
**Status:** ✅ Fixed (2026-04-13) in PR 6. The resume context now includes `:__wait_group_status__ => %{event_name => %{"status" => "received"|"timeout", "value" => ...}}`. The whole timeout + parent-resume is also wrapped in an `Ecto.Multi` so partial/lost events can't desync.
**File:** `lib/durable/wait/timeout_worker.ex:218-265` (`handle_wait_group_timeout`)
On `wait_for_all` timeout with 3 of 5 events received, the resume payload can't distinguish "4th timed out" from "5th still arriving." Late-arriving events after timeout are silently dropped. **Fix:** Include per-event status in the resume payload; log a warning when a received event finds its group already `:timeout`.

### M-5. `ack` failure causes silent re-execution
**Status:** ✅ Fixed (2026-04-13) in PR 4. `Durable.Queue.Adapters.Postgres.ack/2` now retries transient failures up to 3 times with randomized backoff and fires `[:durable, :queue, :ack_failed]` telemetry on exhaustion. A previously-silent `Repo.update` error would have resulted in stale-recovery re-executing the job 5 minutes later; now operators see telemetry before that window.
**File:** `lib/durable/queue/adapters/postgres.ex:64`
If the ack `Repo.update` fails after a workflow succeeds, the lock persists until the 300s stale-lock recovery kicks in — which then re-enqueues the already-done workflow. No idempotency key means it runs again. **Fix:** Retry ack with exponential backoff; add an `ack_failed` counter in telemetry so operators see silent re-executions.

### M-6. `LogCapture` silently drops unencodable metadata
**Status:** ✅ Fixed (2026-04-13) in PR 6. `serialize_value/1` now emits a rate-limited (once per step) warning when metadata is stringified via `inspect/1`, pointing devs at the non-JSON-safe value.
**File:** `lib/durable/log_capture.ex:261-269`
`serialize_value/1` converts tuples/PIDs/funs to `inspect/1` strings. No crash, but the debugging signal is degraded — devs see `"#PID<0.123.0>"` instead of the structured data they logged. **Fix:** Emit a one-time warning per step when metadata was stringified, so devs know to structure their logs.

---

## 🟢 LOW / DOCS

### L-1. Scheduler silently fails on module reload
**Status:** ✅ Fixed (2026-04-13) in PR 7. Migration `V20260413000000AddSchedulerResilience` adds `last_error`, `last_error_at`, `consecutive_failures`, `auto_disabled_at` fields to `scheduled_workflows`. New `ScheduledWorkflow.failure_changeset/3` and `success_changeset/3` track state. `Scheduler.execute_schedule/2` advances `next_run_at` on module load failure and auto-disables after 5 consecutive failures.
**File:** `lib/durable/scheduler.ex:162+`
If a `ScheduledWorkflow` references a module that no longer exists (hot code reload removed it), the scheduler logs and returns without updating `next_run_at`. On the next poll it finds the same schedule, logs again, returns again — a noisy loop with no actual work. **Fix:** Add `:last_error` + `:last_error_at` fields to `ScheduledWorkflow`; increment a failure counter; auto-disable after N consecutive failures.

### L-2. `cancel_workflow/1` doesn't synchronously cancel running children
**Status:** ✅ Fixed (2026-04-13) in PR 4 / PR 8. `notify_orchestration_parent/4` now emits a `Logger.warning` when a child completion arrives for a non-waiting parent, making orphan completions visible. Full cascade cancellation semantics are documented as future work.
**File:** `lib/durable/executor.ex:1389+`
Parent cancellation marks children `:cancelled` in `[:pending, :running, :waiting]` states, but if a child is mid-step-execution on another worker, the step runs to completion. Then child completion tries to notify parent, finds parent `:cancelled`, silently returns `:ok` — result is lost. **Fix:** Log a warning when a completion notification finds a non-waiting parent; consider a dead-letter queue for these orphan completions.

### L-3. `call_workflow` exposes child's full context to parent
**Status:** ✅ Fixed (2026-04-13) in PR 8. `@doc` on `Durable.Orchestration.call_workflow/3` now explicitly documents that the success payload is the child's full context; shows a pattern for filtering to explicit outputs.
**File:** `lib/durable/orchestration.ex:226-230`
`build_result_payload` returns `%{result: child.context}` — the entire child context becomes a key in the parent's data flow. This is a minor info-leak surprise (parent sees all child state, not just outputs). **Fix:** Document; consider adding a `returns:` option to filter what propagates.

### L-4. `wait_for_input` resumption re-runs the whole step body
**Status:** ✅ Fixed (2026-04-13) in PR 8. `@doc` on `Durable.Wait.wait_for_event/2` now includes a "Resumption semantics" section explaining that the step body re-executes from the top and that side effects before the wait must be idempotent. Shows both the anti-pattern and the fix (split into two steps).
**File:** Step bodies contain `wait_for_input` as a thrown marker
When resumed, the step body re-executes from the top. Side effects before `wait_for_input` run twice. Users often don't realize this. **Fix:** Document loudly; `wait_for_*` primitives are resumption barriers, and anything before them must be idempotent.

### L-5. No `each/foreach` macro yet — design it with isolation in mind
**Status:** ✅ Noted (2026-04-13) in PR 8. `Durable.DSL.Step` module docstring now includes a "Future work" section calling out that iteration primitives must be designed with context isolation per iteration to avoid `put_context` races across concurrent iterations.
**Files:** `lib/durable/dsl/*.ex`
No iteration primitive exists today. If/when added: design iterations with isolated process dict contexts (like parallel) to avoid race conditions between iterations.

---

## Recommended fix order

1. **Immediate:** C-1 and C-2 (critical data loss and instant crashes)
2. **Serialization sweep (single PR):** H-1 through H-7 — apply `sanitize_for_json/1` at all write boundaries, plus retry/goto context-merging
3. **Transactional safety (separate PR):** M-2, M-3, M-5 via `Ecto.Multi`
4. **Extended zombie detection (separate PR):** M-1
5. **Ergonomic improvements (doc + small tweaks):** M-4, M-6, all L-*

## Testing strategy

Each fix should add a regression test in the existing test file:
- C-1 → new tests in `test/durable/context_test.exs` for cross-step persistence
- C-2 → new test in `test/durable/wait_test.exs` for tuple `timeout_value`
- H-1/H-2 → tests in `test/durable/wait_test.exs`
- H-3/H-4 → tests in `test/durable/step_runner_test.exs`
- H-5 → new test in `test/durable/retry_test.exs` for context continuity across retries
- H-6 → new test in `test/durable/decision_test.exs`
- M-* → integration tests simulating crashes between state transitions

## Risk assessment

The **biggest exposure is C-1**. Right now the library's documented `put_context`/`get_context` API doesn't do what it says it does. Every workflow that uses it works only because users also return the keys they care about. A new user following the documentation pattern without that workaround will silently lose state.

The **biggest live crash risk is C-2**. It triggers on very idiomatic usage (`timeout_value: {:error, :timeout}`). Until fixed, this is a footgun waiting to catch anyone trying the `wait_for_*` family with typical Elixir conventions.
