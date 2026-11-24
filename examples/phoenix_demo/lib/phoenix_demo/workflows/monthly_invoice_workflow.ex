defmodule PhoenixDemo.Workflows.MonthlyInvoiceWorkflow do
  @moduledoc """
  Issues a customer's invoice for a month, at most once: a second start for
  the same customer and month hands back the first run, finished or not, and
  never bills twice.

  Showcases: a workflow key as an idempotency key, with
  `on_duplicate: :use_existing` and `reuse: :never`.

  Input: %{"customer" => "acme", "month" => "2026-11"}
  """

  use Durable
  use Durable.Helpers

  require Logger

  workflow "issue_invoice", on_duplicate: :use_existing, reuse: :never do
    step :total_usage, fn invoice ->
      Process.sleep(800)
      {:ok, assign(invoice, :total_cents, 4_900 + :rand.uniform(20_000))}
    end

    step :send_invoice, fn invoice ->
      Logger.info(
        "[Invoice] #{invoice["customer"]} #{invoice["month"]}: #{invoice["total_cents"]}c"
      )

      {:ok, assign(invoice, :sent, true)}
    end
  end
end
