defmodule Durable.Migration.Migrations.V20261110000000AddReadyOrderAndScheduleSource do
  @moduledoc false
  # * `workflow_executions_claim_index` sorts by when a run became ready,
  #   `COALESCE(scheduled_at, inserted_at)`. It sorted `scheduled_at` with NULLs
  #   first, so a retry or snooze that had come due waited behind every run
  #   started since.
  # * `scheduled_workflows.source` tells a schedule made with `Durable.schedule/3`
  #   (`api`) from one declared with `@schedule` (`code`) and one whose `@schedule`
  #   was removed (`removed`). Only `code` schedules can be turned off for
  #   no longer being in the code. Rows from before this migration count as
  #   `api` until their `@schedule` registers them at the next boot.
  #
  # Creating the index scans `workflow_executions` and blocks inserts while it
  # runs; `CONCURRENTLY` isn't possible inside the migration transaction.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_110_000_000

  @impl true
  def up(prefix) do
    alter table(:scheduled_workflows, prefix: prefix) do
      add_if_not_exists(:source, :text, null: false, default: "api")
    end

    replace_claim_index(prefix, [
      "queue",
      "priority DESC",
      "COALESCE(scheduled_at, inserted_at) ASC",
      "inserted_at ASC"
    ])

    :ok
  end

  @impl true
  def down(prefix) do
    replace_claim_index(prefix, [
      "queue",
      "priority DESC",
      "scheduled_at ASC NULLS FIRST",
      "inserted_at ASC"
    ])

    alter table(:scheduled_workflows, prefix: prefix) do
      remove_if_exists(:source, :text)
    end

    :ok
  end

  defp replace_claim_index(prefix, columns) do
    drop_if_exists(
      index(:workflow_executions, [:queue],
        name: :workflow_executions_claim_index,
        prefix: prefix
      )
    )

    create(
      index(:workflow_executions, columns,
        name: :workflow_executions_claim_index,
        where: "status = 'pending'",
        prefix: prefix
      )
    )
  end
end
