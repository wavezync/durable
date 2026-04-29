defmodule Durable.Migration.Migrations.V20260413000000AddSchedulerResilience do
  @moduledoc false
  # Bug L-1: scheduler resilience.
  # Adds tracking fields so the scheduler can detect persistently-failing
  # ScheduledWorkflow rows (e.g., the workflow_module no longer exists after
  # a code reload) and auto-disable them after a configurable failure count
  # instead of looping noisily forever.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_413_000_000

  @impl true
  def up(prefix) do
    alter table(:scheduled_workflows, prefix: prefix) do
      add_if_not_exists(:last_error, :text)
      add_if_not_exists(:last_error_at, :utc_datetime_usec)
      add_if_not_exists(:consecutive_failures, :integer, default: 0)
      add_if_not_exists(:auto_disabled_at, :utc_datetime_usec)
    end

    :ok
  end

  @impl true
  def down(prefix) do
    alter table(:scheduled_workflows, prefix: prefix) do
      remove_if_exists(:last_error, :text)
      remove_if_exists(:last_error_at, :utc_datetime_usec)
      remove_if_exists(:consecutive_failures, :integer)
      remove_if_exists(:auto_disabled_at, :utc_datetime_usec)
    end

    :ok
  end
end
