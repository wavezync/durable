# M04: Documentation & Release

**Status:** Done
**Priority:** High
**Effort:** 1 week
**Dependencies:** M02, M03 (soft — can start without, but references their output)

## Motivation

Durable is feature-rich but lacks a Getting Started guide and isn't published to Hex. These are the two biggest blockers to external adoption. This milestone prepares the library for its first public release with proper documentation, package metadata, and a smooth onboarding experience.

## Scope

### In Scope

- `guides/getting_started.md` — step-by-step onboarding guide
- Verify all public modules have `@moduledoc`
- Update `mix.exs` `docs()` config for HexDocs (groups, extras, logo)
- Update `mix.exs` `package()` config for Hex publishing
- Changelog (CHANGELOG.md)
- Publish to Hex

### Out of Scope

- Marketing website or landing page
- Video tutorials
- Blog post (can be separate effort)
- API documentation rewrites (existing @moduledoc/@doc is good)

## Architecture & Design

### Getting Started Guide Structure

`guides/getting_started.md`:

1. **What is Durable?** — One-paragraph elevator pitch
2. **Installation** — Add dep, run `mix durable.install` or manual setup
3. **Your First Workflow** — Define a simple 3-step workflow
4. **Running Workflows** — `Durable.start/2`, checking status
5. **Adding Retries** — `retry:` option on a step
6. **Context Management** — `put_context`, `get_context`, `input()`
7. **Branching** — Simple `branch on:` example
8. **Waiting for Input** — Human-in-the-loop example
9. **Next Steps** — Links to other guides (parallel, orchestration, scheduling, etc.)

The guide should be completable in ~15 minutes and result in a working workflow.

### HexDocs Configuration

```elixir
# mix.exs
defp docs do
  [
    main: "getting-started",
    extras: [
      "guides/getting_started.md",
      "guides/branching.md",
      "guides/parallel.md",
      "guides/waiting.md",
      "guides/compensations.md",
      "guides/orchestration.md",
      "guides/ai_workflows.md",
      "guides/testing.md",          # From M03
      "CHANGELOG.md"
    ],
    groups_for_extras: [
      Guides: ~r/guides\/.*/,
      Changelog: ["CHANGELOG.md"]
    ],
    groups_for_modules: [
      "Core": [Durable, Durable.Context, Durable.Wait],
      "DSL": [Durable.DSL.Workflow, Durable.DSL.Step, Durable.DSL.TimeHelpers],
      "Orchestration": [Durable.Orchestration],
      "Scheduling": [Durable.Scheduler, Durable.Scheduler.DSL],
      "Queue": [Durable.Queue.Adapter, Durable.Queue.Manager],
      "Query": [Durable.Query],
      "Setup": [Durable.Migration, Durable.Supervisor, Durable.Config],
      "Testing": [Durable.TestCase]
    ]
  ]
end
```

### Package Configuration

```elixir
defp package do
  [
    name: "durable",
    description: "Durable workflow engine for Elixir — resumable, reliable workflows with retries, waits, and PostgreSQL persistence",
    licenses: ["MIT"],
    links: %{
      "GitHub" => "https://github.com/wavezync/durable"
    },
    files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md guides)
  ]
end
```

### Module Documentation Audit

Verify these public modules have clear `@moduledoc`:
- `Durable` (main API)
- `Durable.Context`
- `Durable.Wait`
- `Durable.DSL.Workflow`, `Durable.DSL.Step`, `Durable.DSL.TimeHelpers`
- `Durable.Orchestration`
- `Durable.Scheduler`, `Durable.Scheduler.DSL`
- `Durable.Queue.Adapter`, `Durable.Queue.Manager`
- `Durable.Query`
- `Durable.Migration`, `Durable.Supervisor`, `Durable.Config`

## Implementation Plan

1. **Getting Started guide** — `guides/getting_started.md`
   - Write complete walkthrough following structure above
   - Test every code example compiles/works

2. **Module documentation audit** — scan all `lib/durable/**/*.ex`
   - Verify `@moduledoc` exists on all public modules
   - Add missing docs, improve unclear ones
   - Ensure `@doc` on all public functions

3. **CHANGELOG.md** — root directory
   - Create initial changelog with current state as v0.1.0
   - Follow Keep a Changelog format

4. **Update mix.exs** — `mix.exs`
   - Add `docs()` configuration
   - Add `package()` configuration
   - Verify `ex_doc` is in deps

5. **Publish** — `mix hex.publish`
   - Test with `mix hex.publish --dry-run` first
   - Verify HexDocs renders correctly

## Testing Strategy

- No new automated tests (documentation-only milestone)
- Manual verification:
  - Follow Getting Started guide from scratch in a new project
  - Run `mix docs` and verify all pages render
  - Run `mix hex.publish --dry-run` to verify package
  - Check all guide code examples are accurate

## Acceptance Criteria

- [ ] `guides/getting_started.md` is a complete, followable onboarding guide
- [ ] All public modules have `@moduledoc`
- [ ] `mix docs` generates clean HexDocs with grouped modules and extras
- [ ] `CHANGELOG.md` exists with v0.1.0 entry
- [ ] `mix.exs` has complete `package()` and `docs()` config
- [ ] `mix hex.publish --dry-run` succeeds
- [ ] README.md links to HexDocs
- [ ] No broken links in generated docs

## Open Questions

- Version number: v0.1.0 (pre-release) or v1.0.0?
- License: MIT? Apache 2.0?
- Should we add a Livebook notebook as an interactive guide?

## References

- `mix.exs` — current project config
- `guides/` — existing 6 guides
- Existing `@moduledoc`/`@doc` across `lib/durable/`
- Oban's HexDocs — good example of library documentation structure
- `lib/mix/tasks/durable.install.ex` — install task that Getting Started references
