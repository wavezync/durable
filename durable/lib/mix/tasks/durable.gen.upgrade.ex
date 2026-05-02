defmodule Mix.Tasks.Durable.Gen.Upgrade do
  @shortdoc "Generates a host-app migration for pending Durable migrations"

  @moduledoc """
  Generates an Ecto migration that upgrades Durable's internal database schema.

  This is the host-application counterpart to `mix durable.gen.migration`.
  Durable migrations are explicit: when Durable adds new internal migrations,
  generate a new wrapper migration and run `mix ecto.migrate`.

  ## Usage

      mix durable.gen.upgrade
      mix durable.gen.upgrade -r MyApp.Repo
      mix durable.gen.upgrade --prefix private
      mix durable.gen.upgrade --to 20260413000000

  ## Options

  * `-r`, `--repo` - The Ecto repo to generate the migration for
  * `--prefix` - Durable PostgreSQL schema prefix (default: `"durable"`)
  * `--to` - Durable migration version to upgrade to (default: latest)
  * `--migrations-path` - Destination migrations path
  """

  use Mix.Task

  import Macro, only: [camelize: 1]
  import Mix.Ecto
  import Mix.EctoSQL
  import Mix.Generator

  alias Durable.Migration

  @aliases [r: :repo]
  @switches [
    repo: [:string, :keep],
    prefix: :string,
    to: :integer,
    migrations_path: :string,
    no_compile: :boolean,
    no_deps_check: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    repos = parse_repos!(args)
    {opts, _argv} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    Enum.map(repos, fn repo ->
      ensure_repo(repo, args)
      generate(repo, opts)
    end)
  end

  defp parse_repos!(args) do
    case parse_repo(args) do
      [] -> Mix.raise("Could not find an Ecto repo. Pass one with -r MyApp.Repo.")
      repos -> repos
    end
  end

  defp generate(repo, opts) do
    target_version = target_version!(opts)
    prefix = Keyword.get(opts, :prefix, "durable")
    previous_version = Migration.previous_version(target_version)
    path = Keyword.get(opts, :migrations_path) || Path.join(source_repo_priv(repo), "migrations")
    base_name = "upgrade_durable_to_v#{target_version}"
    file = Path.join(path, "#{timestamp()}_#{base_name}.exs")

    unless File.dir?(path), do: create_directory(path)
    ensure_unique!(path, base_name)

    create_file(
      file,
      migration_template(repo, target_version, previous_version, prefix, base_name)
    )

    Mix.shell().info("""

    Run `mix ecto.migrate` to apply Durable migrations up to #{target_version}.
    """)

    file
  end

  defp target_version!(opts) do
    target_version = Keyword.get(opts, :to, Migration.current_version())

    if target_version in Migration.all_versions() do
      target_version
    else
      Mix.raise(
        "Unknown Durable migration version #{inspect(target_version)}. " <>
          "Known versions: #{Enum.join(Migration.all_versions(), ", ")}"
      )
    end
  end

  defp ensure_unique!(path, base_name) do
    fuzzy_path = Path.join(path, "*_#{base_name}.exs")

    if Path.wildcard(fuzzy_path) != [] do
      Mix.raise("migration can't be created, there is already a migration file for #{base_name}.")
    end
  end

  defp migration_template(repo, target_version, previous_version, prefix, base_name) do
    module_name = Module.concat([repo, Migrations, camelize(base_name)])

    """
    defmodule #{inspect(module_name)} do
      use Ecto.Migration

      def up do
        Durable.Migration.up(to: #{target_version}, prefix: #{inspect(prefix)})
      end

      def down do
        Durable.Migration.down(to: #{previous_version}, prefix: #{inspect(prefix)})
      end
    end
    """
  end

  defp timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()

    "#{year}" <>
      pad(month) <>
      pad(day) <>
      pad(hour) <>
      pad(minute) <>
      pad(second)
  end

  defp pad(value) when value < 10, do: "0#{value}"
  defp pad(value), do: to_string(value)
end
