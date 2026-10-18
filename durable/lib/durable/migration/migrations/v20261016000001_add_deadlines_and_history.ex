defmodule Durable.Migration.Migrations.V20261016000001AddDeadlinesAndHistory do
  @moduledoc false
  # * `workflow_executions.deadline_at` — when a run with a workflow `timeout:`
  #   must be finished by. Partial index: only runs that have one.
  # * `queue_samples` — one row per queue per minute (ready, scheduled, running,
  #   waiting), written by whichever node gets there first. Kept for a week.
  # * `activity` — operational events worth an operator's attention: recovered
  #   runs, fenced workers, failed acks, queue pauses, auto-disabled schedules,
  #   pruning. Kept for a week.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_016_000_001

  @impl true
  def up(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      add_if_not_exists(:deadline_at, :utc_datetime_usec)
    end

    create_if_not_exists(
      index(:workflow_executions, [:deadline_at],
        where: "deadline_at IS NOT NULL",
        prefix: prefix
      )
    )

    create_if_not_exists table(:queue_samples, primary_key: false, prefix: prefix) do
      add(:queue, :string, primary_key: true)
      add(:at, :utc_datetime, primary_key: true)
      add(:ready, :integer, null: false, default: 0)
      add(:scheduled, :integer, null: false, default: 0)
      add(:running, :integer, null: false, default: 0)
      add(:waiting, :integer, null: false, default: 0)
    end

    create_if_not_exists(index(:queue_samples, [:at], prefix: prefix))

    create_if_not_exists table(:activity, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:at, :utc_datetime_usec, null: false)
      add(:kind, :string, null: false)
      add(:node_id, :string)
      add(:queue, :string)
      add(:workflow_id, :binary_id)
      add(:count, :integer, null: false, default: 1)
      add(:details, :map, null: false, default: %{})
    end

    create_if_not_exists(index(:activity, [:at], prefix: prefix))

    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(table(:activity, prefix: prefix))
    drop_if_exists(table(:queue_samples, prefix: prefix))
    drop_if_exists(index(:workflow_executions, [:deadline_at], prefix: prefix))

    alter table(:workflow_executions, prefix: prefix) do
      remove_if_exists(:deadline_at, :utc_datetime_usec)
    end

    :ok
  end
end
