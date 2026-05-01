defmodule Mix.Tasks.Durable.MigrationsTest do
  use Durable.DataCase, async: false

  alias Durable.Migration
  alias Durable.Migration.SchemaMigration
  alias Mix.Tasks.Durable.Migrations, as: MigrationsTask

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "reports the default schema as migrated" do
    assert :ok = MigrationsTask.run(["-r", "Durable.TestRepo"])

    output = collect_all_output()
    assert output =~ "Repo: Durable.TestRepo"
    assert output =~ "Current Durable version: #{Migration.current_version()}"
    assert output =~ "Migrated database version: #{Migration.current_version()}"
    assert output =~ "Pending versions: none"
    assert output =~ "Status: up"
  end

  test "emits JSON status" do
    assert :ok = MigrationsTask.run(["-r", "Durable.TestRepo", "--json"])

    output = collect_all_output()
    decoded = Jason.decode!(output)

    assert decoded["repo"] == "Durable.TestRepo"
    assert decoded["prefix"] == "durable"
    assert decoded["current_version"] == Migration.current_version()
    assert decoded["migrated_version"] == Migration.current_version()
    assert decoded["pending_versions"] == []
    assert decoded["status"] == "up"
  end

  test "--check passes when no Durable migrations are pending" do
    assert :ok = MigrationsTask.run(["-r", "Durable.TestRepo", "--check"])
  end

  test "--check raises when Durable migrations are pending" do
    prefix = unique_prefix("missing")

    assert_raise Mix.Error, ~r/Durable migrations are pending/, fn ->
      MigrationsTask.run(["-r", "Durable.TestRepo", "--prefix", prefix, "--check"])
    end
  end

  test "reports partially migrated prefixes" do
    prefix = unique_prefix("partial")
    [applied | pending] = Migration.all_versions()

    create_schema(prefix)
    SchemaMigration.ensure_table!(Durable.TestRepo, prefix)
    insert_schema_version(prefix, applied)

    assert :ok = MigrationsTask.run(["-r", "Durable.TestRepo", "--prefix", prefix])

    output = collect_all_output()
    assert output =~ "Migrated database version: #{applied}"
    assert output =~ "Pending versions: #{Enum.join(pending, ", ")}"
    assert output =~ "Status: pending"
  end

  defp unique_prefix(label) do
    "durable_#{label}_#{System.unique_integer([:positive])}"
  end

  defp create_schema(prefix) do
    Durable.TestRepo.query!("CREATE SCHEMA IF NOT EXISTS #{prefix}", [])
  end

  defp insert_schema_version(prefix, version) do
    Durable.TestRepo.query!(
      "INSERT INTO #{prefix}.durable_schema_migrations (version, inserted_at) VALUES ($1, $2)",
      [version, DateTime.utc_now()]
    )
  end

  defp collect_all_output do
    collect_all_output("")
  end

  defp collect_all_output(acc) do
    receive do
      {:mix_shell, :info, [line]} -> collect_all_output(acc <> "\n" <> line)
      {:mix_shell, :error, [line]} -> collect_all_output(acc <> "\n" <> line)
    after
      100 -> String.trim(acc)
    end
  end
end
