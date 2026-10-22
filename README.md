# Durable

[![CI](https://github.com/wavezync/durable/actions/workflows/ci.yml/badge.svg)](https://github.com/wavezync/durable/actions/workflows/ci.yml)
[![durable on Hex](https://img.shields.io/hexpm/v/durable.svg?label=durable)](https://hex.pm/packages/durable)
[![durable_dashboard on Hex](https://img.shields.io/hexpm/v/durable_dashboard.svg?label=durable_dashboard)](https://hex.pm/packages/durable_dashboard)
[![Docs](https://img.shields.io/badge/docs-durable.wavezync.com-ffc27a)](https://durable.wavezync.com/docs/)
[![License](https://img.shields.io/hexpm/l/durable.svg)](LICENSE)

Durable, reliable, resumable workflows for Elixir. Write workflows as plain
steps; every step is saved, so runs resume after crashes, deploys and long
waits.

- **Docs, guides and interactive examples:** [durable.wavezync.com](https://durable.wavezync.com)
- **API reference:** [durable](https://hexdocs.pm/durable) and [durable_dashboard](https://hexdocs.pm/durable_dashboard) on HexDocs

## Workspace

This is a path-dep monorepo (pnpm-workspaces style) containing the Durable
workflow engine and its surrounding packages. Each subdirectory is an
independent Mix project with its own `mix.exs`, `_build/`, `deps/`, and Hex
publishing pipeline.

## Packages

| Path | Package | Version | Docs | Description |
| --- | --- | --- | --- | --- |
| [`durable/`](durable/) | `:durable` | [![Hex](https://img.shields.io/hexpm/v/durable.svg)](https://hex.pm/packages/durable) | [HexDocs](https://hexdocs.pm/durable) | Core workflow engine — resumable, reliable workflows with PostgreSQL persistence. |
| [`durable_dashboard/`](durable_dashboard/) | `:durable_dashboard` | [![Hex](https://img.shields.io/hexpm/v/durable_dashboard.svg)](https://hex.pm/packages/durable_dashboard) | [HexDocs](https://hexdocs.pm/durable_dashboard) | LiveView-first web dashboard for monitoring and managing Durable workflows. |
| [`examples/phoenix_demo/`](examples/phoenix_demo/) | (unpublished) | | | Reference Phoenix app wiring up `:durable` and `:durable_dashboard`. |
| [`site/`](site/) | (unpublished) | | [durable.wavezync.com](https://durable.wavezync.com) | [durable.wavezync.com](https://durable.wavezync.com): Astro site. Its docs are the packages' own markdown, read in place (`site/src/docs.ts`). `cd site && pnpm install && pnpm dev` |

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

`durable_dashboard` depends on `{:durable, "~> 1.0"}` from Hex, which is what
it ships with. To build it against the local checkout, set `DURABLE_PATH`:

```bash
cd durable_dashboard && DURABLE_PATH=../durable mix test
```

The workspace commands and CI set it for you.

## Releasing

Each package is released on its own from GitHub Actions: **Actions → Release →
Run workflow**, then pick the package. Leave the version blank to take the
next one [git-cliff](https://git-cliff.org) derives from the package's
conventional commits since its last tag, or enter one. The workflow:

1. bumps `@version`, regenerates the package's `CHANGELOG.md` (config in
   [`cliff.toml`](cliff.toml)), commits both to `main`, and tags
   `durable-v<version>` or `durable_dashboard-v<version>`;
2. publishes to Hex with the `HEX_API_KEY` repository secret;
3. creates the GitHub release, with that version's changelog as its notes.

If publishing fails, run Release again with the same version: it reuses the
tag and skips whatever already went out. Release
`durable` first when the dashboard needs its changes: the dashboard is
published against durable from Hex.

Releases publish their HexDocs too. To fix docs without a release, run
**Actions → Docs**: it republishes a package's docs from `main` under its
current version.

Preview a changelog locally with
`git cliff --include-path "durable/**" --tag-pattern "^durable-v" --unreleased`.

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
