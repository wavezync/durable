defmodule Durable.Migration.Migrations.V20261109000000AddClaimIndex do
  @moduledoc false
  # A claim takes the first ready runs by priority, then due time, then age. No
  # index had that order, so every claim sorted the queue's whole backlog. This
  # one lets it read only the rows it takes. It's partial, so finished runs cost
  # it nothing.
  #
  # Creating the index scans `workflow_executions` and blocks inserts while it
  # runs; `CONCURRENTLY` isn't possible inside the migration transaction.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_109_000_000

  @impl true
  def up(prefix) do
    create_if_not_exists(
      index(
        :workflow_executions,
        ["queue", "priority DESC", "scheduled_at ASC NULLS FIRST", "inserted_at ASC"],
        name: :workflow_executions_claim_index,
        where: "status = 'pending'",
        prefix: prefix
      )
    )

    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(
      index(:workflow_executions, [:queue],
        name: :workflow_executions_claim_index,
        prefix: prefix
      )
    )

    :ok
  end
end
