defmodule Durable.MigrationTest do
  use Durable.DataCase, async: false

  alias Durable.Migration
  alias Durable.Migration.Migrator

  test "current_version returns the latest registered migration version" do
    assert Migration.current_version() == List.last(Migration.all_versions())
  end

  test "previous_version returns the version before the target" do
    [first, second | _] = Migration.all_versions()

    assert Migration.previous_version(first) == 0
    assert Migration.previous_version(second) == first
    assert Migration.previous_version() == Enum.at(Migration.all_versions(), -2)
  end

  test "explicit repo helpers report default schema state" do
    assert Migration.migrated_version(Durable.TestRepo) == Migration.current_version()
    assert Migration.pending_versions(Durable.TestRepo) == []
  end

  test "explicit repo helpers report missing prefixes as unmigrated" do
    prefix = "durable_missing_#{System.unique_integer([:positive])}"

    assert Migration.migrated_version(Durable.TestRepo, prefix: prefix) == 0

    assert Migration.pending_versions(Durable.TestRepo, prefix: prefix) ==
             Migration.all_versions()
  end

  test "all migration files are registered with the migrator" do
    file_modules =
      "lib/durable/migration/migrations/v*.ex"
      |> Path.wildcard()
      |> Enum.map(&module_from_file!/1)
      |> Enum.sort()

    registered_modules =
      Migrator.all_migrations()
      |> Enum.map(fn {_version, mod} -> mod end)
      |> Enum.sort()

    assert registered_modules == file_modules
  end

  defp module_from_file!(path) do
    path
    |> File.read!()
    |> then(&Regex.run(~r/defmodule\s+([A-Za-z0-9_.]+)/, &1))
    |> case do
      [_match, module] -> String.to_existing_atom("Elixir." <> module)
      nil -> flunk("Expected #{path} to define a module")
    end
  end
end
