defmodule Mix.Tasks.Durable.SendEvent do
  @shortdoc "Sends an event to a waiting workflow"

  @moduledoc """
  Delivers an event to a workflow that is suspended on
  `wait_for_event/2`, `wait_for_any/2`, or `wait_for_all/2`.

  Payload parsing rules match `mix durable.provide_input` — JSON when
  it looks like JSON, raw string otherwise.

  ## Usage

      mix durable.send_event WORKFLOW_ID EVENT_NAME PAYLOAD [options]

  ## Options

  * `--json-file PATH` - Read payload from a file instead
  * `--name NAME` - The Durable instance name (default: Durable)

  ## Examples

      mix durable.send_event ab12 payment_confirmed '{"amount":99.99}'
      mix durable.send_event ab12 shipping_update delivered
  """

  use Mix.Task

  alias Durable.Mix.Helpers

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started_readonly()

    {opts, positional, _} =
      OptionParser.parse(args, strict: [json_file: :string, name: :string])

    case positional do
      [id, event_name | rest] ->
        with {:ok, payload} <- build_payload(rest, opts),
             {:ok, resolved_id} <-
               Helpers.resolve_workflow_id(Helpers.get_durable_name(opts), id) do
          submit(resolved_id, event_name, payload, opts)
        else
          {:error, :ambiguous, matches} ->
            Mix.shell().error("Prefix is ambiguous:\n  " <> Enum.join(matches, "\n  "))

          {:error, :not_found} ->
            Mix.shell().error("No workflow matches: #{id}")

          {:error, reason} ->
            Mix.shell().error("Invalid payload: #{reason}")
        end

      _ ->
        Mix.shell().error(
          "Usage: mix durable.send_event WORKFLOW_ID EVENT_NAME PAYLOAD [--json-file PATH]"
        )
    end
  end

  defp submit(workflow_id, event_name, payload, opts) do
    durable = Helpers.get_durable_name(opts)

    case Durable.Wait.send_event(workflow_id, event_name, payload, durable: durable) do
      :ok ->
        Mix.shell().info("Sent event '#{event_name}' to #{Helpers.truncate_id(workflow_id)}.")

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  # Shares parsing with durable.provide_input. Keeping it duplicated is
  # cheaper than making a shared helper at this size, and each task
  # stays standalone.
  defp build_payload([], opts) do
    case Keyword.get(opts, :json_file) do
      nil ->
        {:error, "missing PAYLOAD positional arg or --json-file"}

      path ->
        with {:ok, body} <- read_file(path),
             {:ok, json} <- Jason.decode(body) do
          {:ok, json}
        else
          {:error, %Jason.DecodeError{} = e} -> {:error, Exception.message(e)}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  defp build_payload([raw | _], _opts), do: {:ok, parse_payload(raw)}

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp parse_payload(raw) do
    trimmed = String.trim(raw)

    if json_like?(trimmed) do
      case Jason.decode(trimmed) do
        {:ok, decoded} -> decoded
        _ -> raw
      end
    else
      raw
    end
  end

  defp json_like?(<<c, _::binary>>) when c in [?{, ?[, ?", ?-, ?t, ?f, ?n], do: true
  defp json_like?(<<c, _::binary>>) when c in ?0..?9, do: true
  defp json_like?(_), do: false
end
