defmodule Mix.Tasks.Durable.Retry do
  @shortdoc "Starts a fresh execution of a workflow using a prior run's input"

  @moduledoc """
  Starts a NEW workflow execution with the same module, queue, and
  input as an existing one. This matches what the dashboard's "Retry"
  button does — it does not resume the original execution in place.

  Useful after a `:failed` or `:cancelled` run when you want to try
  again with identical input.

  ## Usage

      mix durable.retry WORKFLOW_ID [--name NAME]

  `WORKFLOW_ID` accepts a unique prefix.

  ## Options

  * `--name NAME` - The Durable instance name (default: Durable)
  """

  use Mix.Task

  alias Durable.Mix.Helpers
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started_readonly()

    {opts, positional, _} = OptionParser.parse(args, strict: [name: :string])

    case positional do
      [id | _] ->
        durable = Helpers.get_durable_name(opts)

        case Helpers.resolve_workflow_id(durable, id) do
          {:ok, resolved_id} -> retry(resolved_id, durable)
          {:error, :not_found} -> Mix.shell().error("No workflow matches: #{id}")
          {:error, :ambiguous, ms} -> Mix.shell().error("Ambiguous:\n  " <> Enum.join(ms, "\n  "))
        end

      [] ->
        Mix.shell().error("Usage: mix durable.retry WORKFLOW_ID")
    end
  end

  defp retry(id, durable) do
    config = Durable.Config.get(durable)

    case Repo.get(config, WorkflowExecution, id) do
      nil ->
        Mix.shell().error("Workflow #{id} vanished between resolution and retry.")

      exec ->
        module = Module.safe_concat([exec.workflow_module])

        case Durable.start(module, exec.input, queue: exec.queue, durable: durable) do
          {:ok, new_id} ->
            Mix.shell().info(
              "Started new execution #{Helpers.truncate_id(new_id)} " <>
                "(retry of #{Helpers.truncate_id(id)})"
            )

            Mix.shell().info("  module: #{Helpers.strip_elixir_prefix(exec.workflow_module)}")
            Mix.shell().info("  queue:  #{exec.queue}")

          {:error, reason} ->
            Mix.shell().error("Failed to start retry: #{inspect(reason)}")
        end
    end
  rescue
    ArgumentError ->
      Mix.shell().error(
        "Could not load module #{inspect(:ignored)} — is the workflow module available?"
      )
  end
end
