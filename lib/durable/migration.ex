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

  ## Examples

      # Default prefix
      def up, do: Durable.Migration.up()

      # Custom prefix for isolation
      def up, do: Durable.Migration.up(prefix: "my_app_durable")

  ## Version History

  * Version 1 - Initial schema with all core tables:
    * `workflow_executions` - Stores workflow instances
    * `step_executions` - Stores step execution history
    * `pending_inputs` - Stores pending human-in-the-loop inputs
    * `scheduled_workflows` - Stores cron-scheduled workflow definitions

  """

  use Ecto.Migration

  @current_version 1

  @doc """
  Returns the current migration version.
  """
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  Runs all migrations up to the current version.

  ## Options

  * `:prefix` - The PostgreSQL schema name (default: `"durable"`)
  * `:version` - The target version (default: current version)

  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    version = Keyword.get(opts, :version, @current_version)
    prefix = Keyword.get(opts, :prefix, "durable")

    for v <- 1..version do
      change(v, :up, prefix)
    end

    :ok
  end

  @doc """
  Rolls back all migrations down to version 0.

  ## Options

  * `:prefix` - The PostgreSQL schema name (default: `"durable"`)
  * `:version` - The target version to roll back to (default: 1, which drops all tables)

  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    version = Keyword.get(opts, :version, 1)
    prefix = Keyword.get(opts, :prefix, "durable")

    for v <- @current_version..version//-1 do
      change(v, :down, prefix)
    end

    :ok
  end

  # Version 1: Initial schema
  defp change(1, :up, prefix) do
    # Create schema first
    execute("CREATE SCHEMA IF NOT EXISTS #{prefix}")

    # workflow_executions table
    create table(:workflow_executions, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:workflow_module, :string, null: false)
      add(:workflow_name, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:queue, :string, null: false, default: "default")
      add(:priority, :integer, null: false, default: 0)
      add(:input, :map, null: false, default: %{})
      add(:context, :map, null: false, default: %{})
      add(:current_step, :string)
      add(:error, :map)

      add(
        :parent_workflow_id,
        references(:workflow_executions, type: :binary_id, on_delete: :nilify_all, prefix: prefix)
      )

      add(:scheduled_at, :utc_datetime_usec)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:locked_by, :string)
      add(:locked_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:workflow_executions, [:status], prefix: prefix))

    create(
      index(:workflow_executions, [:queue, :status, :priority, :scheduled_at], prefix: prefix)
    )

    create(index(:workflow_executions, [:workflow_module, :status], prefix: prefix))
    create(index(:workflow_executions, [:locked_by, :locked_at], prefix: prefix))
    create(index(:workflow_executions, [:parent_workflow_id], prefix: prefix))

    # step_executions table
    create table(:step_executions, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(
        :workflow_id,
        references(:workflow_executions,
          type: :binary_id,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:step_name, :string, null: false)
      add(:step_type, :string, null: false, default: "step")
      add(:attempt, :integer, null: false, default: 1)
      add(:status, :string, null: false, default: "pending")
      add(:input, :map)
      add(:output, :map)
      add(:error, :map)
      add(:logs, :jsonb, null: false, default: "[]")
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:duration_ms, :integer)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:step_executions, [:workflow_id, :step_name], prefix: prefix))
    create(index(:step_executions, [:workflow_id, :status], prefix: prefix))
    create(index(:step_executions, [:workflow_id, :attempt], prefix: prefix))

    execute(
      "CREATE INDEX step_executions_logs_gin ON #{prefix}.step_executions USING GIN (logs)",
      "DROP INDEX IF EXISTS #{prefix}.step_executions_logs_gin"
    )

    # pending_inputs table
    create table(:pending_inputs, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(
        :workflow_id,
        references(:workflow_executions,
          type: :binary_id,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:input_name, :string, null: false)
      add(:step_name, :string, null: false)
      add(:input_type, :string, null: false, default: "free_text")
      add(:prompt, :text)
      add(:schema, :map)
      add(:fields, :jsonb)
      add(:status, :string, null: false, default: "pending")
      add(:response, :jsonb)
      add(:timeout_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:pending_inputs, [:workflow_id, :input_name], prefix: prefix))
    create(index(:pending_inputs, [:status, :timeout_at], prefix: prefix))

    create(
      unique_index(
        :pending_inputs,
        [:workflow_id, :input_name],
        where: "status = 'pending'",
        name: :pending_inputs_workflow_input_pending_idx,
        prefix: prefix
      )
    )

    # scheduled_workflows table
    create table(:scheduled_workflows, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:workflow_module, :string, null: false)
      add(:workflow_name, :string, null: false)
      add(:cron_expression, :string, null: false)
      add(:timezone, :string, null: false, default: "UTC")
      add(:input, :map, null: false, default: %{})
      add(:queue, :string, null: false, default: "default")
      add(:enabled, :boolean, null: false, default: true)
      add(:last_run_at, :utc_datetime_usec)
      add(:next_run_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:scheduled_workflows, [:name], prefix: prefix))
    create(index(:scheduled_workflows, [:enabled, :next_run_at], prefix: prefix))
  end

  defp change(1, :down, prefix) do
    # Drop tables in reverse order (due to foreign keys)
    drop_if_exists(table(:scheduled_workflows, prefix: prefix))
    drop_if_exists(table(:pending_inputs, prefix: prefix))
    drop_if_exists(table(:step_executions, prefix: prefix))
    drop_if_exists(table(:workflow_executions, prefix: prefix))

    # Drop schema
    execute("DROP SCHEMA IF EXISTS #{prefix} CASCADE")
  end
end
