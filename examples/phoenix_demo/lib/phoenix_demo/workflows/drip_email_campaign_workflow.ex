defmodule PhoenixDemo.Workflows.DripEmailCampaignWorkflow do
  @moduledoc """
  Three-stage email drip that visibly cycles `:running → :waiting → :running`
  across progressively longer gaps:

      welcome
        → schedule_at(now + 30s) → followup #1
        → sleep(1m)              → followup #2
        → sleep(2m)              → followup #3
        → complete

  Showcases: `schedule_at`, `sleep`, and a multi-stage workflow whose status
  flips between `:running` and `:waiting` three times.

  Input: `%{"customer_email" => "alice@example.com", "campaign" => "welcome"}`
  """

  use Durable
  use Durable.Helpers
  use Durable.Context
  use Durable.Wait

  require Logger

  workflow "drip_email_campaign", timeout: minutes(30) do
    step :send_welcome, fn data ->
      email = data["customer_email"] || "demo@example.com"
      campaign = data["campaign"] || "welcome"

      put_context(:customer_email, email)
      put_context(:campaign, campaign)
      put_context(:welcome_sent_at, DateTime.utc_now() |> DateTime.to_iso8601())

      Logger.info("[Drip] Welcome email → #{email} (#{campaign})")
      {:ok, assign(data, "email_step", "welcome_sent")}
    end

    step :wait_first, fn data ->
      until = DateTime.add(DateTime.utc_now(), 30, :second)
      Logger.info("[Drip] Scheduling followup #1 at #{DateTime.to_iso8601(until)}")
      schedule_at(until)
      {:ok, data}
    end

    step :send_first_followup, fn data ->
      email = get_context(:customer_email)
      Logger.info("[Drip] Followup #1 → #{email}")
      put_context(:first_sent_at, DateTime.utc_now() |> DateTime.to_iso8601())
      {:ok, assign(data, "email_step", "first_sent")}
    end

    step :wait_second, fn data ->
      Logger.info("[Drip] Sleeping 1m before followup #2")
      sleep(minutes(1))
      {:ok, data}
    end

    step :send_second_followup, fn data ->
      email = get_context(:customer_email)
      Logger.info("[Drip] Followup #2 → #{email}")
      put_context(:second_sent_at, DateTime.utc_now() |> DateTime.to_iso8601())
      {:ok, assign(data, "email_step", "second_sent")}
    end

    step :wait_third, fn data ->
      Logger.info("[Drip] Sleeping 2m before followup #3")
      sleep(minutes(2))
      {:ok, data}
    end

    step :send_third_followup, fn data ->
      email = get_context(:customer_email)
      Logger.info("[Drip] Followup #3 → #{email}")
      put_context(:third_sent_at, DateTime.utc_now() |> DateTime.to_iso8601())
      {:ok, assign(data, "email_step", "third_sent")}
    end

    step :complete_campaign, fn _data ->
      email = get_context(:customer_email)

      {:ok,
       %{
         "customer_email" => email,
         "campaign" => get_context(:campaign),
         "status" => "completed",
         "welcome_sent_at" => get_context(:welcome_sent_at),
         "first_sent_at" => get_context(:first_sent_at),
         "second_sent_at" => get_context(:second_sent_at),
         "third_sent_at" => get_context(:third_sent_at)
       }}
    end
  end
end
