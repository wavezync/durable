defmodule Mix.Tasks.Durable.Cancel do
  @shortdoc "Cancels a workflow execution"

  @moduledoc """
  Cancels a running, pending, or waiting workflow execution.

  ## Usage

      mix durable.cancel WORKFLOW_ID [options]

  ## Options

  * `--reason REASON` - Cancellation reason
  * `--name NAME` - The Durable instance name (default: Durable)

  ## Examples

      mix durable.cancel abc12345-...
      mix durable.cancel abc12345-... --reason "User requested cancellation"
  """

  use Mix.Task

  alias Durable.Executor
  alias Durable.Mix.Helpers

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started()

    {opts, positional, _} =
      OptionParser.parse(args, strict: [reason: :string, name: :string])

    case positional do
      [workflow_id | _] ->
        cancel_workflow(workflow_id, opts)

      [] ->
        Mix.shell().error("Usage: mix durable.cancel WORKFLOW_ID [--reason REASON]")
    end
  end

  defp cancel_workflow(workflow_id, opts) do
    durable_name = Helpers.get_durable_name(opts)
    reason = Keyword.get(opts, :reason)

    case Executor.cancel_workflow(workflow_id, reason, durable: durable_name) do
      :ok ->
        Mix.shell().info("Workflow #{Helpers.truncate_id(workflow_id)} cancelled.")

      {:error, :not_found} ->
        Mix.shell().error("Workflow #{workflow_id} not found.")

      {:error, :already_completed} ->
        Mix.shell().error(
          "Workflow #{workflow_id} has already completed and cannot be cancelled."
        )
    end
  end
end
