defmodule Durable.Migration do
  @moduledoc """
  Migrations for Durable workflow engine.

  Durable requires several database tables to store workflow executions,
  step executions, pending inputs, and scheduled workflows.

  ## Usage

  Create a migration in your application:

      defmodule MyApp.Repo.Migrations.AddDurable do
        use Ecto.Migration

        def up, do: Durable.Migration.up()
        def down, do: Durable.Migration.down()
      end

  Then run the migration:

      mix ecto.migrate

  ## Options

  * `:prefix` - The PostgreSQL schema name (default: `"durable"`)
  * `:to` - Migrate up to a specific version (inclusive)
  * `:step` - Number of migrations to roll back (for down only)

  ## Examples

      # Default prefix - runs all pending migrations
      def up, do: Durable.Migration.up()

      # Custom prefix for isolation
      def up, do: Durable.Migration.up(prefix: "my_app_durable")

      # Rollback the last 2 migrations
      def down, do: Durable.Migration.down(step: 2)

  ## Version History

  Migration versions use timestamps (YYYYMMDDHHmmss format). Use
  `Durable.Migration.migrated_versions/1` to see applied migrations.

  * 20260103000000 - Initial schema with all core tables:
    * `workflow_executions` - Stores workflow instances with compensation support
    * `step_executions` - Stores step execution history including compensation steps
    * `pending_inputs` - Stores pending human-in-the-loop inputs
    * `scheduled_workflows` - Stores cron-scheduled workflow definitions

  """

  alias Durable.Migration.Migrator

  @doc """
  Runs all pending migrations up to the latest version.

  ## Options

  * `:prefix` - The PostgreSQL schema name (default: `"durable"`)
  * `:to` - Migrate up to a specific version (inclusive)
  * `:log` - Log level for migration output (default: `:info`)
  """
  @spec up(keyword()) :: :ok
  defdelegate up(opts \\ []), to: Migrator

  @doc """
  Rolls back migrations.

  ## Options

  * `:prefix` - The PostgreSQL schema name (default: `"durable"`)
  * `:to` - Rollback to a specific version (exclusive - keeps that version)
  * `:step` - Number of migrations to roll back (default: all)
  * `:log` - Log level for migration output (default: `:info`)
  """
  @spec down(keyword()) :: :ok
  defdelegate down(opts \\ []), to: Migrator

  @doc """
  Returns the list of all available migration versions.
  """
  @spec all_versions() :: [pos_integer()]
  defdelegate all_versions(), to: Migrator

  @doc """
  Returns the list of applied migration versions.

  Requires a repo connection to be available (called within an Ecto migration).
  """
  @spec migrated_versions(keyword()) :: [pos_integer()]
  defdelegate migrated_versions(opts \\ []), to: Migrator

  @doc """
  Returns pending migrations (not yet applied).
  """
  @spec pending_versions(keyword()) :: [pos_integer()]
  defdelegate pending_versions(opts \\ []), to: Migrator
end
