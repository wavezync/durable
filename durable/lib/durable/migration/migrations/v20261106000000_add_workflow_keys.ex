defmodule Durable.Migration.Migrations.V20261106000000AddWorkflowKeys do
  @moduledoc false
  # Workflow keys (`Durable.start(..., key: "article:42")`):
  #
  # * `workflow_executions.key` — the key a run was started with, kept for
  #   history. `holds_key` marks the one run per workflow and key that holds
  #   it. Status is deliberately not part of the unique index: no status
  #   change can raise a unique error or free a key; only a new start (or
  #   `Durable.release_key/2`) moves it.
  # * `activity (workflow_id, at)` — key events per run, for the run page.
  #
  # Creating the indexes scans `workflow_executions` and blocks inserts while
  # it runs; `CONCURRENTLY` isn't possible inside the migration transaction.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_106_000_000

  @impl true
  def up(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      add_if_not_exists(:key, :text)
      add_if_not_exists(:holds_key, :boolean, null: false, default: false)
    end

    create_if_not_exists(
      unique_index(:workflow_executions, [:workflow_module, :workflow_name, :key],
        name: :workflow_executions_key_holder_index,
        where: "holds_key",
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:workflow_executions, [:key],
        name: :workflow_executions_key_lookup_index,
        where: "key IS NOT NULL",
        prefix: prefix
      )
    )

    create_if_not_exists(
      index(:activity, [:workflow_id, :at],
        name: :activity_workflow_id_at_index,
        where: "workflow_id IS NOT NULL",
        prefix: prefix
      )
    )

    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(
      index(:activity, [:workflow_id, :at], name: :activity_workflow_id_at_index, prefix: prefix)
    )

    drop_if_exists(
      index(:workflow_executions, [:key],
        name: :workflow_executions_key_lookup_index,
        prefix: prefix
      )
    )

    drop_if_exists(
      index(:workflow_executions, [:workflow_module, :workflow_name, :key],
        name: :workflow_executions_key_holder_index,
        prefix: prefix
      )
    )

    alter table(:workflow_executions, prefix: prefix) do
      remove_if_exists(:holds_key, :boolean)
      remove_if_exists(:key, :text)
    end

    :ok
  end
end
