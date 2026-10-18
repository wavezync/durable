defmodule DurableDashboard.CronTest do
  use ExUnit.Case, async: true

  import DurableDashboard.Cron, only: [describe: 1]

  test "common shapes read as words" do
    assert describe("* * * * *") == "Every minute"
    assert describe("*/15 * * * *") == "Every 15 minutes"
    assert describe("5 * * * *") == "Every hour at :05"
    assert describe("0 */6 * * *") == "Every 6 hours at :00"
    assert describe("0 9 * * *") == "Every day at 09:00"
    assert describe("30 9,17 * * *") == "Every day at 09:30 and 17:30"
    assert describe("0 9 * * 1-5") == "Weekdays at 09:00"
    assert describe("0 10 * * 0,6") == "Weekends at 10:00"
    assert describe("0 8 * * 1") == "Every Monday at 08:00"
    assert describe("0 8 * * 1,3,5") == "Every Monday, Wednesday and Friday at 08:00"
    assert describe("0 2 1 * *") == "Monthly on day 1 at 02:00"
    assert describe("@daily") == "Every day at 00:00"
    assert describe("@hourly") == "Every hour at :00"
  end

  test "anything else is left to the raw expression" do
    assert describe("0 9 * 1-3 *") == nil
    assert describe("0-30/5 9-17 * * 1-5") == nil
    assert describe("nonsense") == nil
    assert describe("99 * * * *") == nil
  end
end
