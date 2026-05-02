defmodule PhoenixDemo.Workflows.DripEmailCampaignWorkflow do
  @moduledoc """
  Multi-stage email drip campaign that visibly progresses across waits.
  Day 2 is sent after a `schedule_at(now + drip_scale s)` pause; day 7 is
  sent after a `sleep(drip_scale s)` pause.

  Both delays default to 30 seconds so a demo session can complete in under
  two minutes. Override with `config :phoenix_demo, :drip_scale, 5`.

  Showcases: `sleep`, `schedule_at`, multi-stage workflows that go through
  `:waiting → :running → :waiting` cycles.

  Input: `%{"customer_email" => "alice@example.com", "campaign" => "welcome"}`
  """

  use Durable
  use Durable.Helpers
  use Durable.Context
  use Durable.Wait

  require Logger

  @drip_scale Application.compile_env(:phoenix_demo, :drip_scale, 30)

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

    step :wait_day_2, fn data ->
      until = DateTime.add(DateTime.utc_now(), @drip_scale, :second)
      Logger.info("[Drip] Scheduling day-2 nudge at #{DateTime.to_iso8601(until)}")
      schedule_at(until)
      {:ok, data}
    end

    step :send_day_2_email, fn data ->
      email = get_context(:customer_email)
      Logger.info("[Drip] Day-2 email → #{email}")
      put_context(:day_2_sent_at, DateTime.utc_now() |> DateTime.to_iso8601())
      {:ok, assign(data, "email_step", "day_2_sent")}
    end

    step :wait_day_7, fn data ->
      Logger.info("[Drip] Sleeping #{@drip_scale}s before day-7 email")
      sleep(seconds(@drip_scale))
      {:ok, data}
    end

    step :send_day_7_email, fn data ->
      email = get_context(:customer_email)
      Logger.info("[Drip] Day-7 email → #{email}")
      put_context(:day_7_sent_at, DateTime.utc_now() |> DateTime.to_iso8601())
      {:ok, assign(data, "email_step", "day_7_sent")}
    end

    step :complete_campaign, fn _data ->
      email = get_context(:customer_email)

      {:ok,
       %{
         "customer_email" => email,
         "campaign" => get_context(:campaign),
         "status" => "completed",
         "welcome_sent_at" => get_context(:welcome_sent_at),
         "day_2_sent_at" => get_context(:day_2_sent_at),
         "day_7_sent_at" => get_context(:day_7_sent_at)
       }}
    end
  end
end
