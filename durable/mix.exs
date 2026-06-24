defmodule Durable.MixProject do
  use Mix.Project

  # Shared monorepo metadata. Canonical values live in ../shared.exs; Hex
  # tarballs can't reference files outside the package root, so we copy that
  # file next to this mix.exs (the copy is what ships) and read it back.
  # Edit ../shared.exs, never the git-ignored copy beside this file.
  shared_src = Path.join(__DIR__, "../shared.exs")
  shared_dst = Path.join(__DIR__, "shared.exs")

  if File.exists?(shared_src) and
       (not File.exists?(shared_dst) or File.read!(shared_dst) != File.read!(shared_src)) do
    File.cp!(shared_src, shared_dst)
  end

  {shared, _bindings} = Code.eval_file(shared_dst)

  # Versioned independently of durable_dashboard.
  @version "0.1.0-rc"
  @elixir_requirement Keyword.fetch!(shared, :elixir)
  @source_url Keyword.fetch!(shared, :source_url)
  @homepage_url Keyword.fetch!(shared, :homepage_url)
  @maintainers Keyword.fetch!(shared, :maintainers)
  @licenses Keyword.fetch!(shared, :licenses)

  def project do
    [
      app: :durable,
      version: @version,
      elixir: @elixir_requirement,
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      name: "Durable",
      homepage_url: @homepage_url,
      description: "A durable, resumable workflow engine for Elixir",
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Durable.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Core
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:nimble_options, "~> 1.1"},
      {:crontab, "~> 1.1"},
      {:igniter, "~> 0.6", optional: true},
      {:phoenix_pubsub, "~> 2.1", optional: true},

      # Dev/Test
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["format", "compile --warnings-as-errors", "credo --strict", "test"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/ai_workflows.md",
        "guides/branching.md",
        "guides/compensations.md",
        "guides/orchestration.md",
        "guides/parallel.md",
        "guides/waiting.md"
      ],
      groups_for_modules: [
        "Mix Tasks": [
          Mix.Tasks.Durable.Migrations,
          Mix.Tasks.Durable.Gen.Upgrade,
          Mix.Tasks.Durable.Status,
          Mix.Tasks.Durable.List,
          Mix.Tasks.Durable.Run,
          Mix.Tasks.Durable.Cancel,
          Mix.Tasks.Durable.Cleanup
        ]
      ]
    ]
  end

  defp package do
    [
      maintainers: @maintainers,
      licenses: @licenses,
      links: %{"GitHub" => @source_url, "Homepage" => @homepage_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE shared.exs)
    ]
  end
end
