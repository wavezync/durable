defmodule Mix.Tasks.Durable.Doctor do
  @shortdoc "Diagnoses common workflow/queue/scheduler health problems"

  @moduledoc """
  Health check for a Durable instance. Surfaces the classes of stuck
  state that recovery doesn't always fix on its own:

    * zombies — `:waiting` workflows with no pending inputs or events
    * stale locks — `:running` workflows whose lock hasn't been
      refreshed for longer than `stale_lock_timeout`
    * compensation stragglers — `:compensating` workflows that never
      reached `:compensated` or `:compensation_failed`
    * disabled schedules — scheduled workflows auto-disabled after
      repeated failures

  Pass `--fix` to invoke the adapter's recovery (same path the
  background `StaleJobRecovery` GenServer runs on its interval).

  ## Usage

      mix durable.doctor [--fix] [--name NAME]

  ## Options

  * `--fix` - Run recovery for stale locks + zombies after reporting
  * `--json` - Emit the findings as JSON
  * `--name NAME` - The Durable instance name (default: Durable)
  """

  use Mix.Task

  alias Durable.Mix.Helpers
  alias Durable.Queue.Adapter
  alias Durable.Repo
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, ScheduledWorkflow, WorkflowExecution}

  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started_readonly()

    {opts, _, _} =
      OptionParser.parse(args, strict: [fix: :boolean, json: :boolean, name: :string])

    durable_name = Helpers.get_durable_name(opts)
    config = Durable.Config.get(durable_name)

    report = %{
      zombies: find_zombies(config),
      stale_locks: find_stale_locks(config),
      stuck_compensating: find_stuck_compensating(config),
      disabled_schedules: find_disabled_schedules(config)
    }

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(Jason.encode!(report, pretty: true))
    else
      print_report(report, config)
    end

    if Keyword.get(opts, :fix, false), do: run_fix(durable_name)
  end

  # --- Finders ---------------------------------------------------------------

  # A zombie is a :waiting workflow with no pending inputs or events —
  # nothing can ever unblock it. StaleJobRecovery's adapter fix targets
  # exactly this shape; surfacing it separately here lets operators see
  # the problem without running recovery.
  defp find_zombies(config) do
    query =
      from(w in WorkflowExecution,
        as: :w,
        where: w.status == :waiting,
        where:
          not exists(
            from(p in PendingInput,
              where: p.workflow_id == parent_as(:w).id and p.status == :pending
            )
          ),
        where:
          not exists(
            from(e in PendingEvent,
              where: e.workflow_id == parent_as(:w).id and e.status == :pending
            )
          ),
        select: %{
          id: w.id,
          name: w.workflow_name,
          current_step: w.current_step,
          updated_at: w.updated_at
        },
        limit: 100
      )

    Repo.all(config, query)
  end

  defp find_stale_locks(config) do
    cutoff = DateTime.add(DateTime.utc_now(), -config.stale_lock_timeout, :second)

    query =
      from(w in WorkflowExecution,
        where: w.status == :running,
        where: not is_nil(w.locked_by),
        where: w.locked_at < ^cutoff,
        select: %{
          id: w.id,
          name: w.workflow_name,
          locked_by: w.locked_by,
          locked_at: w.locked_at
        },
        limit: 100
      )

    Repo.all(config, query)
  end

  # Compensation that got stuck before reaching a terminal state. Rare,
  # but devastating when it happens because the rollback is half-done.
  defp find_stuck_compensating(config) do
    cutoff = DateTime.add(DateTime.utc_now(), -config.stale_lock_timeout, :second)

    query =
      from(w in WorkflowExecution,
        where: w.status == :compensating,
        where: w.updated_at < ^cutoff,
        select: %{
          id: w.id,
          name: w.workflow_name,
          current_step: w.current_step,
          updated_at: w.updated_at
        },
        limit: 100
      )

    Repo.all(config, query)
  end

  defp find_disabled_schedules(config) do
    query =
      from(s in ScheduledWorkflow,
        where: not is_nil(s.auto_disabled_at),
        order_by: [desc: s.auto_disabled_at],
        select: %{
          id: s.id,
          name: s.name,
          consecutive_failures: s.consecutive_failures,
          auto_disabled_at: s.auto_disabled_at,
          last_error_at: s.last_error_at
        },
        limit: 100
      )

    Repo.all(config, query)
  end

  # --- Text output -----------------------------------------------------------

  defp print_report(report, config) do
    total =
      length(report.zombies) + length(report.stale_locks) +
        length(report.stuck_compensating) + length(report.disabled_schedules)

    header =
      "Durable doctor — #{inspect(config.name)}  (stale_lock_timeout=#{config.stale_lock_timeout}s)"

    Mix.shell().info(header)

    if total == 0 do
      Mix.shell().info("  No issues found.")
    else
      print_section(
        "Zombies (:waiting, no pending inputs/events)",
        report.zombies,
        &zombie_row/1,
        [
          "ID",
          "Workflow",
          "Current step",
          "Stuck since"
        ]
      )

      print_section(
        "Stale locks (:running, lock not refreshed)",
        report.stale_locks,
        &stale_row/1,
        [
          "ID",
          "Workflow",
          "Locked by",
          "Locked at"
        ]
      )

      print_section(
        "Stuck compensating",
        report.stuck_compensating,
        &compensating_row/1,
        ["ID", "Workflow", "Current step", "Since"]
      )

      print_section(
        "Disabled schedules",
        report.disabled_schedules,
        &schedule_row/1,
        ["Name", "Failures", "Disabled at", "Last error"]
      )
    end
  end

  defp print_section(_title, [], _row_fn, _headers), do: :ok

  defp print_section(title, rows, row_fn, headers) do
    Mix.shell().info("")
    Mix.shell().info("#{title}  (#{length(rows)})")

    rows
    |> Enum.map(row_fn)
    |> Helpers.format_table(headers)
    |> Enum.each(fn line -> Mix.shell().info("  #{line}") end)
  end

  defp zombie_row(z) do
    [
      Helpers.truncate_id(z.id),
      z.name,
      z.current_step || "—",
      Helpers.format_datetime(z.updated_at)
    ]
  end

  defp stale_row(s) do
    [Helpers.truncate_id(s.id), s.name, s.locked_by, Helpers.format_datetime(s.locked_at)]
  end

  defp compensating_row(c) do
    [
      Helpers.truncate_id(c.id),
      c.name,
      c.current_step || "—",
      Helpers.format_datetime(c.updated_at)
    ]
  end

  defp schedule_row(s) do
    [
      s.name,
      to_string(s.consecutive_failures),
      Helpers.format_datetime(s.auto_disabled_at),
      Helpers.format_datetime(s.last_error_at)
    ]
  end

  # --- Fix -------------------------------------------------------------------

  # We call the adapter directly (not `StaleJobRecovery.recover_now/1`)
  # because this task runs with queue processing disabled, so the
  # StaleJobRecovery GenServer isn't in the supervision tree.
  defp run_fix(durable_name) do
    config = Durable.Config.get(durable_name)
    adapter = Adapter.default_adapter()

    Mix.shell().info("")
    Mix.shell().info("Running recovery...")

    run_stale_lock_fix(adapter, config)
    run_zombie_fix(adapter, config)
  end

  defp run_stale_lock_fix(adapter, config) do
    case adapter.recover_stale_locks(config, config.stale_lock_timeout) do
      {:ok, count} -> Mix.shell().info("  Stale-lock recovery: #{count} row(s)")
      {:error, reason} -> Mix.shell().error("  Stale-lock recovery failed: #{inspect(reason)}")
    end
  end

  defp run_zombie_fix(adapter, config) do
    if function_exported?(adapter, :recover_zombie_workflows, 2) do
      case adapter.recover_zombie_workflows(config, config.stale_lock_timeout) do
        {:ok, count} -> Mix.shell().info("  Zombie recovery:     #{count} row(s)")
        {:error, reason} -> Mix.shell().error("  Zombie recovery failed: #{inspect(reason)}")
      end
    else
      Mix.shell().info("  Zombie recovery:     adapter does not implement it, skipping")
    end
  end
end
