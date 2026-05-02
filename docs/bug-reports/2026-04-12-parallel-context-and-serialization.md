# Bug Report: Parallel step context loss, tuple serialization, and zombie workflows

**Date:** 2026-04-12
**Severity:** High — multiple classes of bugs cause silent data corruption, cryptic errors, and unrecoverable stuck workflows
**Reproduction:** `examples/phoenix_demo` — onboarding workflow with parallel provisioning block

## Summary

Four related issues were discovered while building complex workflows for the `examples/phoenix_demo` app. They compound on each other: bug #1 triggers bug #3, which masks the root cause and leaves workflows in the zombie state described in bug #4. Bug #2 is triggered independently when users construct `parallel into:` callbacks.

Individually these are library footguns. Together they make parallel blocks dangerous to use without deep knowledge of the executor internals.

---

## Bug 1 — Parallel steps don't inherit parent workflow context

**Severity:** High (silent data loss)
**Status:** ✅ Fixed (2026-04-13) — `create_parallel_child/5` now copies the parent's accumulated context into the child execution, and `execute_parallel_step/3` merges it into the pipeline data before invoking `StepRunner.execute/4`. Context is a snapshot taken at spawn time — concurrent siblings still can't see each other's writes, which is intentional.
**File:** `lib/durable/executor.ex:785-825` (`execute_parallel_step/3`)

### Observed behaviour

```elixir
step :register_employee, fn data ->
  put_context(:employee_name, data["name"])  # Sets context on parent
  {:ok, %{name: data["name"]}}
end

parallel into: fn _ctx, results -> {:ok, results} end do
  step :setup_email, fn _data ->
    name = get_context(:employee_name)   # ← Returns nil!
    email = String.downcase(name) <> "@company.com"  # ← Crashes: String.downcase(nil)
    {:ok, %{email: email}}
  end
end
```

`get_context/1` inside a parallel step returns `nil` for keys that were set by previous non-parallel steps. The developer expects the context to flow through the pipeline — instead, parallel steps see an empty context.

### Root cause

Parallel steps execute as **separate child workflow executions** (separate DB rows, separate processes). In `execute_parallel_step/3`:

```elixir
# lib/durable/executor.ex:801
data = atomize_keys(execution.input)   # ← Only the workflow's INITIAL input
case StepRunner.execute(step_def, data, execution.id, config) do
```

And in `StepRunner.execute_with_retry/6` (line 56):
```elixir
Process.put(:durable_context, data)   # ← data here = parent's initial input, not accumulated context
```

The child execution is created with just the parent's initial input as its context — any `put_context/2` calls made by prior steps are lost.

### Proposed fix

When creating child executions for a parallel block, copy the parent's `execution.context` into the child's `context` field. In `execute_parallel_step/3`, load that context into the process dictionary before the step runs:

```elixir
# Merge parent context when spawning parallel children (at spawn time)
parent_context = parent_exec.context || %{}
child_context = Map.merge(parent_context, %{"__parallel_step" => step_name_str})

# In execute_parallel_step/3 before StepRunner.execute:
merged_data = Map.merge(atomize_keys(execution.context), atomize_keys(execution.input))
Process.put(:durable_context, merged_data)
```

### Test to add

```elixir
test "parallel steps can read context set by earlier steps" do
  {:ok, id} = Durable.start(ParallelContextWorkflow, %{"seed" => "hello"}, inline: true)
  execution = Durable.Query.get_execution(id)
  assert execution.status == :completed
  assert execution.context["seen_in_parallel"] == "hello"  # set by prior step, read inside parallel
end
```

---

## Bug 2 — Raw tuples in `parallel into:` results break JSON storage

**Severity:** High (workflow fails after parallel completes, may corrupt state)
**Status:** ✅ Fixed (2026-04-12) — `apply_parallel_into/3` now pre-serializes results via the existing `serialize_parallel_results/1` before calling the user's `into:` callback, so user code never sees raw tagged tuples.
**File:** `lib/durable/executor.ex:980` (`apply_parallel_into/3`)

### Observed behaviour

```elixir
parallel into: fn _ctx, results ->
  # results = %{setup_email: {:ok, %{...}}, setup_dev_tools: {:ok, %{...}}}
  {:ok, %{provisioning: "complete", results: results}}   # ← crashes when saved
end
```

The save to PostgreSQL fails with:
```
** (Protocol.UndefinedError) protocol Jason.Encoder not implemented for Tuple
Got value: {:ok, %{"domain" => "company.com", "email" => "..."}}
```

### Root cause

When there is **no** `into:` function, the library calls `serialize_parallel_results/1` (line 994) which correctly unwraps tagged tuples:

```elixir
defp serialize_parallel_results(results) do
  Map.new(results, fn {key, value} ->
    serialized_value =
      case value do
        {:ok, data} -> ["ok", data]
        {:error, reason} -> ["error", serialize_error_reason(reason)]
        other -> other
      end
    {serialized_key, serialized_value}
  end)
end
```

But when there **is** an `into:` function, raw tuples are passed straight to user code (line 980):

```elixir
defp apply_parallel_into(into_fn, base_ctx, results) when is_function(into_fn, 2) do
  into_fn.(base_ctx, results)   # ← results still contains tuples
```

If the user's callback returns those tuples (which is a natural thing to do — "just pass results through"), storage crashes later.

### Proposed fix

Pre-serialize results before passing to the user's callback. The callback should never receive raw Erlang tuples:

```elixir
defp apply_parallel_into(into_fn, base_ctx, results) when is_function(into_fn, 2) do
  safe_results = serialize_parallel_results(results)
  into_fn.(base_ctx, safe_results)
rescue
  ...
end
```

This is the same serialization the library already applies for the no-`into:` case. Users would then see `%{setup_email: ["ok", %{...}]}` — obviously not a tuple — and handle it with documented helpers (e.g. `Durable.parallel_ok?/1`).

### Test to add

```elixir
test "parallel into: callback receives JSON-safe results" do
  workflow = build_workflow_with_into(fn _ctx, results ->
    # User returns results directly — must not crash storage
    {:ok, %{results: results}}
  end)
  {:ok, id} = Durable.start(workflow, %{}, inline: true)
  execution = Durable.Query.get_execution(id)
  assert execution.status == :completed
end
```

---

## Bug 3 — Secondary encoding error hides the root cause

**Severity:** Medium (breaks debuggability)
**Status:** ✅ Fixed (2026-04-12) — `mark_failed/3` now runs errors through `sanitize_for_json/1` (recursive tuple/pid/function stringification) before persisting, with a try/rescue fallback that stores a minimal diagnostic if even the sanitized payload fails to save. Workflows can no longer get stuck because the error couldn't be recorded.
**File:** `lib/durable/executor.ex:1146` (`mark_failed/3`)

### Observed behaviour

When a step crashed (bug #1), the executor built an error map including stacktrace frames. Some of those frames referenced tuple patterns like `{:ok, ...}` as literal data. Saving that error record to PostgreSQL then crashed with a `Protocol.UndefinedError` — which was the error reported to the developer. The original `String.replace(nil, ...)` crash was never seen.

### Root cause

`mark_failed/3` does `Repo.update` with the raw error map:
```elixir
execution
|> WorkflowExecution.status_changeset(:failed, %{
  error: error,   # ← could contain anything
  ...
})
|> Repo.update(config)   # ← crashes if error contains tuple/pid/function
```

There is no sanitization before the error is persisted as JSONB.

### Proposed fix

Add a `sanitize_for_json/1` helper that recursively walks a term and replaces unencodable values with their `inspect/1` string form. Call it in `mark_failed/3` before the update. If the save still fails, fall back to storing a minimal `%{type: "serialization_error", message: Exception.message(e)}`.

```elixir
defp mark_failed(config, execution, error) do
  safe_error = sanitize_for_json(error)
  
  try do
    execution
    |> WorkflowExecution.status_changeset(:failed, %{
      error: safe_error,
      completed_at: DateTime.utc_now()
    })
    |> Ecto.Changeset.change(locked_by: nil, locked_at: nil)
    |> Repo.update(config)
  rescue
    e ->
      fallback = %{type: "unrecorded_error", message: Exception.message(e)}
      # ... retry with fallback
  end
  ...
end

defp sanitize_for_json(term) when is_tuple(term),
  do: term |> Tuple.to_list() |> sanitize_for_json()
defp sanitize_for_json(term) when is_map(term),
  do: Map.new(term, fn {k, v} -> {sanitize_key(k), sanitize_for_json(v)} end)
defp sanitize_for_json(term) when is_list(term),
  do: Enum.map(term, &sanitize_for_json/1)
defp sanitize_for_json(term) when is_atom(term) or is_binary(term) or is_number(term),
  do: term
defp sanitize_for_json(term), do: inspect(term)
```

### Test to add

```elixir
test "mark_failed survives unencodable error values" do
  error_with_tuple = %{
    type: "crash",
    details: {:some, "tuple"},   # Jason.Encoder chokes on this
    extra: [pid: self()]
  }

  {:ok, exec} = insert_running_workflow()
  assert {:error, _} = Executor.mark_failed(config, exec, error_with_tuple)

  reloaded = Repo.get(config, WorkflowExecution, exec.id)
  assert reloaded.status == :failed
  assert reloaded.error["type"] == "crash"                 # preserved
  assert is_binary(reloaded.error["details"])              # tuple stringified
end
```

---

## Bug 4 — Zombie workflows in `:waiting` with nothing to wait on

**Severity:** Medium (creates unrecoverable stuck state)
**Status:** ✅ Fixed (2026-04-13) — Added optional adapter callback `recover_zombie_workflows/2`. The Postgres implementation detects workflows in `:waiting` with no pending inputs/events whose last update is past the stale lock timeout, and marks them `:failed` with `error.type == "zombie_detected"`. `StaleJobRecovery.do_recovery/1` calls it after the regular stale-lock sweep, so the periodic recovery (default 60s) automatically surfaces stuck workflows. Emits `[:durable, :queue, :zombie_recovered]` telemetry.

### Observed behaviour

After bug #1 + bug #3, a workflow was left with:
- `status = :waiting`
- `locked_by` pointing to a dead worker
- `locked_at` timestamp from hours ago
- No rows in `pending_inputs` or `pending_events`
- `error = NULL` (because the error save itself crashed)

From the outside, the workflow looks like it is waiting for user input — but nothing can unblock it. The dashboard displays it as `Waiting` indefinitely. The stale-lock recovery eventually clears the lock but doesn't transition the status.

### Root cause

The workflow state machine assumes every `:waiting` status corresponds to a `PendingInput` or `PendingEvent` row. There is no integrity check that verifies the invariant.

### Proposed fix

Two parts:

**A. Prevent creation of zombies:** When `mark_failed/3` (or any terminal handler) crashes, the recovery code must still transition the workflow out of `:waiting` / `:running`. Bug #3's fix covers most of this.

**B. Detect existing zombies:** Extend the stale-job recovery (`lib/durable/queue/stale_job_recovery.ex`) to detect:

```
workflow.status = :waiting
AND (
  NOT EXISTS (SELECT 1 FROM pending_inputs
              WHERE workflow_id = workflow.id AND status = :pending)
  AND NOT EXISTS (SELECT 1 FROM pending_events
                  WHERE workflow_id = workflow.id AND status = :pending)
)
AND workflow.locked_at < now() - interval '1 stale_lock_timeout'
```

Transition these to `:failed` with a diagnostic error:
```elixir
%{
  type: "zombie_detected",
  message: "Workflow was in :waiting status with no pending inputs or events; likely crashed during state transition.",
  current_step: workflow.current_step,
  locked_at: workflow.locked_at
}
```

And emit a PubSub event so dashboards can highlight it.

### Test to add

```elixir
test "zombie workflow recovery fails stuck :waiting workflows with no pending inputs" do
  {:ok, exec} = create_workflow(status: :waiting, locked_at: long_ago())
  # No pending inputs/events inserted
  
  :ok = StaleJobRecovery.run(config)
  
  reloaded = Repo.get(config, WorkflowExecution, exec.id)
  assert reloaded.status == :failed
  assert reloaded.error["type"] == "zombie_detected"
end
```

---

## Cross-cutting: Developer-facing diagnostics

Even after fixing these bugs, similar issues will surface in the future. Two small investments pay off:

### Add compile-time warning when `get_context/1` is called inside a parallel step body

The DSL macro knows when it's inside a `parallel` block. If `get_context/1` is seen in the AST of a `step` inside `parallel`, emit a compile warning:

```
warning: get_context/1 inside a parallel step only sees context copied at spawn time;
  mutations made by other parallel siblings are not visible. Pass needed values via
  the step's `data` argument instead.
```

### Log the full error chain

When the executor catches and wraps errors, include the original exception as `original_error` so the developer sees both layers:

```elixir
rescue
  e ->
    {:error, %{
      type: "parallel_into_error",
      message: Exception.message(e),
      original_error: inspect(e),   # ← new
      stacktrace: Exception.format_stacktrace(__STACKTRACE__)
    }}
end
```

---

## Repro steps (end-to-end)

1. Check out `feat/dashboard` at commit with `examples/phoenix_demo/lib/phoenix_demo/workflows/onboarding_workflow.ex` pre-fix.
2. `cd examples/phoenix_demo && mix seed_workflows`
3. Open `/dashboard`, find the "employee_onboarding" workflow, submit the equipment form.
4. Observe: status flips to `waiting` at step `parallel_NNNN` and stays there.
5. Inspect with psql:
   ```
   SELECT status, current_step, locked_by, error
     FROM durable.workflow_executions
    WHERE id = '...';
   ```
   → `waiting`, `parallel_NNNN`, non-null stale lock, NULL error.
6. Find the original crash in server logs: `Protocol.UndefinedError ... not implemented for Tuple ... {:error, %{"message" => "no function clause matching in String.replace/4"}}`.

## Files to patch (priority order)

1. `lib/durable/executor.ex` — bugs #1, #2, #3 (parallel context, into pre-serialization, error sanitization)
2. `lib/durable/queue/stale_job_recovery.ex` — bug #4 (zombie detector)
3. `lib/durable/dsl/step.ex` — compile-time warning for `get_context` in parallel steps
4. `test/durable/executor_test.exs` — regression coverage for all four bugs
