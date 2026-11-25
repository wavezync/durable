defmodule Durable.Migration.Migrations.V20261125000000AddKeyScopes do
  @moduledoc false
  # `key_scope:` (issue #52): workflows that name one scope share its keys.
  # `workflow_executions.key_scope` is the scope a run was started under, NULL
  # for a workflow's own keys, so no row is rewritten. One run per scope and
  # key holds it. The per-workflow holder index stays: a workflow's runs of a
  # key still have one holder among them, and a node not upgraded yet inserts
  # against it.
  #
  # Creating the index scans `workflow_executions` and blocks inserts while it
  # runs; `CONCURRENTLY` isn't possible inside the migration transaction.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_125_000_000

  @impl true
  def up(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      add_if_not_exists(:key_scope, :text)
    end

    create_if_not_exists(
      unique_index(:workflow_executions, [:key_scope, :key],
        name: :workflow_executions_key_scope_holder_index,
        where: "holds_key AND key_scope IS NOT NULL",
        prefix: prefix
      )
    )

    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(
      index(:workflow_executions, [:key_scope, :key],
        name: :workflow_executions_key_scope_holder_index,
        prefix: prefix
      )
    )

    alter table(:workflow_executions, prefix: prefix) do
      remove_if_exists(:key_scope, :text)
    end

    :ok
  end
end
