defmodule DurableDashboard.MixProject do
  use Mix.Project

  @version "0.0.0-alpha"
  @source_url "https://github.com/wavezync/durable"

  def project do
    [
      app: :durable_dashboard,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      name: "DurableDashboard",
      description: "Web dashboard for Durable workflow engine",
      source_url: @source_url,
      package: package()
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
      {:durable, path: "../durable"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix, "~> 1.8"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup"],
      "assets.setup": ["cmd --cd assets pnpm install"],
      "assets.build": ["cmd --cd assets pnpm build"],
      "hex.build": ["assets.build", "hex.build"],
      "hex.publish": ["assets.build", "hex.publish"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs)
    ]
  end
end
