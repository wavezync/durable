# Embeddable Library Transformation

## Overview

This topic covers the transformation of Durable from a standalone Elixir application into an embeddable library following the Oban pattern. Users can now add Durable to their existing application's supervision tree and use their own Ecto repo.

## Status

**Completed** - All implementation work finished, 80 tests passing, CI checks green.

## Quick Reference

### Installation Pattern

```elixir
# 1. Migration
defmodule MyApp.Repo.Migrations.AddDurable do
  use Ecto.Migration
  def up, do: Durable.Migration.up()
  def down, do: Durable.Migration.down()
end

# 2. Supervision tree
children = [
  MyApp.Repo,
  {Durable, repo: MyApp.Repo, queues: %{default: [concurrency: 10]}}
]

# 3. Usage
Durable.start(MyWorkflow, %{input: "data"})
```

### Key Files

| File | Purpose |
|------|---------|
| `lib/durable/config.ex` | Configuration validation and storage |
| `lib/durable/migration.ex` | Programmatic migrations |
| `lib/durable/supervisor.ex` | Main supervision tree entry point |

## Sessions

| Session | Date | Focus | Status |
|---------|------|-------|--------|
| [Session 1](./sessions/2026-01-02-session-01.md) | 2026-01-02 | Full implementation of embeddable pattern | Completed |

## Key Decisions

1. Dynamic repo via `Durable.Config.repo()` instead of hardcoded module
2. Schema prefix `"durable"` for PostgreSQL namespace isolation
3. Persistent term storage for fast configuration access
4. NimbleOptions for configuration validation
5. Programmatic migrations via `Durable.Migration.up()/down()`

## Related Files

- [Implementation Plan](./implementation-plan.md) - Detailed implementation steps and configuration reference
- `/Users/kasun/work/wavezync/durable/lib/durable/config.ex` - Configuration module
- `/Users/kasun/work/wavezync/durable/lib/durable/migration.ex` - Migration module
- `/Users/kasun/work/wavezync/durable/lib/durable/supervisor.ex` - Supervisor module

## Tags

`embedding`, `oban-pattern`, `configuration`, `supervision-tree`, `ecto`, `migrations`

---
*Maintained by conversation-archiver agent*
