defmodule PhoenixDemo.Workflows.ReportExportWorkflow do
  @moduledoc """
  Builds a user's CSV export. Asking again with other filters replaces the
  export in progress: the old one is cancelled, and the new one starts once
  the old one's step has stopped, so two exports never write one file at once.

  Showcases: a workflow key with `on_duplicate: :cancel_existing`, and a
  cancel that waits for the step in flight.

  Input: %{"user" => "dana", "filters" => "last 30 days", "seconds" => 20}
  """

  use Durable
  use Durable.Helpers

  require Logger

  workflow "export_report", on_duplicate: :cancel_existing do
    step :query_rows, fn export ->
      Process.sleep(trunc(export["seconds"] || 20) * 1000)
      {:ok, assign(export, :rows, 1_000 + :rand.uniform(9_000))}
    end

    step :write_file, fn export ->
      Logger.info("[Export] #{export["user"]}: #{export["rows"]} rows (#{export["filters"]})")
      {:ok, assign(export, :file, "exports/#{export["user"]}.csv")}
    end
  end
end
