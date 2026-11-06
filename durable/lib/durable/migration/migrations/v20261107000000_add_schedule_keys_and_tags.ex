defmodule Durable.Migration.Migrations.V20261107000000AddScheduleKeysAndTags do
  @moduledoc false
  # * `scheduled_workflows.key` — the workflow key a schedule's runs start
  #   with, so a fire while the last run is still going follows the
  #   workflow's `on_duplicate:` instead of starting a second copy.
  # * `workflow_executions.tags` — free-form labels a start gives a run, such
  #   as "account:7", to find and cancel runs across workflows. The GIN index
  #   serves `tags @> ARRAY[...]`.
  #
  # Creating the index scans `workflow_executions` and blocks inserts while it
  # runs; `CONCURRENTLY` isn't possible inside the migration transaction.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_107_000_000

  @impl true
  def up(prefix) do
    alter table(:scheduled_workflows, prefix: prefix) do
      add_if_not_exists(:key, :text)
    end

    alter table(:workflow_executions, prefix: prefix) do
      add_if_not_exists(:tags, {:array, :text}, null: false, default: [])
    end

    create_if_not_exists(
      index(:workflow_executions, [:tags],
        name: :workflow_executions_tags_index,
        using: "GIN",
        prefix: prefix
      )
    )

    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(
      index(:workflow_executions, [:tags], name: :workflow_executions_tags_index, prefix: prefix)
    )

    alter table(:workflow_executions, prefix: prefix) do
      remove_if_exists(:tags, {:array, :text})
    end

    alter table(:scheduled_workflows, prefix: prefix) do
      remove_if_exists(:key, :text)
    end

    :ok
  end
end
