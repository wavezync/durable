defmodule Durable.Repo.Migrations.CreateScheduledWorkflows do
  use Ecto.Migration

  def change do
    create table(:scheduled_workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :workflow_module, :string, null: false
      add :workflow_name, :string, null: false
      add :cron_expression, :string, null: false
      add :timezone, :string, null: false, default: "UTC"
      add :input, :map, null: false, default: %{}
      add :queue, :string, null: false, default: "default"
      add :enabled, :boolean, null: false, default: true
      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scheduled_workflows, [:name])
    create index(:scheduled_workflows, [:enabled, :next_run_at])
  end
end
