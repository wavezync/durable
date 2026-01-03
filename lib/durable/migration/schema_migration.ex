defmodule Durable.Migration.SchemaMigration do
  @moduledoc false
  # Internal module for tracking applied Durable migrations.
  # Stores version numbers in the `durable_schema_migrations` table.

  use Ecto.Migration

  alias Ecto.Migration.Runner

  @table_name "durable_schema_migrations"

  @doc """
  Ensures the schema migrations table exists.
  """
  @spec ensure_table!(String.t()) :: :ok
  def ensure_table!(prefix) do
    # Use direct repo query to ensure table is created immediately
    # (not deferred like Ecto.Migration's execute)
    query = """
    CREATE TABLE IF NOT EXISTS #{prefix}.#{@table_name} (
      version BIGINT PRIMARY KEY NOT NULL,
      inserted_at TIMESTAMP(6) WITHOUT TIME ZONE NOT NULL
    )
    """

    get_repo().query!(query, [])
    :ok
  end

  @doc """
  Checks if the migrations table exists.
  """
  @spec table_exists?(String.t()) :: boolean()
  def table_exists?(prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = $1
      AND table_name = $2
    )
    """

    %{rows: [[exists]]} = get_repo().query!(query, [prefix, @table_name])
    exists
  end

  @doc """
  Returns all recorded migration versions in ascending order.
  """
  @spec versions(String.t()) :: [pos_integer()]
  def versions(prefix) do
    if table_exists?(prefix) do
      query = "SELECT version FROM #{prefix}.#{@table_name} ORDER BY version"
      %{rows: rows} = get_repo().query!(query, [])
      Enum.map(rows, fn [v] -> v end)
    else
      []
    end
  end

  @doc """
  Records a migration version as applied.
  """
  @spec record_version(String.t(), pos_integer()) :: :ok
  def record_version(prefix, version) do
    now = DateTime.utc_now()

    query =
      "INSERT INTO #{prefix}.#{@table_name} (version, inserted_at) VALUES ($1, $2)"

    get_repo().query!(query, [version, now])
    :ok
  end

  @doc """
  Deletes a migration version record.
  """
  @spec delete_version(String.t(), pos_integer()) :: :ok
  def delete_version(prefix, version) do
    query = "DELETE FROM #{prefix}.#{@table_name} WHERE version = $1"
    get_repo().query!(query, [version])
    :ok
  end

  @doc """
  Drops the schema migrations table.
  """
  @spec drop_table(String.t()) :: :ok
  def drop_table(prefix) do
    drop_if_exists(table(@table_name, prefix: prefix))
    :ok
  end

  # Get repo from Ecto.Migration runner context
  defp get_repo do
    Runner.repo()
  end
end
