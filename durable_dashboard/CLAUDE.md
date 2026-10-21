# Durable Dashboard

Hex package providing the web dashboard for the Durable workflow engine.
Architecture: Plug.Router entry point → Phoenix Router → LiveView pages,
with a single ReactFlow island for the workflow graph view (mounted via a
`phx-hook`).

## Before changing any UI

Read `DESIGN.md` in this directory. It is the source of truth for colors,
typography, spacing, motion, status semantics, component primitives, and
composition patterns. New visual decisions are made *there*, then applied
in code — not the other way around.

If a needed pattern isn't in `DESIGN.md`, add it there in the same PR.

## Stateless visual components

Live in `lib/durable_dashboard/components/core.ex`:
`button, badge, status_pill, card, heading, code, kbd, relative_time,
icon, skeleton, empty_state, error_state`. Use these instead of
hand-rolling HTML — see `DESIGN.md` §5 for the API contract.

## Build & test

```bash
# Assets (use pnpm, not npm)
cd assets && pnpm install && pnpm build

# Type / lint / format checks
cd assets && pnpm exec tsc --noEmit && pnpm exec biome check src/

# Elixir (durable comes from Hex unless DURABLE_PATH points at a checkout)
export DURABLE_PATH=../durable
mix compile --warnings-as-errors
mix test
```

## Test DB

`mix test` needs Postgres: the page tests (`DurableDashboard.LiveCase`) mount
the real LiveViews against a Durable instance on `TestRepo` — the compose
Postgres on port `54321` (`docker compose up -d` in the repo root), database
`durable_dashboard_test`, created and migrated by `test_helper.exs`. Runs come
from `DurableDashboard.Fixtures` (real workflows, executed inline).

A page test that shows a real, unfixed bug is tagged `:known_bug` and
excluded; `mix test --only known_bug` runs them.

The Phoenix demo runs against port `53412`. See `examples/phoenix_demo` in the
repo root.
