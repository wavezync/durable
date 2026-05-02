defmodule Durable.SchedulerResilienceTest do
  @moduledoc """
  Regression coverage for PR 7 / L-1 — the scheduler must surface persistent
  failures in `ScheduledWorkflow.failure_changeset/3` and auto-disable the
  schedule after N consecutive failures, rather than looping hot on the
  same unresolvable schedule every poll cycle.
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Repo
  alias Durable.Storage.Schemas.ScheduledWorkflow

  defp config, do: Config.get(Durable)

  defp insert_schedule(attrs \\ %{}) do
    defaults = %{
      name: "test_resilience_#{System.unique_integer([:positive])}",
      workflow_module: "Elixir.NonExistentModuleXYZ",
      workflow_name: "never_runs",
      cron_expression: "*/5 * * * *",
      enabled: true
    }

    attrs = Map.merge(defaults, attrs)

    {:ok, s} =
      %ScheduledWorkflow{}
      |> ScheduledWorkflow.changeset(attrs)
      |> Repo.insert(config())

    s
  end

  test "failure_changeset/3 records error + increments counter" do
    schedule = insert_schedule()

    {:ok, updated} =
      schedule
      |> ScheduledWorkflow.failure_changeset("module not found")
      |> Repo.update(config())

    assert updated.consecutive_failures == 1
    assert updated.last_error =~ "module not found"
    assert updated.last_error_at != nil
    # Not auto-disabled yet
    assert updated.enabled == true
    assert is_nil(updated.auto_disabled_at)
  end

  test "failure_changeset auto-disables after N consecutive failures" do
    schedule = insert_schedule(%{consecutive_failures: 4})

    {:ok, updated} =
      schedule
      |> ScheduledWorkflow.failure_changeset("still broken", auto_disable_after: 5)
      |> Repo.update(config())

    assert updated.consecutive_failures == 5
    assert updated.enabled == false
    assert updated.auto_disabled_at != nil
  end

  test "success_changeset/3 resets the failure counter and clears last_error" do
    schedule =
      insert_schedule(%{
        consecutive_failures: 3,
        last_error: "previous failure",
        last_error_at: DateTime.utc_now()
      })

    now = DateTime.utc_now()
    next = DateTime.add(now, 300, :second)

    {:ok, updated} =
      schedule
      |> ScheduledWorkflow.success_changeset(now, next)
      |> Repo.update(config())

    assert updated.consecutive_failures == 0
    assert is_nil(updated.last_error)
    assert is_nil(updated.last_error_at)
    assert updated.last_run_at == now
    assert updated.next_run_at == next
  end

  test "failure_changeset advances next_run_at when supplied" do
    schedule = insert_schedule()
    future = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:microsecond)

    {:ok, updated} =
      schedule
      |> ScheduledWorkflow.failure_changeset("boom", next_run_at: future)
      |> Repo.update(config())

    # Defer the next fire so we don't loop hot on the same broken schedule
    assert updated.next_run_at == future
  end
end
