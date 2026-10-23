# M08: Workflow Versioning

**Status:** In Progress (phase 1 done, phase 2 needs the open questions answered)
**Priority:** High
**Effort:** 1 week
**Dependencies:** None

## Motivation

A deploy changes the workflow code under runs that are still in flight. Today a
run resumes against whatever definition is deployed, matched to its position by
step name. Whether that's safe depends on the change:

| Change | In-flight run today |
|--------|---------------------|
| Edit a step body | Runs the new body. Usually what you want (bug fixes). |
| Add a step after the run's position | Runs it. |
| Add a step before the run's position | Skips it. |
| Remove a later step | Skips it. |
| Rename or remove the step the run stopped at | **Was:** marked `completed`, every step after skipped, no error. **Now (phase 1):** fails with `definition_changed`. |
| Change a `parallel`/`branch` block's steps | The block's id is a hash of its shape, so its step names change: same as a rename. |
| A step expects context an earlier *new* step writes | Crashes at runtime, retried, fails. |

The silent `completed` was a data-loss bug and is fixed. The rest needs a way to
keep old runs on the old definition until they finish, which is what this
milestone adds.

## Scope

### In Scope

- Phase 1 (done): a run whose current step no longer exists fails with
  `%{type: "definition_changed"}` and no compensations, so it stays retryable
  once the step is restored.
- Phase 2: explicit versions. Several definitions of one workflow side by side;
  each run pinned to the version it started on.
- A way to see which versions still have runs in flight, so old code can be
  deleted safely.

### Out of Scope

- Replay-based patching (Temporal's `patched?`). Durable checkpoints steps
  rather than replaying history, so there's nothing to keep deterministic.
- Automatic versions from a structural hash. Every change would make a new
  version, including the safe ones above, and old definitions still have to
  stay in the code to be run.
- Migrating a run from one version to another (moving its position by hand).

## Architecture & Design

### API

```elixir
defmodule MyApp.OrderWorkflow do
  use Durable

  # Runs started before v2 shipped finish on this. Delete it once
  # `mix durable.status` shows none left.
  workflow "order", version: 1 do
    step :reserve, ...
    step :approve, ...
    step :ship, ...
  end

  workflow "order", version: 2 do
    step :reserve, ...
    step :review, ...
    step :ship, ...
  end
end
```

- `version:` is a positive integer workflow option, default `1`. Every workflow
  written so far is version 1, which matches every existing run.
- Two `workflow` blocks with the same name and version fail the compile.
- `Durable.start/3`, `call_workflow`, and schedules start the highest version.
  `Durable.start(mod, input, version: 1)` picks one explicitly (for tests of the
  old path).
- `workflow_version/0` (in `Durable.Context`) returns the run's version, so one
  definition can branch on it for small differences instead of being copied.

### Storage

- New column `workflow_executions.workflow_version integer NOT NULL DEFAULT 1`
  (a new migration, shipped through `mix durable.gen.upgrade`). The default
  covers existing rows.
- Index `(workflow_module, workflow_name, workflow_version) WHERE status IN
  (pending, running, waiting)` for the in-flight report.

### Resolution

- `__workflow_definition__(name)` keeps returning the latest version (the
  dashboard and `Durable.Scheduler` rely on it);
  `__workflow_definition__(name, version)` returns one version, and
  `__workflow_versions__(name)` lists them.
- The executor resolves `(module, name, version)`. A version that's gone fails
  the run with `definition_changed`, like a missing step.
- Parallel children copy the parent's version. A `call_workflow` child is a new
  run and starts the callee's latest version.

### Visibility

- `Durable.Query.list_executions(version: 1)`.
- `mix durable.status` shows in-flight runs per version.
- Dashboard: the version on the run page; per-version in-flight counts on the
  workflow page.
- Telemetry: `:workflow_version` in run metadata (adding keys is allowed by the
  telemetry contract).

## Implementation Plan

1. ~~Phase 1: fail on a missing current step~~ (done in this branch).
2. DSL: `version:` option, per-version definition functions, duplicate check,
   `__workflow_versions__/1`.
3. Migration, schema, executor resolution, start/call/schedule pick latest,
   parallel children inherit.
4. `workflow_version/0`, query filter, `mix durable.status`, telemetry.
5. Dashboard: version on the run page and in-flight counts per version.
6. Guide: "Changing workflows" — which changes are safe in place, when to add a
   version, how to retire one.

## Testing Strategy

- Two versions in one module: new runs start v2, a v1 run resumes and finishes
  on v1.
- A run whose version was deleted fails with `definition_changed`; restoring it
  and `Durable.retry/2` finishes the run.
- Parallel children run the parent's version.
- Existing rows (no version set) resolve as version 1.
- Duplicate `name`/`version` fails the compile.

## Acceptance Criteria

- [x] A deploy that removes a run's current step fails the run loudly and
      recoverably instead of completing it.
- [ ] A run always finishes on the version it started on, while that version is
      in the code.
- [ ] Operators can see which versions still have runs before deleting one.
- [ ] Upgrading from 1.x needs only `mix durable.gen.upgrade` and a migrate.

## Open Questions

1. **API shape:** several `workflow "order", version: N` blocks in one module
   (proposed), or one module per version (`MyApp.Order.V1`) tied together by a
   name?
2. **Release:** the new column means users must run a migration. Ship as 1.2.0
   with an upgrade note, as the migration tooling was built for, or hold for
   2.0?
3. **Missing version:** fail the run (proposed), or fall back to the latest
   version when the run's current step exists there too?

## References

- AWS Step Functions versions and aliases: executions are pinned to the version
  they started on.
- Restate deployments: old deployments keep serving in-flight invocations until
  they drain.
- `test/durable/definition_change_test.exs`: the phase 1 behaviour.
