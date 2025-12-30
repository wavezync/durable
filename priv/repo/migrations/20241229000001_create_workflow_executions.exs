defmodule Durable.Repo.Migrations.CreateWorkflowExecutions do
  use Ecto.Migration

  def change do
    create table(:workflow_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workflow_module, :string, null: false
      add :workflow_name, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :queue, :string, null: false, default: "default"
      add :priority, :integer, null: false, default: 0
      add :input, :map, null: false, default: %{}
      add :context, :map, null: false, default: %{}
      add :current_step, :string
      add :error, :map
      add :parent_workflow_id, references(:workflow_executions, type: :binary_id, on_delete: :nilify_all)
      add :scheduled_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :locked_by, :string
      add :locked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_executions, [:status])
    create index(:workflow_executions, [:queue, :status, :priority, :scheduled_at])
    create index(:workflow_executions, [:workflow_module, :status])
    create index(:workflow_executions, [:locked_by, :locked_at])
    create index(:workflow_executions, [:parent_workflow_id])
  end
end
