defmodule Durable.Repo.Migrations.CreatePendingInputs do
  use Ecto.Migration

  def change do
    create table(:pending_inputs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workflow_id, references(:workflow_executions, type: :binary_id, on_delete: :delete_all), null: false
      add :input_name, :string, null: false
      add :step_name, :string, null: false
      add :input_type, :string, null: false, default: "free_text"
      add :prompt, :text
      add :schema, :map
      add :fields, :jsonb
      add :status, :string, null: false, default: "pending"
      add :response, :jsonb
      add :timeout_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:pending_inputs, [:workflow_id, :input_name])
    create index(:pending_inputs, [:status, :timeout_at])
    create unique_index(:pending_inputs, [:workflow_id, :input_name], where: "status = 'pending'", name: :pending_inputs_workflow_input_pending_idx)
  end
end
