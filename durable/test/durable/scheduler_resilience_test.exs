defmodule Durable.SchedulerResilienceTest do
  @moduledoc """
  Regression coverage for PR 7 / L-1 — the scheduler must surface persistent
  failures (`Durable.Scheduler.API.record_failure/3`) and auto-disable the
  schedule after N consecutive failures, rather than looping hot on the
  same unresolvable schedule every poll cycle.
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Repo
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.ScheduledWorkflow

  defp config, do: Config.get(Durable)

  defp insert_schedule(attrs \\ %{}) do
    defaults = %{
      name: "test_resilience_#{System.unique_integer([:positive])}",
      workflow_module: "Elixir.NonExistentModuleXYZ",
      workflow_name: "never_runs",
      cron_expression: "*/5 * * * *",
      enabled: true,
      next_run_at: DateTime.add(DateTime.utc_now(), -5, :second)
    }

    attrs = Map.merge(defaults, attrs)

    {:ok, s} =
      %ScheduledWorkflow{}
      |> ScheduledWorkflow.changeset(attrs)
      |> Repo.insert(config())

    s
  end

  test "record_failure/3 records error + increments counter" do
    schedule = insert_schedule()

    updated = API.record_failure(schedule, "module not found", config())

    assert updated.consecutive_failures == 1
    assert updated.last_error =~ "module not found"
    assert updated.last_error_at != nil
    # Not auto-disabled yet
    assert updated.enabled == true
    assert is_nil(updated.auto_disabled_at)
  end

  test "record_failure/3 auto-disables after 5 consecutive failures" do
    schedule = insert_schedule(%{consecutive_failures: 4})

    updated = API.record_failure(schedule, "still broken", config())

    assert updated.consecutive_failures == 5
    assert updated.enabled == false
    assert updated.auto_disabled_at != nil
  end

  test "record_failure/3 advances next_run_at" do
    schedule = insert_schedule()

    updated = API.record_failure(schedule, "boom", config())

    # Defer the next fire so we don't loop hot on the same broken schedule
    assert DateTime.after?(updated.next_run_at, DateTime.utc_now())
  end

  test "record_failure/3 counts on the row, not on the copy the tick read" do
    schedule = insert_schedule(%{consecutive_failures: 2})

    # The copy this node holds is behind: the row has moved on to 3.
    stale = %{schedule | consecutive_failures: 0}
    {:ok, _} = schedule |> Ecto.Changeset.change(consecutive_failures: 3) |> Repo.update(config())

    assert API.record_failure(stale, "boom", config()).consecutive_failures == 4
    # The fire it failed has been moved on: a second node's failure isn't counted.
    assert API.record_failure(stale, "boom", config()) == nil
    assert Repo.get(config(), ScheduledWorkflow, schedule.id).consecutive_failures == 4
  end
end
