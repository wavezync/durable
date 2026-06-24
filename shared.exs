# Shared package metadata for the Durable monorepo.
#
# This is the single source of truth for the fields that every published
# package (durable, durable_dashboard) keeps identical: Elixir requirement,
# project URLs, maintainers and license. Each package versions independently,
# so `version` stays in its own mix.exs — it is deliberately NOT here.
#
# Hex tarballs cannot reference files outside a package's own root, so each
# package's mix.exs copies this file next to itself at build time and reads it
# back with Code.eval_file/1. The copy is what actually ships to hex.pm.
#
# Edit the values HERE. Never edit a per-package `shared.exs` — those copies
# are git-ignored and overwritten on every build.
[
  elixir: "~> 1.15",
  source_url: "https://github.com/wavezync/durable",
  homepage_url: "https://durable.wavezync.com",
  maintainers: ["WaveZync"],
  licenses: ["MIT"]
]
