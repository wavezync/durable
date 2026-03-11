defmodule Mix.Tasks.Durable.Status do
  @shortdoc "Shows Durable queue status and workflow summary"

  @moduledoc """
  Shows Durable queue status and workflow summary.

  ## Usage

      mix durable.status [--name NAME]

  ## Options

  * `--name` - The Durable instance name (default: Durable)
  """

  use Mix.Task

  alias Durable.Mix.Helpers
  alias Durable.Query
  alias Durable.Queue.Manager

  @statuses [
    :pending,
    :running,
    :completed,
    :failed,
    :waiting,
    :cancelled,
    :compensating,
    :compensated,
    :compensation_failed
  ]

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started()
    {opts, _, _} = OptionParser.parse(args, strict: [name: :string])
    durable_name = Helpers.get_durable_name(opts)

    print_queue_status(durable_name)
    Mix.shell().info("")
    print_workflow_summary(durable_name)
  end

  defp print_queue_status(durable_name) do
    queues = Manager.queues(durable_name)

    rows =
      Enum.map(queues, fn queue ->
        db_stats = Manager.stats(durable_name, queue)
        poller_status = get_poller_status(durable_name, queue)

        [
          queue,
          poller_status[:concurrency] || "N/A",
          poller_status[:active_jobs] || "N/A",
          format_paused(poller_status[:paused]),
          db_stats.pending,
          db_stats.running
        ]
      end)

    headers = ["Queue", "Concurrency", "Active", "Paused", "Pending", "Running"]

    Mix.shell().info("Queue Status (#{inspect(durable_name)})")

    Helpers.format_table(rows, headers)
    |> Enum.each(fn line -> Mix.shell().info("  #{line}") end)
  end

  defp get_poller_status(durable_name, queue) do
    status = Manager.status(durable_name, queue)

    %{
      concurrency: status.concurrency,
      active_jobs: status.active_jobs,
      paused: status.paused
    }
  rescue
    _ -> %{concurrency: nil, active_jobs: nil, paused: nil}
  catch
    :exit, _ -> %{concurrency: nil, active_jobs: nil, paused: nil}
  end

  defp format_paused(nil), do: "N/A"
  defp format_paused(true), do: "yes"
  defp format_paused(false), do: "no"

  defp print_workflow_summary(durable_name) do
    rows =
      @statuses
      |> Enum.map(fn status ->
        count = Query.count_executions(status: status, durable: durable_name)
        {status, count}
      end)
      |> Enum.filter(fn {_, count} -> count > 0 end)
      |> Enum.map(fn {status, count} ->
        [to_string(status), Helpers.format_number(count)]
      end)

    Mix.shell().info("Workflow Summary")

    if rows == [] do
      Mix.shell().info("  No workflow executions found.")
    else
      Helpers.format_table(rows, ["Status", "Count"])
      |> Enum.each(fn line -> Mix.shell().info("  #{line}") end)
    end
  end
end
