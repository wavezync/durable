defmodule Durable.Migration.Migrations.V20261111000000AddRootWorkflowId do
  @moduledoc false
  # `workflow_executions.root_workflow_id` is the run at the top of this run's
  # tree, so a whole tree of child and parallel runs can share one trace. It's
  # NULL on a top run, which is its own root. A child started before this
  # migration counts as its own root too.
  #
  # Stored rather than found by walking `parent_workflow_id`, because a parent
  # that has finished can be pruned while the rest of its tree is still of use.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_111_000_000

  @impl true
  def up(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      add_if_not_exists(:root_workflow_id, :binary_id)
    end

    :ok
  end

  @impl true
  def down(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      remove_if_exists(:root_workflow_id, :binary_id)
    end

    :ok
  end
end
