defmodule PhoenixDemo.Workflows.OrderTrackerWorkflow do
  @moduledoc """
  Tracks an order until the carrier reports it delivered. Starting the tracker
  again for the same order doesn't start a second one: the new status goes to
  the running tracker as an `order_updated` event.

  Showcases: a workflow key with `on_duplicate: {:send_event, "order_updated"}`
  and `wait_for_event`.

  Input: %{"order_id" => "ORD-1042", "status" => "shipped"}
  """

  use Durable
  use Durable.Helpers
  use Durable.Wait

  require Logger

  workflow "track_order", on_duplicate: {:send_event, "order_updated"} do
    step :open_tracker, fn order ->
      {:ok, assign(order, :history, [order["status"]])}
    end

    step :await_delivery, fn order ->
      update =
        wait_for_event("order_updated",
          timeout: minutes(30),
          timeout_value: %{"status" => "no update"}
        )

      {:ok, assign(order, :status, update["status"])}
    end

    step :notify_customer, fn order ->
      Logger.info("[Orders] #{order["order_id"]} is #{order["status"]}")
      {:ok, order}
    end
  end
end
