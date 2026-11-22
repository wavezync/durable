defmodule Durable.Integration.Audit4ApiMigrationTest do
  @moduledoc """
  `Durable.Migration.up/1` and `down/1` run for real, in a schema of their own
  next to the suite's `durable` one: up twice, down, up again, part of the way
  down and back. Whatever the path, the tables, columns, indexes and
  constraints end up the same as a straight `up`.
  """
  use ExUnit.Case, async: false

  alias Durable.IntegrationRepo
  alias Durable.Migration

  @moduletag :integration
  @moduletag :capture_log
  @moduletag timeout: 120_000

  @prefix "audit4_api_migration"

  # Each step is its own host-app migration, as an app's would be.
  for {name, call} <- [
        {Up, quote(do: Migration.up(prefix: unquote(@prefix), log: false))},
        {Down, quote(do: Migration.down(prefix: unquote(@prefix), log: false))},
        {DownTwo, quote(do: Migration.down(prefix: unquote(@prefix), step: 2, log: false))},
        {DownToFirst,
         quote(
           do:
             Migration.down(
               prefix: unquote(@prefix),
               to: hd(Migration.all_versions()),
               log: false
             )
         )},
        {UpToThird,
         quote(
           do:
             Migration.up(
               prefix: unquote(@prefix),
               to: Enum.at(Migration.all_versions(), 2),
               log: false
             )
         )}
      ] do
    defmodule Module.concat(__MODULE__, name) do
      use Ecto.Migration

      def up, do: unquote(call)
      def down, do: :ok
    end
  end

  setup_all do
    start_supervised!(IntegrationRepo)
    :ok
  end

  setup do
    clean()
    on_exit(&clean/0)
  end

  defp clean do
    IntegrationRepo.query!("DROP SCHEMA IF EXISTS #{@prefix} CASCADE")
    IntegrationRepo.query!("DELETE FROM schema_migrations WHERE version >= 99990000000000")
  end

  # Runs one of the migrations above, each time as a new version.
  defp migrate(name) do
    version = 99_990_000_000_000 + System.unique_integer([:positive, :monotonic])
    :ok = Ecto.Migrator.up(IntegrationRepo, version, Module.concat(__MODULE__, name), log: false)
  end

  defp applied, do: Migration.migrated_version(IntegrationRepo, prefix: @prefix)

  # Everything the catalog says about a schema, with the schema's own name and
  # anything that depends on creation order taken out.
  defp shape(prefix) do
    columns =
      rows(
        """
        SELECT table_name, column_name, data_type, udt_name, is_nullable,
               coalesce(column_default, '')
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name <> 'durable_schema_migrations'
        ORDER BY 1, 2
        """,
        prefix
      )

    indexes =
      rows(
        """
        SELECT tablename, indexname, indexdef FROM pg_indexes
        WHERE schemaname = $1 AND tablename <> 'durable_schema_migrations'
        ORDER BY 1, 2
        """,
        prefix
      )

    constraints =
      rows(
        """
        SELECT rel.relname, con.conname, con.contype::text, pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = $1 AND rel.relname <> 'durable_schema_migrations'
        ORDER BY 1, 2
        """,
        prefix
      )

    %{columns: columns, indexes: indexes, constraints: constraints}
  end

  defp rows(sql, prefix) do
    for row <- IntegrationRepo.query!(sql, [prefix]).rows do
      Enum.map(row, &String.replace(to_string(&1), prefix <> ".", "SCHEMA."))
    end
  end

  defp schema_exists? do
    IntegrationRepo.query!("SELECT 1 FROM pg_namespace WHERE nspname = $1", [@prefix]).rows != []
  end

  test "a straight up builds what the suite's own schema has" do
    migrate(Up)

    assert applied() == Migration.current_version()
    assert Migration.pending_versions(IntegrationRepo, prefix: @prefix) == []

    built = shape(@prefix)
    assert built.columns != []
    assert built == shape("durable")
  end

  test "up twice changes nothing the second time" do
    migrate(Up)
    once = shape(@prefix)
    migrate(Up)

    assert shape(@prefix) == once
    assert applied() == Migration.current_version()
  end

  test "down takes everything away, twice over, and up brings it all back" do
    migrate(Up)
    built = shape(@prefix)

    migrate(Down)
    refute schema_exists?()
    assert applied() == 0

    migrate(Down)
    refute schema_exists?()

    assert Migration.pending_versions(IntegrationRepo, prefix: @prefix) ==
             Migration.all_versions()

    migrate(Up)
    assert shape(@prefix) == built
  end

  test "part of the way down and up again ends where a straight up does" do
    migrate(Up)
    built = shape(@prefix)
    versions = Migration.all_versions()

    migrate(DownTwo)
    assert applied() == Enum.at(versions, -3)
    assert shape(@prefix) != built

    migrate(Up)
    assert applied() == Migration.current_version()
    assert shape(@prefix) == built

    migrate(DownToFirst)
    assert applied() == hd(versions)

    migrate(UpToThird)
    assert applied() == Enum.at(versions, 2)

    migrate(Up)
    assert shape(@prefix) == built
  end

  test "none of it touched the suite's schema" do
    before = shape("durable")

    migrate(Up)
    migrate(DownTwo)
    migrate(Down)

    assert shape("durable") == before
    assert Migration.migrated_version(IntegrationRepo) == Migration.current_version()
  end
end
