defmodule Mix.Tasks.Durable.Cleanup do
  @shortdoc "Deletes old workflow executions"

  @moduledoc """
  Deletes old workflow executions from the database.

  Cascade deletes handle associated step executions, pending inputs, and events.

  ## Usage

      mix durable.cleanup --older-than DURATION [options]

  ## Options

  * `--older-than DURATION` - Required. Delete executions older than this duration.
    Supports: `30d` (days), `24h` (hours), `60m` (minutes)
  * `--status STATUS` - Only delete executions with this status (default: completed, failed).
    Can be specified multiple times.
  * `--dry-run` - Show how many records would be deleted without deleting
  * `--batch-size N` - Number of records to delete per batch (default: 1000)
  * `--name NAME` - The Durable instance name (default: Durable)

  ## Examples

      mix durable.cleanup --older-than 30d
      mix durable.cleanup --older-than 24h --status completed --dry-run
      mix durable.cleanup --older-than 7d --batch-size 500
  """

  use Mix.Task

  import Ecto.Query

  alias Durable.Config
  alias Durable.Mix.Helpers
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

  @default_statuses [:completed, :failed]
  @default_batch_size 1000

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          older_than: :string,
          status: [:string, :keep],
          dry_run: :boolean,
          batch_size: :integer,
          name: :string
        ]
      )

    with {:ok, cutoff} <- parse_older_than(opts),
         {:ok, statuses} <- parse_statuses(opts) do
      durable_name = Helpers.get_durable_name(opts)
      config = Config.get(durable_name)
      dry_run = Keyword.get(opts, :dry_run, false)
      batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

      if dry_run do
        run_dry(config, cutoff, statuses)
      else
        run_cleanup(config, cutoff, statuses, batch_size)
      end
    end
  end

  defp parse_older_than(opts) do
    case Keyword.get(opts, :older_than) do
      nil ->
        Mix.shell().error("--older-than is required. Example: --older-than 30d")
        :error

      duration_str ->
        parse_duration(duration_str)
    end
  end

  defp parse_duration(str) do
    case Regex.run(~r/^(\d+)([dhm])$/, str) do
      [_, num_str, unit] ->
        num = String.to_integer(num_str)
        seconds = duration_to_seconds(num, unit)
        cutoff = DateTime.add(DateTime.utc_now(), -seconds, :second)
        {:ok, cutoff}

      nil ->
        Mix.shell().error(
          "Invalid duration: #{str}. Use format like 30d (days), 24h (hours), or 60m (minutes)."
        )

        :error
    end
  end

  defp duration_to_seconds(num, "d"), do: num * 86_400
  defp duration_to_seconds(num, "h"), do: num * 3_600
  defp duration_to_seconds(num, "m"), do: num * 60

  defp parse_statuses(opts) do
    case Keyword.get_values(opts, :status) do
      [] ->
        {:ok, @default_statuses}

      status_strings ->
        statuses =
          Enum.map(status_strings, fn s ->
            String.to_existing_atom(s)
          end)

        {:ok, statuses}
    end
  rescue
    ArgumentError ->
      Mix.shell().error("Invalid status provided.")
      :error
  end

  defp run_dry(config, cutoff, statuses) do
    count = count_matching(config, cutoff, statuses)
    status_str = Enum.map_join(statuses, ", ", &to_string/1)

    Mix.shell().info(
      "Dry run: #{Helpers.format_number(count)} executions would be deleted " <>
        "(status: #{status_str}, older than #{Helpers.format_datetime(cutoff)})."
    )
  end

  defp run_cleanup(config, cutoff, statuses, batch_size) do
    total = do_batch_delete(config, cutoff, statuses, batch_size, 0)
    Mix.shell().info("Deleted #{Helpers.format_number(total)} workflow executions.")
  end

  defp do_batch_delete(config, cutoff, statuses, batch_size, acc) do
    ids_query =
      from(w in WorkflowExecution,
        where: w.status in ^statuses and w.inserted_at < ^cutoff,
        select: w.id,
        limit: ^batch_size
      )

    delete_query = from(w in WorkflowExecution, where: w.id in subquery(ids_query))
    {deleted, _} = Repo.delete_all(config, delete_query)

    if deleted > 0 do
      do_batch_delete(config, cutoff, statuses, batch_size, acc + deleted)
    else
      acc
    end
  end

  defp count_matching(config, cutoff, statuses) do
    query =
      from(w in WorkflowExecution,
        where: w.status in ^statuses and w.inserted_at < ^cutoff,
        select: count(w.id)
      )

    Repo.one(config, query)
  end
end
