# Each package has its own rules; this points an editor opened at the repo root
# at them, so the workflow DSL stays paren-free whichever folder is open.
[
  inputs: ["mix.exs", "shared.exs"],
  subdirectories: ["durable", "durable_dashboard", "examples/phoenix_demo"]
]
