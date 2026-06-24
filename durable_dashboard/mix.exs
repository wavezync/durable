defmodule DurableDashboard.MixProject do
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

  # Versioned independently of durable.
  @version "0.1.0-rc"

  @elixir_requirement Keyword.fetch!(shared, :elixir)
  @source_url Keyword.fetch!(shared, :source_url)
  @homepage_url Keyword.fetch!(shared, :homepage_url)
  @maintainers Keyword.fetch!(shared, :maintainers)
  @licenses Keyword.fetch!(shared, :licenses)

  def project do
    [
      app: :durable_dashboard,
      version: @version,
      elixir: @elixir_requirement,
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      name: "DurableDashboard",
      description: "Web dashboard for Durable workflow engine",
      source_url: @source_url,
      homepage_url: @homepage_url,
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
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The Hex version is the committed default, so a plain `mix deps.get` and
      # `mix hex.publish` resolve durable from Hex with no special steps. For
      # monorepo co-development, comment it and uncomment the path dep below.
      # Bump the requirement to the durable release this dashboard targets.
      # (Same toggle pattern as elixir-nx/nx's torchx.)
      {:durable, "~> 0.1.0-rc"},
      # {:durable, path: "../durable"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix, "~> 1.8"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup"],
      "assets.setup": ["cmd --cd assets pnpm install"],
      "assets.build": ["cmd --cd assets pnpm build"],
      # Formats + autofixes the React/TS island via Biome (biome check --write).
      "assets.format": ["cmd --cd assets pnpm lint:fix"],
      "assets.typecheck": ["cmd --cd assets pnpm typecheck"],
      "hex.build": ["assets.build", "hex.build"],
      "hex.publish": ["assets.build", "hex.publish"],
      # All formatting + checks, Elixir and frontend. `format` + `assets.format`
      # cover formatting (Elixir + TS); `assets.typecheck` is the JS-side static
      # check (this package has no credo dependency). Runs in :test env via cli/0.
      #
      # Ordering matters: the `assets.*` steps shell out via `mix cmd --cd assets`,
      # which shifts the VM's cwd. A `cmd` step interleaved between `compile` and
      # `test` breaks lazy loading of :jason for the test run, so we run all the
      # frontend (cmd) steps first and keep the Elixir `format → compile → test`
      # block contiguous and last.
      precommit: [
        "assets.format",
        "assets.typecheck",
        "format",
        "compile --warnings-as-errors",
        "test"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md"]
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
