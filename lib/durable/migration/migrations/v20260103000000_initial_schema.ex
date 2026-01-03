defmodule Durable.Migration.Migrations.V20260103000000InitialSchema do
  @moduledoc false
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_103_000_000

  @impl true
  def up(prefix) do
    create_workflow_executions_table(prefix)
    create_workflow_executions_indexes(prefix)
    create_step_executions_table(prefix)
    create_step_executions_indexes(prefix)
    create_pending_inputs_table(prefix)
    create_pending_inputs_indexes(prefix)
    create_scheduled_workflows_table(prefix)
    create_scheduled_workflows_indexes(prefix)
    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(table(:scheduled_workflows, prefix: prefix))
    drop_if_exists(table(:pending_inputs, prefix: prefix))
    drop_if_exists(table(:step_executions, prefix: prefix))
    drop_if_exists(table(:workflow_executions, prefix: prefix))
    :ok
  end

  # workflow_executions table
  defp create_workflow_executions_table(prefix) do
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

      # Compensation/Saga support
      add(:compensation_results, :jsonb, default: "[]")
      add(:compensated_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end
  end

  defp create_workflow_executions_indexes(prefix) do
    create(index(:workflow_executions, [:status], prefix: prefix))

    create(
      index(:workflow_executions, [:queue, :status, :priority, :scheduled_at], prefix: prefix)
    )

    create(index(:workflow_executions, [:workflow_module, :status], prefix: prefix))
    create(index(:workflow_executions, [:locked_by, :locked_at], prefix: prefix))
    create(index(:workflow_executions, [:parent_workflow_id], prefix: prefix))
  end

  # step_executions table
  defp create_step_executions_table(prefix) do
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

      # Compensation/Saga support
      add(:compensation_for, :string)
      add(:is_compensation, :boolean, default: false, null: false)

      timestamps(type: :utc_datetime_usec)
    end
  end

  defp create_step_executions_indexes(prefix) do
    create(index(:step_executions, [:workflow_id, :step_name], prefix: prefix))
    create(index(:step_executions, [:workflow_id, :status], prefix: prefix))
    create(index(:step_executions, [:workflow_id, :attempt], prefix: prefix))
    create(index(:step_executions, [:workflow_id, :is_compensation], prefix: prefix))

    execute(
      "CREATE INDEX step_executions_logs_gin ON #{prefix}.step_executions USING GIN (logs)",
      "DROP INDEX IF EXISTS #{prefix}.step_executions_logs_gin"
    )
  end

  # pending_inputs table
  defp create_pending_inputs_table(prefix) do
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
  end

  defp create_pending_inputs_indexes(prefix) do
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
  end

  # scheduled_workflows table
  defp create_scheduled_workflows_table(prefix) do
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
  end

  defp create_scheduled_workflows_indexes(prefix) do
    create(unique_index(:scheduled_workflows, [:name], prefix: prefix))
    create(index(:scheduled_workflows, [:enabled, :next_run_at], prefix: prefix))
  end
end
