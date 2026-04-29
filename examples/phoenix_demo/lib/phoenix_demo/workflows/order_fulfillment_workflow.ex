defmodule PhoenixDemo.Workflows.OrderFulfillmentWorkflow do
  @moduledoc """
  End-to-end order fulfillment that calls `PaymentWorkflow` as a child and
  rolls back via saga compensation when downstream steps fail.

  Showcases: `call_workflow`, `compensate`, sequential pipeline, parent/child
  relationship.

  Input:
      %{"order_id" => "ORD-123",
        "amount" => 42.50,
        "force_failure" => false}

  Set `force_failure: true` to force the shipping step to fail and observe
  compensations cascade in reverse order (`refund_payment` then
  `release_inventory`).
  """

  use Durable
  use Durable.Helpers
  use Durable.Context
  use Durable.Orchestration

  alias PhoenixDemo.Workflows.PaymentWorkflow

  require Logger

  workflow "fulfill_order", timeout: minutes(10) do
    step :reserve_inventory, [compensate: :release_inventory], fn data ->
      order_id = data["order_id"] || "ORD-#{:rand.uniform(99_999)}"
      reservation_id = "RES-#{:rand.uniform(99_999)}"

      Logger.info("[Order #{order_id}] Reserving inventory — #{reservation_id}")
      Process.sleep(120)

      put_context(:order_id, order_id)
      put_context(:reservation_id, reservation_id)
      put_context(:amount, data["amount"] || 0)
      put_context(:force_failure, data["force_failure"] == true)

      {:ok,
       data
       |> assign("order_id", order_id)
       |> assign("reservation_id", reservation_id)}
    end

    step :charge_customer, fn data ->
      amount = get_context(:amount)

      Logger.info("[Order] Calling PaymentWorkflow for $#{amount}")

      # Payment always succeeds in the saga demo — shipping is the failure
      # surface so the full compensation cascade is visible.
      case call_workflow(
             PaymentWorkflow,
             %{"amount" => amount, "force_failure" => false},
             timeout: minutes(2)
           ) do
        {:ok, %{"payment_id" => payment_id} = result} ->
          put_context(:payment_id, payment_id)
          put_context(:auth_code, result["auth_code"])
          Logger.info("[Order] Payment captured — #{payment_id}")
          {:ok, assign(data, "payment_id", payment_id)}

        {:error, reason} ->
          Logger.warning("[Order] Payment failed: #{inspect(reason)}")
          {:error, %{reason: "payment_failed", details: reason}}
      end
    end

    step :ship_order, [compensate: :refund_payment], fn data ->
      order_id = get_context(:order_id)
      force_failure = get_context(:force_failure)

      if force_failure do
        Logger.warning("[Order #{order_id}] Carrier rejected package — failing to trigger saga")
        {:error, %{reason: "Carrier rejected package", carrier: "DemoExpress"}}
      else
        tracking = "TRK-#{:rand.uniform(999_999)}"
        Logger.info("[Order #{order_id}] Shipped — tracking=#{tracking}")
        Process.sleep(80)

        put_context(:tracking_number, tracking)
        {:ok, assign(data, "tracking_number", tracking)}
      end
    end

    step :send_confirmation, fn _data ->
      order_id = get_context(:order_id)
      tracking = get_context(:tracking_number)
      payment_id = get_context(:payment_id)

      Logger.info("[Order #{order_id}] Confirmation sent — payment=#{payment_id} tracking=#{tracking}")

      {:ok,
       %{
         "order_id" => order_id,
         "status" => "fulfilled",
         "payment_id" => payment_id,
         "tracking_number" => tracking
       }}
    end

    compensate :refund_payment, fn data ->
      payment_id = get_context(:payment_id)

      if payment_id do
        Logger.warning("[Compensate] Refunding payment #{payment_id}")
        Process.sleep(60)
        put_context(:refunded, true)
      else
        Logger.warning("[Compensate] No payment to refund (charge step never completed)")
      end

      {:ok, data}
    end

    compensate :release_inventory, fn data ->
      reservation_id = get_context(:reservation_id)

      if reservation_id do
        Logger.warning("[Compensate] Releasing reservation #{reservation_id}")
        Process.sleep(40)
        put_context(:inventory_released, true)
      end

      {:ok, data}
    end
  end
end
