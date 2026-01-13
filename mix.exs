defmodule Durable.MixProject do
  use Mix.Project

  @version "0.0.0-alpha"
  @source_url "https://github.com/wavezync/durable"
  @homepage_url "https://durable.wavezync.com"

  def project do
    [
      app: :durable,
      version: @version,
      elixir: "~> 1.15",
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
        "guides/foreach.md",
        "guides/parallel.md",
        "guides/waiting.md"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE)
    ]
  end
end
