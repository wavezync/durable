# Durable workspace

This is a path-dep monorepo (pnpm-workspaces style) containing the Durable
workflow engine and its surrounding packages. Each subdirectory is an
independent Mix project with its own `mix.exs`, `_build/`, `deps/`, and Hex
publishing pipeline.

## Packages

| Path | Package | Description |
| --- | --- | --- |
| [`durable/`](durable/) | `:durable` | Core workflow engine — resumable, reliable workflows with PostgreSQL persistence. |
| [`durable_dashboard/`](durable_dashboard/) | `:durable_dashboard` | LiveView-first web dashboard for monitoring and managing Durable workflows. |
| [`examples/phoenix_demo/`](examples/phoenix_demo/) | (unpublished) | Reference Phoenix app wiring up `:durable` and `:durable_dashboard`. |

## Workspace commands

A thin root `mix.exs` fans out common commands to each published package:

```bash
mix setup       # mix deps.get in durable/, then durable_dashboard/
mix compile     # compile both
mix test        # run both test suites
mix format      # format both projects
mix precommit   # run each project's precommit alias
```

`examples/phoenix_demo` is intentionally outside the fan-out — it's an
integration sample, not a published package, and uses its own DB on port
`53412`. Run it directly via `cd examples/phoenix_demo && mix ...`.

## Working in a single package

Each package is a normal Mix project. From inside any subdirectory, the usual
commands work: `mix deps.get`, `mix compile`, `mix test`, `mix format`,
`mix credo --strict` (in `durable/`), `mix hex.publish`, etc.

## Cross-package references

Packages link to each other via `path:` deps in dev. To publish, swap the
`path:` line for the Hex version:

```elixir
# durable_dashboard/mix.exs
{:durable, path: "../durable"}      # dev
{:durable, "~> 0.1"}                # release
```

## Database

A shared `docker-compose.yml` at the workspace root brings up the Postgres
instance the core durable test suite expects (port `54321`):

```bash
docker compose up -d
```

The Phoenix demo runs against its own Postgres on port `53412`; see
[`examples/phoenix_demo/docker-compose.yml`](examples/phoenix_demo/docker-compose.yml).

## Layout reference

This layout is modeled on [`elixir-nx/nx`](https://github.com/elixir-nx/nx),
which uses the same path-dep + thin-coordinator pattern across `nx/`,
`exla/`, and `torchx/`.
