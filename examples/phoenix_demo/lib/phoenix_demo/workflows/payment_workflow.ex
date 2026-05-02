defmodule PhoenixDemo.Workflows.PaymentWorkflow do
  @moduledoc """
  Charges a payment with retry/backoff. Runs standalone or as a child of
  `OrderFulfillmentWorkflow` via `call_workflow/3`.

  Showcases: composition target, exponential-backoff retry visible as
  separate `StepExecution` rows on the timeline.

  Input: `%{"amount" => 42.50, "force_failure" => false}`
  """

  use Durable
  use Durable.Helpers
  use Durable.Context

  require Logger

  workflow "process_payment", timeout: minutes(5) do
    step :validate_amount, fn data ->
      amount = data["amount"] || 0

      if amount <= 0 do
        {:error, %{reason: "Invalid amount", amount: amount}}
      else
        put_context(:amount, amount)
        put_context(:force_failure, data["force_failure"] == true)
        Logger.info("[Payment] Validating $#{amount}")
        {:ok, assign(data, :amount, amount)}
      end
    end

    step :authorize_card,
         [retry: [max_attempts: 3, backoff: :exponential, base: 2, max_backoff: 5_000]],
         fn data ->
      force_failure = get_context(:force_failure)
      amount = get_context(:amount)

      Logger.info("[Payment] Authorizing $#{amount} (force_failure=#{force_failure})")
      Process.sleep(150)

      cond do
        force_failure ->
          {:error, %{reason: "issuer_decline", amount: amount}}

        :rand.uniform(3) > 1 ->
          {:error, %{reason: "transient_network_glitch", amount: amount}}

        true ->
          auth_code = "AUTH-#{:rand.uniform(99_999)}"
          put_context(:auth_code, auth_code)
          Logger.info("[Payment] Authorized — auth_code=#{auth_code}")
          {:ok, assign(data, :auth_code, auth_code)}
      end
    end

    step :capture_payment, fn data ->
      amount = get_context(:amount)
      Logger.info("[Payment] Capturing $#{amount}")
      Process.sleep(100)

      payment_id = "PAY-#{:rand.uniform(999_999)}"
      captured_at = DateTime.utc_now() |> DateTime.to_iso8601()

      put_context(:payment_id, payment_id)
      put_context(:captured_at, captured_at)

      {:ok,
       data
       |> assign("payment_id", payment_id)
       |> assign("amount", amount)
       |> assign("captured_at", captured_at)}
    end
  end
end
