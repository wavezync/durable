defmodule Durable.Repo.Migrations.CreateStepExecutions do
  use Ecto.Migration

  def change do
    create table(:step_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workflow_id, references(:workflow_executions, type: :binary_id, on_delete: :delete_all), null: false
      add :step_name, :string, null: false
      add :step_type, :string, null: false, default: "step"
      add :attempt, :integer, null: false, default: 1
      add :status, :string, null: false, default: "pending"
      add :input, :map
      add :output, :map
      add :error, :map
      add :logs, :jsonb, null: false, default: "[]"
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:step_executions, [:workflow_id, :step_name])
    create index(:step_executions, [:workflow_id, :status])
    create index(:step_executions, [:workflow_id, :attempt])

    execute(
      "CREATE INDEX step_executions_logs_gin ON step_executions USING GIN (logs)",
      "DROP INDEX step_executions_logs_gin"
    )
  end
end
