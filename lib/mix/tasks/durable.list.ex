defmodule Mix.Tasks.Durable.List do
  @shortdoc "Lists workflow executions"

  @moduledoc """
  Lists workflow executions with optional filters.

  ## Usage

      mix durable.list [options]

  ## Options

  * `--status STATUS` - Filter by status (pending, running, completed, failed, etc.)
  * `--workflow MODULE` - Filter by workflow module
  * `--queue QUEUE` - Filter by queue name
  * `--since DATETIME` - Show executions since ISO 8601 datetime
  * `--until DATETIME` - Show executions until ISO 8601 datetime
  * `--limit N` - Maximum number of results (default: 50)
  * `--format FORMAT` - Output format: table or json (default: table)
  * `--name NAME` - The Durable instance name (default: Durable)
  """

  use Mix.Task

  alias Durable.Mix.Helpers
  alias Durable.Query

  @valid_statuses ~w(pending running completed failed waiting cancelled
                     compensating compensated compensation_failed)

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started()

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          status: :string,
          workflow: :string,
          queue: :string,
          since: :string,
          until: :string,
          limit: :integer,
          format: :string,
          name: :string
        ]
      )

    durable_name = Helpers.get_durable_name(opts)

    case build_filters(opts, durable_name) do
      {:ok, filters} ->
        executions = Query.list_executions(filters)
        format = Keyword.get(opts, :format, "table")
        output(executions, format)

      {:error, message} ->
        Mix.shell().error(message)
    end
  end

  defp build_filters(opts, durable_name) do
    filters = [durable: durable_name]

    with {:ok, filters} <- add_status(filters, opts),
         {:ok, filters} <- add_workflow(filters, opts),
         {:ok, filters} <- add_queue(filters, opts),
         {:ok, filters} <- add_since(filters, opts),
         {:ok, filters} <- add_until(filters, opts) do
      limit = Keyword.get(opts, :limit, 50)
      {:ok, Keyword.put(filters, :limit, limit)}
    end
  end

  defp add_status(filters, opts) do
    case Keyword.get(opts, :status) do
      nil ->
        {:ok, filters}

      status_str ->
        if status_str in @valid_statuses do
          {:ok, Keyword.put(filters, :status, String.to_existing_atom(status_str))}
        else
          {:error,
           "Invalid status: #{status_str}. Valid statuses: #{Enum.join(@valid_statuses, ", ")}"}
        end
    end
  end

  defp add_workflow(filters, opts) do
    case Keyword.get(opts, :workflow) do
      nil -> {:ok, filters}
      mod_str -> {:ok, Keyword.put(filters, :workflow, Module.concat([mod_str]))}
    end
  end

  defp add_queue(filters, opts) do
    case Keyword.get(opts, :queue) do
      nil -> {:ok, filters}
      queue -> {:ok, Keyword.put(filters, :queue, queue)}
    end
  end

  defp add_since(filters, opts) do
    parse_datetime(filters, opts, :since, :from)
  end

  defp add_until(filters, opts) do
    parse_datetime(filters, opts, :until, :to)
  end

  defp parse_datetime(filters, opts, opt_key, filter_key) do
    case Keyword.get(opts, opt_key) do
      nil ->
        {:ok, filters}

      dt_str ->
        case DateTime.from_iso8601(dt_str) do
          {:ok, dt, _offset} ->
            {:ok, Keyword.put(filters, filter_key, dt)}

          {:error, _} ->
            {:error, "Invalid datetime for --#{opt_key}: #{dt_str}. Use ISO 8601 format."}
        end
    end
  end

  defp output(executions, "json") do
    data =
      Enum.map(executions, fn exec ->
        %{
          id: exec.id,
          workflow_module: exec.workflow_module,
          workflow_name: exec.workflow_name,
          status: exec.status,
          queue: exec.queue,
          started_at: exec.started_at && DateTime.to_iso8601(exec.started_at),
          completed_at: exec.completed_at && DateTime.to_iso8601(exec.completed_at)
        }
      end)

    Mix.shell().info(Jason.encode!(data, pretty: true))
  end

  defp output(executions, _table) do
    if executions == [] do
      Mix.shell().info("No workflow executions found.")
    else
      rows =
        Enum.map(executions, fn exec ->
          [
            Helpers.truncate_id(exec.id),
            Helpers.strip_elixir_prefix(exec.workflow_module),
            to_string(exec.status),
            exec.queue,
            Helpers.format_datetime(exec.started_at),
            Helpers.format_duration(exec.started_at, exec.completed_at)
          ]
        end)

      headers = ["ID", "Workflow", "Status", "Queue", "Started", "Duration"]

      Helpers.format_table(rows, headers)
      |> Enum.each(fn line -> Mix.shell().info(line) end)
    end
  end
end
