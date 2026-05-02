defmodule Mix.Tasks.Durable.Pending do
  @shortdoc "Lists pending inputs and events blocking workflows"

  @moduledoc """
  Lists outstanding pending inputs and pending events across all
  workflows. Use this to answer "what is waiting on me?" without
  clicking through the dashboard.

  ## Usage

      mix durable.pending [options]

  ## Options

  * `--inputs` - Only list pending inputs
  * `--events` - Only list pending events
  * `--limit N` - Max rows per section (default: 50)
  * `--expiring-in HOURS` - Only show rows that time out within N hours
  * `--json` - Emit JSON instead of tables
  * `--name NAME` - The Durable instance name (default: Durable)
  """

  use Mix.Task

  alias Durable.Mix.Helpers
  alias Durable.Repo
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WorkflowExecution}

  import Ecto.Query

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started_readonly()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          inputs: :boolean,
          events: :boolean,
          limit: :integer,
          expiring_in: :integer,
          json: :boolean,
          name: :string
        ]
      )

    durable_name = Helpers.get_durable_name(opts)
    only_inputs = Keyword.get(opts, :inputs, false)
    only_events = Keyword.get(opts, :events, false)

    show_inputs = only_inputs or not only_events
    show_events = only_events or not only_inputs

    inputs = if show_inputs, do: fetch_inputs(durable_name, opts), else: []
    events = if show_events, do: fetch_events(durable_name, opts), else: []

    if Keyword.get(opts, :json, false) do
      emit_json(%{pending_inputs: inputs, pending_events: events})
    else
      emit_text(inputs, show_inputs, events, show_events)
    end
  end

  defp fetch_inputs(durable_name, opts) do
    config = Durable.Config.get(durable_name)
    limit = Keyword.get(opts, :limit, 50)
    cutoff = expiring_cutoff(opts)

    base =
      from(p in PendingInput,
        join: w in WorkflowExecution,
        on: p.workflow_id == w.id,
        where: p.status == :pending,
        order_by: [asc: p.timeout_at, asc: p.inserted_at],
        limit: ^limit,
        select: %{
          workflow_id: p.workflow_id,
          workflow_name: w.workflow_name,
          name: p.input_name,
          type: p.input_type,
          step: p.step_name,
          timeout_at: p.timeout_at,
          inserted_at: p.inserted_at
        }
      )

    base
    |> apply_expiring(cutoff)
    |> then(&Repo.all(config, &1))
  end

  defp fetch_events(durable_name, opts) do
    config = Durable.Config.get(durable_name)
    limit = Keyword.get(opts, :limit, 50)
    cutoff = expiring_cutoff(opts)

    base =
      from(p in PendingEvent,
        join: w in WorkflowExecution,
        on: p.workflow_id == w.id,
        where: p.status == :pending,
        order_by: [asc: p.timeout_at, asc: p.inserted_at],
        limit: ^limit,
        select: %{
          workflow_id: p.workflow_id,
          workflow_name: w.workflow_name,
          name: p.event_name,
          wait_type: p.wait_type,
          timeout_at: p.timeout_at,
          inserted_at: p.inserted_at
        }
      )

    base
    |> apply_expiring(cutoff)
    |> then(&Repo.all(config, &1))
  end

  defp expiring_cutoff(opts) do
    case Keyword.get(opts, :expiring_in) do
      nil -> nil
      hours -> DateTime.add(DateTime.utc_now(), hours * 3600, :second)
    end
  end

  defp apply_expiring(query, nil), do: query

  defp apply_expiring(query, cutoff) do
    from(p in query, where: not is_nil(p.timeout_at) and p.timeout_at <= ^cutoff)
  end

  defp emit_json(payload), do: Mix.shell().info(Jason.encode!(payload, pretty: true))

  defp emit_text(inputs, true, events, true) do
    print_inputs(inputs)
    Mix.shell().info("")
    print_events(events)
  end

  defp emit_text(inputs, true, _events, false), do: print_inputs(inputs)
  defp emit_text(_inputs, false, events, true), do: print_events(events)
  defp emit_text(_, _, _, _), do: :ok

  defp print_inputs([]) do
    Mix.shell().info("Pending inputs")
    Mix.shell().info("  (none)")
  end

  defp print_inputs(inputs) do
    Mix.shell().info("Pending inputs (#{length(inputs)})")

    rows =
      Enum.map(inputs, fn row ->
        [
          Helpers.truncate_id(row.workflow_id),
          row.workflow_name,
          row.name,
          to_string(row.type),
          row.step,
          format_timeout(row.timeout_at),
          Helpers.format_seconds(age_seconds(row.inserted_at))
        ]
      end)

    headers = ["Workflow", "Name", "Input", "Type", "Step", "Timeout", "Age"]

    Helpers.format_table(rows, headers)
    |> Enum.each(fn line -> Mix.shell().info("  #{line}") end)
  end

  defp print_events([]) do
    Mix.shell().info("Pending events")
    Mix.shell().info("  (none)")
  end

  defp print_events(events) do
    Mix.shell().info("Pending events (#{length(events)})")

    rows =
      Enum.map(events, fn row ->
        [
          Helpers.truncate_id(row.workflow_id),
          row.workflow_name,
          row.name,
          to_string(row.wait_type),
          format_timeout(row.timeout_at),
          Helpers.format_seconds(age_seconds(row.inserted_at))
        ]
      end)

    headers = ["Workflow", "Name", "Event", "Wait", "Timeout", "Age"]

    Helpers.format_table(rows, headers)
    |> Enum.each(fn line -> Mix.shell().info("  #{line}") end)
  end

  defp format_timeout(nil), do: "—"

  # Show relative "in 2h" for future timeouts, "overdue 5m" for past ones —
  # fastest way to spot rows that should already have been handled.
  defp format_timeout(dt) do
    diff = DateTime.diff(dt, DateTime.utc_now(), :second)

    if diff > 0 do
      "in #{Helpers.format_seconds(diff)}"
    else
      "overdue #{Helpers.format_seconds(-diff)}"
    end
  end

  defp age_seconds(inserted_at) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :second)
  end
end
