# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  export: [
    locals_without_parens: [
      # Workflow DSL
      workflow: 2,
      workflow: 3,
      # Step DSL
      branch: 2,
      compensate: 2,
      compensate: 3,
      decision: 2,
      decision: 3,
      parallel: 1,
      parallel: 2,
      step: 2,
      step: 3
    ]
  ]
]
