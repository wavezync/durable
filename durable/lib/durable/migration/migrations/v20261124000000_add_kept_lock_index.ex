defmodule Durable.Migration.Migrations.V20261124000000AddKeptLockIndex do
  @moduledoc false
  # A run stopped mid-step keeps its worker's lock, with no token, until that
  # worker has stopped (rule 30), and the claim takes no other run of its key
  # meanwhile. Without this index that check reads every run a worker holds,
  # through the lock's index, or every run the key ever had, through the
  # key's. This one holds only the runs keeping a lock, which is nearly none.
  #
  # Creating the index scans `workflow_executions` and blocks inserts while it
  # runs; `CONCURRENTLY` isn't possible inside the migration transaction.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_124_000_000

  @impl true
  def up(prefix) do
    create_if_not_exists(
      index(:workflow_executions, [:workflow_module, :workflow_name, :key],
        name: :workflow_executions_kept_lock_index,
        where: "lock_token IS NULL AND locked_by IS NOT NULL",
        prefix: prefix
      )
    )

    :ok
  end

  @impl true
  def down(prefix) do
    drop_if_exists(
      index(:workflow_executions, [:key],
        name: :workflow_executions_kept_lock_index,
        prefix: prefix
      )
    )

    :ok
  end
end
