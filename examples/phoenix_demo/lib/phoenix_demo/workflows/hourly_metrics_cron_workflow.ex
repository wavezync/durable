defmodule PhoenixDemo.Workflows.HourlyMetricsCronWorkflow do
  @moduledoc """
  Auto-runs every minute to mint a fake metrics report. The cadence is
  intentionally fast so scheduled runs are visible in the dashboard during
  a demo session.

  Showcases: `@schedule cron: ...`, scheduler-driven execution, the
  Schedules page (`/schedules`) and Run-now action.

  Registered in `application.ex` under `scheduled_modules:`. The scheduler
  polls every 5 seconds (`scheduler_interval: 5_000`), so the first fire
  lands within the first minute after boot.
  """

  use Durable
  use Durable.Helpers
  use Durable.Context
  use Durable.Scheduler.DSL

  require Logger

  @schedule cron: "* * * * *"
  workflow "hourly_metrics", timeout: minutes(1) do
    step :gather, fn _data ->
      metrics = %{
        "active_users" => :rand.uniform(1_000),
        "requests_per_min" => :rand.uniform(10_000),
        "p99_latency_ms" => 50 + :rand.uniform(200),
        "error_rate" => Float.round(:rand.uniform() * 0.05, 4),
        "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      Logger.info("[Cron] Metrics gathered: #{inspect(metrics)}")
      put_context(:metrics, metrics)
      {:ok, metrics}
    end

    step :persist, fn data ->
      Logger.info("[Cron] Persisted metrics snapshot")
      {:ok, Map.put(data, "persisted_at", DateTime.utc_now() |> DateTime.to_iso8601())}
    end
  end
end
