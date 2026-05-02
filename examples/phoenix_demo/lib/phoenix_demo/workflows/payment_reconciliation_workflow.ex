defmodule PhoenixDemo.Workflows.PaymentReconciliationWorkflow do
  @moduledoc """
  Submits a transaction to a (mock) processor and waits for an external
  webhook to settle it. The webhook is delivered via the Pending Events
  page in the demo UI (which calls `Durable.send_event/3`).

  Showcases: `wait_for_event` with timeout + decision routing on the
  resulting payload.

  Input: `%{"transaction_id" => "TXN-123"}`
  """

  use Durable
  use Durable.Helpers
  use Durable.Context
  use Durable.Wait

  require Logger

  workflow "reconcile_payment", timeout: minutes(10) do
    step :submit_to_processor, fn data ->
      txn_id = data["transaction_id"] || "TXN-#{:rand.uniform(99_999)}"

      Logger.info("[Recon] Submitting #{txn_id} to processor")
      Process.sleep(80)

      put_context(:txn_id, txn_id)
      put_context(:submitted_at, DateTime.utc_now() |> DateTime.to_iso8601())

      {:ok, assign(data, "transaction_id", txn_id)}
    end

    step :await_webhook, fn data ->
      txn_id = get_context(:txn_id)
      Logger.info("[Recon] #{txn_id} — waiting for webhook_received event")

      payload =
        wait_for_event("webhook_received",
          timeout: minutes(5),
          timeout_value: %{"status" => "timeout"}
        )

      Logger.info("[Recon] #{txn_id} received webhook: #{inspect(payload)}")
      put_context(:webhook_payload, payload)
      {:ok, assign(data, "webhook", payload)}
    end

    decision :route_on_status, fn data ->
      payload = get_context(:webhook_payload) || %{}

      case payload["status"] do
        "settled" ->
          Logger.info("[Recon] Payment settled — reconciling")
          {:ok, data}

        other ->
          Logger.warning("[Recon] Payment did not settle (status=#{other}) — handling failure")
          {:goto, :handle_failure, assign(data, "failure_status", other)}
      end
    end

    step :reconcile, fn _data ->
      txn_id = get_context(:txn_id)
      payload = get_context(:webhook_payload)

      Logger.info("[Recon] #{txn_id} reconciled successfully")

      {:ok,
       %{
         "transaction_id" => txn_id,
         "status" => "reconciled",
         "settlement" => payload,
         "reconciled_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end

    step :handle_failure, fn data ->
      txn_id = get_context(:txn_id)
      status = data["failure_status"] || "unknown"

      Logger.warning("[Recon] #{txn_id} failed reconciliation — status=#{status}")

      {:ok,
       %{
         "transaction_id" => txn_id,
         "status" => "failed",
         "failure_status" => status,
         "failed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end
end
