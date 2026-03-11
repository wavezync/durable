defmodule Mix.Tasks.Durable.Run do
  @shortdoc "Starts a workflow execution"

  @moduledoc """
  Starts a workflow execution.

  ## Usage

      mix durable.run MODULE [options]

  ## Options

  * `--input JSON` - JSON input for the workflow (must be an object)
  * `--workflow NAME` - The workflow name within the module
  * `--queue QUEUE` - The queue to run on (default: "default")
  * `--priority N` - Priority level (default: 0)
  * `--name NAME` - The Durable instance name (default: Durable)

  ## Examples

      mix durable.run MyApp.OrderWorkflow
      mix durable.run MyApp.OrderWorkflow --input '{"order_id": 123}'
      mix durable.run MyApp.OrderWorkflow --workflow process_order --queue high_priority
  """

  use Mix.Task

  alias Durable.Mix.Helpers

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started()

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          input: :string,
          workflow: :string,
          queue: :string,
          priority: :integer,
          name: :string
        ]
      )

    case positional do
      [module_str | _] ->
        start_workflow(module_str, opts)

      [] ->
        Mix.shell().error(
          "Usage: mix durable.run MODULE [--input JSON] [--workflow NAME] [--queue QUEUE]"
        )
    end
  end

  defp start_workflow(module_str, opts) do
    durable_name = Helpers.get_durable_name(opts)
    module = Module.concat([module_str])

    with :ok <- validate_module(module),
         {:ok, input} <- parse_input(opts),
         {:ok, start_opts} <- build_opts(opts, durable_name) do
      case Durable.Executor.start_workflow(module, input, start_opts) do
        {:ok, workflow_id} ->
          Mix.shell().info("Workflow started: #{workflow_id}")

        {:error, reason} ->
          Mix.shell().error("Failed to start workflow: #{inspect(reason)}")
      end
    end
  end

  defp validate_module(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        Mix.shell().error("Module #{inspect(module)} not found.")
        :error

      not function_exported?(module, :__workflows__, 0) ->
        Mix.shell().error("Module #{inspect(module)} is not a Durable workflow.")
        :error

      true ->
        :ok
    end
  end

  defp parse_input(opts) do
    case Keyword.get(opts, :input) do
      nil ->
        {:ok, %{}}

      json_str ->
        case Jason.decode(json_str) do
          {:ok, input} when is_map(input) ->
            {:ok, input}

          {:ok, _} ->
            Mix.shell().error("Input must be a JSON object, not an array or scalar.")
            :error

          {:error, %Jason.DecodeError{} = error} ->
            Mix.shell().error("Invalid JSON input: #{Exception.message(error)}")
            :error
        end
    end
  end

  defp build_opts(opts, durable_name) do
    start_opts = [durable: durable_name]

    start_opts =
      case Keyword.get(opts, :workflow) do
        nil -> start_opts
        name -> Keyword.put(start_opts, :workflow, name)
      end

    start_opts =
      case Keyword.get(opts, :queue) do
        nil -> start_opts
        queue -> Keyword.put(start_opts, :queue, queue)
      end

    start_opts =
      case Keyword.get(opts, :priority) do
        nil -> start_opts
        priority -> Keyword.put(start_opts, :priority, priority)
      end

    {:ok, start_opts}
  end
end
