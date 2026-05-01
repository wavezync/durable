defmodule Mix.Tasks.Durable.Migrations do
  @shortdoc "Displays Durable internal migration status"

  @moduledoc """
  Displays Durable's internal migration status for an Ecto repo.

  Use `--check` in CI or deploy gates to fail when the database is behind the
  Durable library version.

  ## Usage

      mix durable.migrations
      mix durable.migrations -r MyApp.Repo --check
      mix durable.migrations --prefix private
      mix durable.migrations --json

  ## Options

  * `-r`, `--repo` - The Ecto repo to inspect
  * `--prefix` - Durable PostgreSQL schema prefix (default: `"durable"`)
  * `--json` - Emit JSON instead of text
  * `--check` - Raise if any Durable migrations are pending
  """

  use Mix.Task

  import Mix.Ecto

  alias Durable.Migration

  @aliases [r: :repo]
  @switches [
    repo: [:string, :keep],
    prefix: :string,
    json: :boolean,
    check: :boolean,
    no_compile: :boolean,
    no_deps_check: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    repos = parse_repos!(args)
    {opts, _argv} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    reports = Enum.map(repos, &build_report(&1, args, opts))
    emit_reports(reports, opts)
    maybe_raise_for_pending(reports, opts)

    :ok
  end

  defp parse_repos!(args) do
    case parse_repo(args) do
      [] -> Mix.raise("Could not find an Ecto repo. Pass one with -r MyApp.Repo.")
      repos -> repos
    end
  end

  defp build_report(repo, args, opts) do
    ensure_repo(repo, args)
    prefix = Keyword.get(opts, :prefix, "durable")

    case Ecto.Migrator.with_repo(repo, &migration_status(&1, prefix), mode: :temporary) do
      {:ok, report, _started} ->
        report

      {:error, error} ->
        Mix.raise("Could not start repo #{inspect(repo)}, error: #{inspect(error)}")
    end
  end

  defp migration_status(repo, prefix) do
    current_version = Migration.current_version()
    migrated_version = Migration.migrated_version(repo, prefix: prefix)
    pending_versions = Migration.pending_versions(repo, prefix: prefix)

    %{
      repo: inspect(repo),
      prefix: prefix,
      current_version: current_version,
      migrated_version: migrated_version,
      pending_versions: pending_versions,
      status: status(pending_versions)
    }
  end

  defp status([]), do: "up"
  defp status(_pending_versions), do: "pending"

  defp emit_reports(reports, opts) do
    if Keyword.get(opts, :json, false) do
      emit_json(reports)
    else
      Enum.each(reports, &emit_text/1)
    end
  end

  defp emit_json([report]), do: Mix.shell().info(Jason.encode!(report, pretty: true))
  defp emit_json(reports), do: Mix.shell().info(Jason.encode!(reports, pretty: true))

  defp emit_text(report) do
    Mix.shell().info("""

    Repo: #{report.repo}
    Prefix: #{report.prefix}
    Current Durable version: #{report.current_version}
    Migrated database version: #{report.migrated_version}
    Pending versions: #{format_pending(report.pending_versions)}
    Status: #{report.status}
    """)
  end

  defp format_pending([]), do: "none"
  defp format_pending(versions), do: Enum.join(versions, ", ")

  defp maybe_raise_for_pending(reports, opts) do
    if Keyword.get(opts, :check, false) and Enum.any?(reports, &pending?/1) do
      Mix.raise(check_error(reports))
    end
  end

  defp pending?(report), do: report.pending_versions != []

  defp check_error(reports) do
    pending =
      reports
      |> Enum.filter(&pending?/1)
      |> Enum.map_join("\n", fn report ->
        "  #{report.repo} prefix=#{inspect(report.prefix)} pending=#{format_pending(report.pending_versions)}"
      end)

    """
    Durable migrations are pending:
    #{pending}

    Generate an upgrade migration with `mix durable.gen.upgrade -r YourApp.Repo`,
    then run `mix ecto.migrate`.
    """
  end
end
