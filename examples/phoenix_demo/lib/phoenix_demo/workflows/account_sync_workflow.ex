defmodule PhoenixDemo.Workflows.AccountSyncWorkflow do
  @moduledoc """
  Copies a CRM account to the data warehouse. One sync per account at a time:
  an edit made while a sync runs syncs again once it ends, with the newest
  data, however many edits came in meanwhile.

  Showcases: a workflow key with `on_duplicate: :run_again`. Start it for the
  same account several times while one runs.

  Input: %{"account_id" => "ACME", "plan" => "pro", "seconds" => 8}
  """

  use Durable
  use Durable.Helpers

  require Logger

  workflow "sync_account", on_duplicate: :run_again do
    step :load_account, fn account ->
      {:ok, assign(account, :seats, 5 + :rand.uniform(45))}
    end

    step :write_to_warehouse, fn account ->
      Process.sleep(trunc(account["seconds"] || 8) * 1000)
      Logger.info("[Sync] #{account["account_id"]} synced on the #{account["plan"]} plan")
      {:ok, assign(account, :synced, true)}
    end
  end
end
