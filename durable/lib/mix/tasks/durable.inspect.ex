defmodule Mix.Tasks.Durable.Inspect do
  @shortdoc "Shows detailed state of a single workflow execution"

  @moduledoc """
  Deep-dive on a single workflow execution. Use this as the first stop
  when a workflow is stuck or behaving unexpectedly — it prints the
  header, step timeline (including wait/resume pairs), pending inputs
  and events, parent/children, and any error.

  ## Usage

      mix durable.inspect WORKFLOW_ID [options]

  `WORKFLOW_ID` may be a full UUID or a unique prefix (the task will
  refuse ambiguous prefixes rather than guess).

  ## Options

  * `--json` - Emit a JSON document instead of the text report
  * `--context` - Include full context as pretty JSON (default: truncated)
  * `--name NAME` - The Durable instance name (default: Durable)
  """

  use Mix.Task

  alias Durable.Mix.Helpers
  alias Durable.Repo
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, StepExecution, WorkflowExecution}

  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started_readonly()

    {opts, positional, _} =
      OptionParser.parse(args, strict: [json: :boolean, context: :boolean, name: :string])

    case positional do
      [id | _] -> inspect_workflow(id, opts)
      [] -> Mix.shell().error("Usage: mix durable.inspect WORKFLOW_ID [--json] [--context]")
    end
  end

  defp inspect_workflow(input, opts) do
    durable_name = Helpers.get_durable_name(opts)

    with {:ok, id} <- resolve_id(durable_name, input),
         {:ok, report} <- collect_report(durable_name, id) do
      if Keyword.get(opts, :json, false) do
        Mix.shell().info(Jason.encode!(report, pretty: true))
      else
        print_text_report(report, opts)
      end
    else
      {:error, :not_found} ->
        Mix.shell().error("No workflow matches: #{input}")

      {:error, :ambiguous, matches} ->
        Mix.shell().error(
          "Prefix matches #{length(matches)} workflows — narrow it down:\n  " <>
            Enum.join(matches, "\n  ")
        )
    end
  end

  defp resolve_id(durable_name, input), do: Helpers.resolve_workflow_id(durable_name, input)

  defp collect_report(durable_name, id) do
    config = Durable.Config.get(durable_name)

    case Repo.get(config, WorkflowExecution, id) do
      nil ->
        {:error, :not_found}

      execution ->
        steps = fetch_steps(config, id)
        pending_inputs = fetch_pending_inputs(config, id)
        pending_events = fetch_pending_events(config, id)
        children = fetch_children(config, id)

        report = %{
          workflow: serialize_workflow(execution),
          step_timeline: serialize_steps(steps),
          pending_inputs: Enum.map(pending_inputs, &serialize_pending_input/1),
          pending_events: Enum.map(pending_events, &serialize_pending_event/1),
          children: Enum.map(children, &serialize_child/1)
        }

        {:ok, report}
    end
  end

  defp fetch_steps(config, id) do
    Repo.all(
      config,
      from(s in StepExecution, where: s.workflow_id == ^id, order_by: [asc: s.inserted_at])
    )
  end

  defp fetch_pending_inputs(config, id) do
    Repo.all(
      config,
      from(p in PendingInput, where: p.workflow_id == ^id, order_by: [asc: p.inserted_at])
    )
  end

  defp fetch_pending_events(config, id) do
    Repo.all(
      config,
      from(p in PendingEvent, where: p.workflow_id == ^id, order_by: [asc: p.inserted_at])
    )
  end

  defp fetch_children(config, id) do
    Repo.all(
      config,
      from(w in WorkflowExecution,
        where: w.parent_workflow_id == ^id,
        order_by: [asc: w.inserted_at]
      )
    )
  end

  # --- Serialization ---------------------------------------------------------

  defp serialize_workflow(exec) do
    %{
      id: exec.id,
      module: Helpers.strip_elixir_prefix(exec.workflow_module),
      name: exec.workflow_name,
      status: exec.status,
      current_step: exec.current_step,
      queue: exec.queue,
      priority: exec.priority,
      parent_workflow_id: exec.parent_workflow_id,
      inserted_at: exec.inserted_at,
      started_at: exec.started_at,
      completed_at: exec.completed_at,
      scheduled_at: exec.scheduled_at,
      locked_by: exec.locked_by,
      locked_at: exec.locked_at,
      duration: Helpers.format_duration(exec.started_at, exec.completed_at),
      error: exec.error,
      context: exec.context,
      input: exec.input
    }
  end

  # Group step rows by step_name and emit a timeline that clearly shows
  # wait/resume pairs — operators need to see BOTH the pause and the
  # resume to reason about what actually happened.
  defp serialize_steps(steps) do
    steps
    |> Enum.group_by(& &1.step_name)
    |> Enum.map(fn {name, rows} ->
      sorted = Enum.sort_by(rows, & &1.inserted_at, DateTime)
      latest = List.last(sorted)

      %{
        step_name: name,
        step_type: latest.step_type,
        latest_status: latest.status,
        attempts: Enum.map(sorted, &serialize_step_row/1)
      }
    end)
    |> Enum.sort_by(fn %{attempts: [first | _]} -> first.inserted_at end, DateTime)
  end

  defp serialize_step_row(row) do
    %{
      status: row.status,
      attempt: row.attempt,
      inserted_at: row.inserted_at,
      started_at: row.started_at,
      completed_at: row.completed_at,
      duration_ms: row.duration_ms,
      error: row.error
    }
  end

  defp serialize_pending_input(p) do
    %{
      input_name: p.input_name,
      input_type: p.input_type,
      status: p.status,
      step_name: p.step_name,
      prompt: p.prompt,
      timeout_at: p.timeout_at,
      inserted_at: p.inserted_at,
      completed_at: p.completed_at
    }
  end

  defp serialize_pending_event(p) do
    %{
      event_name: p.event_name,
      status: p.status,
      wait_type: p.wait_type,
      timeout_at: p.timeout_at,
      inserted_at: p.inserted_at,
      completed_at: p.completed_at
    }
  end

  defp serialize_child(w) do
    %{
      id: w.id,
      name: w.workflow_name,
      status: w.status,
      current_step: w.current_step,
      inserted_at: w.inserted_at,
      completed_at: w.completed_at
    }
  end

  # --- Text output -----------------------------------------------------------

  defp print_text_report(%{workflow: wf} = report, opts) do
    info = fn msg -> Mix.shell().info(msg) end
    info.("")
    info.("Workflow  #{wf.id}")
    info.("  #{wf.module} · #{wf.name}")
    info.("  Status:      #{wf.status}#{current_step_suffix(wf)}")
    info.("  Queue:       #{wf.queue}   Priority: #{wf.priority}")
    info.("  Created:     #{Helpers.format_datetime(wf.inserted_at)}")
    info.("  Started:     #{Helpers.format_datetime(wf.started_at)}")
    info.("  Completed:   #{Helpers.format_datetime(wf.completed_at)}")
    info.("  Duration:    #{wf.duration}")

    maybe_print_lock(info, wf)
    maybe_print_parent(info, wf)
    maybe_print_error(info, wf)

    print_steps(info, report.step_timeline)
    print_pending_inputs(info, report.pending_inputs)
    print_pending_events(info, report.pending_events)
    print_children(info, report.children)

    print_context(info, wf.context, Keyword.get(opts, :context, false))

    diagnose(info, report)
    info.("")
  end

  defp current_step_suffix(%{current_step: nil}), do: ""
  defp current_step_suffix(%{current_step: step}), do: " (at #{step})"

  defp maybe_print_lock(_info, %{locked_by: nil}), do: :ok

  defp maybe_print_lock(info, wf) do
    info.("  Locked by:   #{wf.locked_by} at #{Helpers.format_datetime(wf.locked_at)}")
  end

  defp maybe_print_parent(_info, %{parent_workflow_id: nil}), do: :ok

  defp maybe_print_parent(info, wf) do
    info.("  Parent:      #{wf.parent_workflow_id}")
  end

  defp maybe_print_error(_info, %{error: nil}), do: :ok
  defp maybe_print_error(_info, %{error: err}) when err == %{}, do: :ok

  defp maybe_print_error(info, %{error: err}) do
    info.("")
    info.("Error")

    err
    |> Jason.encode!(pretty: true)
    |> String.split("\n")
    |> Enum.each(fn line -> info.("  #{line}") end)
  end

  defp print_steps(info, []), do: info.("\nSteps  (no step executions yet)")

  defp print_steps(info, steps) do
    info.("")
    info.("Steps")

    rows =
      Enum.map(steps, fn step ->
        [
          step.step_name,
          to_string(step.step_type),
          to_string(step.latest_status),
          length(step.attempts),
          duration_for(step),
          resume_note(step)
        ]
      end)

    headers = ["Step", "Type", "Status", "Rows", "Duration", "Note"]

    Helpers.format_table(rows, headers)
    |> Enum.each(fn line -> info.("  #{line}") end)
  end

  defp duration_for(%{attempts: attempts}) do
    case List.last(attempts) do
      %{duration_ms: nil} -> "—"
      %{duration_ms: ms} -> "#{ms}ms"
    end
  end

  # Multiple rows per step_name means the step paused (wait_for_*) and
  # then resumed; flag that so operators don't read a completed step as
  # "never waited".
  defp resume_note(%{attempts: attempts}) when length(attempts) > 1, do: "wait→resume"
  defp resume_note(_), do: ""

  defp print_pending_inputs(_info, []), do: :ok

  defp print_pending_inputs(info, inputs) do
    info.("")
    info.("Pending inputs")

    rows =
      Enum.map(inputs, fn p ->
        [
          p.input_name,
          to_string(p.input_type),
          to_string(p.status),
          Helpers.format_datetime(p.timeout_at),
          p.step_name
        ]
      end)

    Helpers.format_table(rows, ["Name", "Type", "Status", "Timeout at", "Step"])
    |> Enum.each(fn line -> info.("  #{line}") end)
  end

  defp print_pending_events(_info, []), do: :ok

  defp print_pending_events(info, events) do
    info.("")
    info.("Pending events")

    rows =
      Enum.map(events, fn p ->
        [
          p.event_name,
          to_string(p.status),
          to_string(p.wait_type),
          Helpers.format_datetime(p.timeout_at)
        ]
      end)

    Helpers.format_table(rows, ["Name", "Status", "Type", "Timeout at"])
    |> Enum.each(fn line -> info.("  #{line}") end)
  end

  defp print_children(_info, []), do: :ok

  defp print_children(info, children) do
    info.("")
    info.("Children")

    rows =
      Enum.map(children, fn c ->
        [Helpers.truncate_id(c.id), c.name, to_string(c.status), c.current_step || "—"]
      end)

    Helpers.format_table(rows, ["ID", "Name", "Status", "Step"])
    |> Enum.each(fn line -> info.("  #{line}") end)
  end

  defp print_context(_info, nil, _), do: :ok
  defp print_context(_info, ctx, _) when ctx == %{}, do: :ok

  defp print_context(info, ctx, true) do
    info.("")
    info.("Context")

    ctx
    |> Jason.encode!(pretty: true)
    |> String.split("\n")
    |> Enum.each(fn line -> info.("  #{line}") end)
  end

  defp print_context(info, ctx, false) do
    info.("")
    keys = Map.keys(ctx) |> Enum.map(&to_string/1) |> Enum.sort()

    preview =
      case keys do
        [] -> "(empty)"
        _ -> Enum.join(keys, ", ")
      end

    info.("Context keys (pass --context for full): #{preview}")
  end

  # Terse diagnostics — surface the most common "why is this stuck?"
  # signals so operators don't have to eyeball every field.
  defp diagnose(info, %{workflow: wf} = report) do
    findings = []
    findings = maybe_zombie(findings, wf, report)
    findings = maybe_stale_lock(findings, wf)
    findings = maybe_failed_no_compensation(findings, wf)

    unless findings == [] do
      info.("")
      info.("Diagnostics")
      Enum.each(findings, fn line -> info.("  • #{line}") end)
    end
  end

  defp maybe_zombie(findings, %{status: :waiting}, %{pending_inputs: [], pending_events: []}) do
    [
      "Status is :waiting but no pending inputs or events — likely a zombie. Run `mix durable.doctor --fix`."
      | findings
    ]
  end

  defp maybe_zombie(findings, _, _), do: findings

  defp maybe_stale_lock(findings, %{locked_by: nil}), do: findings

  defp maybe_stale_lock(findings, %{locked_at: locked_at}) do
    age = DateTime.diff(DateTime.utc_now(), locked_at, :second)

    if age > 600 do
      ["Lock is #{Helpers.format_seconds(age)} old — possible stale lock." | findings]
    else
      findings
    end
  end

  defp maybe_failed_no_compensation(findings, %{status: :failed} = wf) do
    if wf.error do
      ["Workflow failed. See the Error section above for details." | findings]
    else
      ["Workflow failed but no error payload was recorded — inspect the queue logs." | findings]
    end
  end

  defp maybe_failed_no_compensation(findings, _), do: findings
end
