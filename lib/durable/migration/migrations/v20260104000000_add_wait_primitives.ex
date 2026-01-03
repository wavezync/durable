defmodule Durable.Migration.Migrations.V20260104000000AddWaitPrimitives do
  @moduledoc false
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_104_000_000

  @impl true
  def up(prefix) do
    alter_pending_inputs(prefix)
    create_pending_events_table(prefix)
    create_pending_events_indexes(prefix)
    create_wait_groups_table(prefix)
    create_wait_groups_indexes(prefix)
    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(table(:wait_groups, prefix: prefix))
    drop_if_exists(table(:pending_events, prefix: prefix))
    remove_pending_inputs_columns(prefix)
    :ok
  end

  # Add new columns to pending_inputs for parallel/foreach support
  defp alter_pending_inputs(prefix) do
    alter table(:pending_inputs, prefix: prefix) do
      add_if_not_exists(:parallel_id, :integer)
      add_if_not_exists(:foreach_id, :integer)
      add_if_not_exists(:foreach_index, :integer)
      add_if_not_exists(:timeout_value, :jsonb)
      add_if_not_exists(:on_timeout, :string, default: "resume")
      add_if_not_exists(:metadata, :jsonb)
    end
  end

  defp remove_pending_inputs_columns(prefix) do
    alter table(:pending_inputs, prefix: prefix) do
      remove_if_exists(:parallel_id, :integer)
      remove_if_exists(:foreach_id, :integer)
      remove_if_exists(:foreach_index, :integer)
      remove_if_exists(:timeout_value, :jsonb)
      remove_if_exists(:on_timeout, :string)
      remove_if_exists(:metadata, :jsonb)
    end
  end

  # pending_events table for wait_for_event support
  defp create_pending_events_table(prefix) do
    create table(:pending_events, primary_key: false, prefix: prefix) do
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

      add(:event_name, :string, null: false)
      add(:step_name, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:payload, :jsonb)
      add(:timeout_at, :utc_datetime_usec)
      add(:timeout_value, :jsonb)

      # For wait_for_any / wait_for_all patterns
      add(:wait_group_id, :binary_id)
      add(:wait_type, :string, null: false, default: "single")

      # For parallel/foreach context
      add(:parallel_id, :integer)
      add(:foreach_id, :integer)
      add(:foreach_index, :integer)

      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end
  end

  defp create_pending_events_indexes(prefix) do
    create(index(:pending_events, [:workflow_id, :event_name], prefix: prefix))
    create(index(:pending_events, [:event_name, :status], prefix: prefix))
    create(index(:pending_events, [:status, :timeout_at], prefix: prefix))
    create(index(:pending_events, [:wait_group_id], prefix: prefix))

    create(
      unique_index(
        :pending_events,
        [:workflow_id, :event_name],
        where: "status = 'pending' AND wait_type = 'single'",
        name: :pending_events_workflow_event_pending_idx,
        prefix: prefix
      )
    )
  end

  # wait_groups table for wait_for_any/wait_for_all
  defp create_wait_groups_table(prefix) do
    create table(:wait_groups, primary_key: false, prefix: prefix) do
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
      add(:wait_type, :string, null: false)
      add(:event_names, {:array, :string}, null: false)
      add(:received_events, :jsonb, default: "{}")
      add(:status, :string, null: false, default: "pending")
      add(:timeout_at, :utc_datetime_usec)
      add(:timeout_value, :jsonb)
      add(:completed_at, :utc_datetime_usec)

      # For parallel/foreach context
      add(:parallel_id, :integer)
      add(:foreach_id, :integer)
      add(:foreach_index, :integer)

      timestamps(type: :utc_datetime_usec)
    end
  end

  defp create_wait_groups_indexes(prefix) do
    create(index(:wait_groups, [:workflow_id, :status], prefix: prefix))
    create(index(:wait_groups, [:status, :timeout_at], prefix: prefix))
  end
end
