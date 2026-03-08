# M03: Testing Framework

**Status:** Not Started
**Priority:** Medium
**Effort:** 1 week
**Dependencies:** None

## Motivation

Users need a clean, documented way to test their Durable workflows. Currently, the only reference is our internal `test/support/data_case.ex`. A public `Durable.TestCase` module with workflow-specific assertions and a testing guide will significantly lower the barrier for adoption and encourage test-driven workflow development.

## Scope

### In Scope

- `Durable.TestCase` module shipped as public API
- Workflow-specific assertion macros
- Synchronous workflow execution helper for tests
- `guides/testing.md` documentation
- Example test patterns for common scenarios

### Out of Scope

- Mock/stub framework for external services (users pick their own: Mox, Hammox, etc.)
- In-memory queue adapter (existing `queue_enabled: false` is sufficient for unit tests)
- Performance/load testing utilities

## Architecture & Design

### Module: `Durable.TestCase`

```elixir
defmodule Durable.TestCase do
  @moduledoc """
  Test helpers for Durable workflows.

  ## Usage

      defmodule MyApp.OrderWorkflowTest do
        use Durable.TestCase, repo: MyApp.Repo

        test "processes order successfully" do
          result = run_workflow_sync(OrderWorkflow, %{order_id: 123})
          assert result.status == :completed
          assert_step_completed(result, :charge_payment)
        end
      end
  """

  use ExUnit.CaseTemplate

  using opts do
    repo = Keyword.fetch!(opts, :repo)
    quote do
      import Durable.TestCase
      alias unquote(repo), as: TestRepo
    end
  end

  setup tags do
    # Sandbox setup (like DataCase)
    # Start Durable with queue_enabled: false
  end
end
```

### Key Functions

#### `run_workflow_sync/2,3`

Executes a workflow synchronously in the test process — no queue, no GenServer. Returns the final execution record.

```elixir
# Simple
result = run_workflow_sync(OrderWorkflow, %{order_id: 123})

# With options
result = run_workflow_sync(OrderWorkflow, %{order_id: 123},
  workflow: "process_order",
  timeout: 10_000
)
```

Implementation: calls `Durable.Executor.run/3` directly (bypassing the queue), then fetches the execution record. This is already how our internal tests work — we just wrap it with a clean API.

#### Assertion Macros

```elixir
# Assert workflow reached a terminal status
assert_workflow_completed(result)
assert_workflow_failed(result)
assert_workflow_cancelled(result)

# Assert specific step status
assert_step_completed(result, :step_name)
assert_step_failed(result, :step_name)

# Assert step executed N times (retries)
assert_step_attempts(result, :step_name, 3)

# Assert context contains expected values
assert_context(result, :key, expected_value)
assert_context(result, %{key1: val1, key2: val2})

# Assert workflow completed within duration
assert_completed_within(result, 5_000)  # ms
```

#### Event/Input Helpers

```elixir
# Provide input to a waiting workflow
provide_test_input(workflow_id, "approval", %{approved: true})

# Send event to a waiting workflow
send_test_event(workflow_id, "payment_confirmed", %{amount: 99})

# Assert workflow is waiting for specific input
assert_waiting_for_input(workflow_id, "approval")
assert_waiting_for_event(workflow_id, "payment_confirmed")
```

### Guide: `guides/testing.md`

Sections:
1. Setup — adding `Durable.TestCase` to test_helper.exs, repo config
2. Basic workflow testing — `run_workflow_sync`, assertions
3. Testing branches — verifying correct path taken
4. Testing parallel steps — checking results
5. Testing waits — providing input/events in tests
6. Testing retries — simulating failures with Mox
7. Testing compensation — verifying rollback behavior
8. Testing scheduled workflows — manual trigger API
9. Integration testing — with queue enabled
10. Best practices — isolation, determinism, avoiding flaky tests

## Implementation Plan

1. **Core TestCase module** — `lib/durable/test_case.ex`
   - `use ExUnit.CaseTemplate` with sandbox setup
   - `run_workflow_sync/2,3` — synchronous execution wrapper
   - Basic assertions: `assert_workflow_completed/1`, `assert_workflow_failed/1`

2. **Step assertions** — extend `lib/durable/test_case.ex`
   - `assert_step_completed/2`, `assert_step_failed/2`
   - `assert_step_attempts/3`
   - `assert_context/2,3`

3. **Wait/input helpers** — extend `lib/durable/test_case.ex`
   - `provide_test_input/3`, `send_test_event/3`
   - `assert_waiting_for_input/2`, `assert_waiting_for_event/2`

4. **Testing guide** — `guides/testing.md`
   - All sections listed above
   - Concrete code examples for each pattern
   - Reference to existing guides for workflow features

## Testing Strategy

- `test/durable/test_case_test.exs` — test the test helpers themselves:
  - `run_workflow_sync` with passing/failing workflows
  - Each assertion macro with positive and negative cases
  - Input/event helpers with waiting workflows
- Use simple test workflow modules defined in test support
- Verify helpful error messages when assertions fail

## Acceptance Criteria

- [ ] `Durable.TestCase` compiles and is usable with `use Durable.TestCase, repo: MyRepo`
- [ ] `run_workflow_sync/2` executes a workflow and returns execution record
- [ ] All assertion macros produce clear error messages on failure
- [ ] `provide_test_input/3` successfully resumes a waiting workflow
- [ ] `guides/testing.md` covers all listed sections with code examples
- [ ] `@moduledoc` on `Durable.TestCase` is comprehensive with examples
- [ ] Existing tests in `test/` still pass (no regressions)
- [ ] `mix credo --strict` passes

## Open Questions

- Should `run_workflow_sync` return a rich struct or the raw `%WorkflowExecution{}` schema?
- Should we provide a `Durable.TestCase.Factory` for creating test workflow executions?
- Do we need `assert_eventually` in TestCase, or is the existing `DataCase.assert_eventually` pattern sufficient?

## References

- `test/support/data_case.ex` — existing test helper pattern to extend
- `lib/durable/executor.ex` — direct execution API for `run_workflow_sync`
- `lib/durable/query.ex` — querying execution/step state for assertions
- `lib/durable/wait.ex` — input/event API for test helpers
- Oban's testing documentation — similar pattern for job testing
