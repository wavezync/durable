defmodule Durable.Migration.Migrations.V20261016000000AddOperatorControls do
  @moduledoc false
  # Operator controls for 1.0:
  #
  # * `workflow_executions.retried_at` — when `Durable.retry/2` last resumed a
  #   failed run. Step attempts are counted from here, so a retried step gets
  #   its full `max_attempts` budget again.
  # * `workflow_executions.trigger` / `trigger_ref` — what started the run
  #   (api | schedule | parent | rerun) and what it points at (the schedule
  #   name, or the run being re-run).
  # * `queues` — cluster-wide pause state, checked by every node's claim query.
  # * `nodes` — one heartbeat row per running Durable instance.
  # * Time indexes for dashboard ranges ("last 24h") and the retention pruner.
  #   Plain CREATE INDEX: on very large tables expect a write lock while they
  #   build, or create them CONCURRENTLY by hand before upgrading.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_016_000_000

  @impl true
  def up(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      add_if_not_exists(:retried_at, :utc_datetime_usec)
      add_if_not_exists(:trigger, :string)
      add_if_not_exists(:trigger_ref, :string)
    end

    create_if_not_exists table(:queues, primary_key: false, prefix: prefix) do
      add(:name, :string, primary_key: true)
      add(:paused_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create_if_not_exists table(:nodes, primary_key: false, prefix: prefix) do
      add(:id, :string, primary_key: true)
      add(:queues, {:array, :string}, null: false, default: [])
      add(:version, :string)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:heartbeat_at, :utc_datetime_usec, null: false)
    end

    create_if_not_exists(index(:workflow_executions, [:inserted_at], prefix: prefix))

    create_if_not_exists(
      index(:workflow_executions, [:workflow_name, :inserted_at], prefix: prefix)
    )

    create_if_not_exists(index(:workflow_executions, [:status, :completed_at], prefix: prefix))
    create_if_not_exists(index(:step_executions, [:inserted_at], prefix: prefix))

    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(index(:step_executions, [:inserted_at], prefix: prefix))
    drop_if_exists(index(:workflow_executions, [:status, :completed_at], prefix: prefix))
    drop_if_exists(index(:workflow_executions, [:workflow_name, :inserted_at], prefix: prefix))
    drop_if_exists(index(:workflow_executions, [:inserted_at], prefix: prefix))
    drop_if_exists(table(:nodes, prefix: prefix))
    drop_if_exists(table(:queues, prefix: prefix))

    alter table(:workflow_executions, prefix: prefix) do
      remove_if_exists(:trigger_ref, :string)
      remove_if_exists(:trigger, :string)
      remove_if_exists(:retried_at, :utc_datetime_usec)
    end

    :ok
  end
end
