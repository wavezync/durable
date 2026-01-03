defmodule Durable.Migration.Migrator do
  @moduledoc false
  # Core migration runner for Durable.
  # Handles applying and rolling back migrations with version tracking.

  use Ecto.Migration

  alias Durable.Migration.SchemaMigration
  alias Ecto.Migration.Runner

  require Logger

  # List of all migration modules in order.
  # When adding new migrations, append them to this list.
  @migrations [
    Durable.Migration.Migrations.V20260103000000InitialSchema,
    Durable.Migration.Migrations.V20260104000000AddWaitPrimitives
  ]

  @doc """
  Returns all available migration versions in ascending order.
  """
  @spec all_versions() :: [pos_integer()]
  def all_versions do
    @migrations
    |> Enum.map(& &1.version())
    |> Enum.sort()
  end

  @doc """
  Returns all migration modules with their versions.
  """
  @spec all_migrations() :: [{pos_integer(), module()}]
  def all_migrations do
    @migrations
    |> Enum.map(fn mod -> {mod.version(), mod} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc """
  Runs pending migrations up.

  ## Options

  * `:prefix` - The PostgreSQL schema name (default: "durable")
  * `:to` - Migrate up to a specific version (inclusive)
  * `:log` - Log level for migration output (default: :info)
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "durable")
    log_level = Keyword.get(opts, :log, :info)
    target_version = Keyword.get(opts, :to)
    repo = Runner.repo()

    # Ensure schema exists (use direct query, not deferred execute)
    repo.query!("CREATE SCHEMA IF NOT EXISTS #{prefix}", [])

    # Ensure schema_migrations table exists
    SchemaMigration.ensure_table!(prefix)

    # Get applied versions
    applied = SchemaMigration.versions(prefix)

    # Get pending migrations
    pending =
      all_migrations()
      |> Enum.reject(fn {version, _mod} -> version in applied end)
      |> filter_to_version(target_version, :up)

    if pending == [] do
      log(log_level, "Durable: No pending migrations")
    else
      run_pending_migrations(pending, prefix, log_level)
    end

    :ok
  end

  defp run_pending_migrations(pending, prefix, log_level) do
    Enum.each(pending, fn {version, mod} ->
      log(log_level, "Durable: Running migration #{version} #{inspect(mod)}")
      mod.up(prefix)
      SchemaMigration.record_version(prefix, version)
      log(log_level, "Durable: Completed migration #{version}")
    end)
  end

  @doc """
  Rolls back migrations.

  ## Options

  * `:prefix` - The PostgreSQL schema name (default: "durable")
  * `:to` - Rollback to a specific version (exclusive - keeps that version)
  * `:step` - Number of migrations to roll back (default: all)
  * `:log` - Log level for migration output (default: :info)
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "durable")
    log_level = Keyword.get(opts, :log, :info)
    target_version = Keyword.get(opts, :to)
    step = Keyword.get(opts, :step)

    # Get applied versions
    applied = SchemaMigration.versions(prefix)

    if applied == [] do
      log(log_level, "Durable: No migrations to roll back")
      :ok
    else
      run_rollback(applied, prefix, log_level, target_version, step)
    end
  end

  defp run_rollback(applied, prefix, log_level, target_version, step) do
    # Build rollback list (in reverse order)
    to_rollback =
      all_migrations()
      |> Enum.filter(fn {version, _mod} -> version in applied end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> filter_to_version(target_version, :down)
      |> take_step(step)

    # Run each rollback
    Enum.each(to_rollback, fn {version, mod} ->
      log(log_level, "Durable: Rolling back migration #{version} #{inspect(mod)}")
      mod.down(prefix)
      SchemaMigration.delete_version(prefix, version)
      log(log_level, "Durable: Rolled back migration #{version}")
    end)

    # Check if all migrations rolled back
    maybe_drop_schema(prefix, log_level)

    :ok
  end

  defp maybe_drop_schema(prefix, log_level) do
    remaining = SchemaMigration.versions(prefix)

    if remaining == [] do
      SchemaMigration.drop_table(prefix)
      execute("DROP SCHEMA IF EXISTS #{prefix} CASCADE")
      log(log_level, "Durable: Dropped schema #{prefix}")
    end
  end

  @doc """
  Returns applied migration versions.
  """
  @spec migrated_versions(keyword()) :: [pos_integer()]
  def migrated_versions(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "durable")
    SchemaMigration.versions(prefix)
  end

  @doc """
  Returns pending migration versions.
  """
  @spec pending_versions(keyword()) :: [pos_integer()]
  def pending_versions(opts \\ []) do
    applied = migrated_versions(opts)
    all_versions() -- applied
  end

  # Private helpers

  defp filter_to_version(migrations, nil, _direction), do: migrations

  defp filter_to_version(migrations, target, :up) do
    Enum.take_while(migrations, fn {version, _} -> version <= target end)
  end

  defp filter_to_version(migrations, target, :down) do
    Enum.take_while(migrations, fn {version, _} -> version > target end)
  end

  defp take_step(migrations, nil), do: migrations
  defp take_step(migrations, step), do: Enum.take(migrations, step)

  defp log(false, _msg), do: :ok
  defp log(nil, _msg), do: :ok
  defp log(level, msg), do: Logger.log(level, msg)
end
