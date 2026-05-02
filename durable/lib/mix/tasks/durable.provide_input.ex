defmodule Mix.Tasks.Durable.ProvideInput do
  @shortdoc "Provides a pending input to unblock a workflow"

  @moduledoc """
  Unblocks a workflow that is waiting on `wait_for_input/2` (or any of
  its convenience wrappers like `wait_for_approval`, `wait_for_choice`,
  `wait_for_text`, `wait_for_form`).

  Use this when the dashboard is down, when you want to script a
  response, or when you just prefer the terminal.

  ## Usage

      mix durable.provide_input WORKFLOW_ID INPUT_NAME DATA [options]

  `DATA` is parsed as JSON when it looks like JSON (objects, arrays,
  numbers, quoted strings, booleans, null); otherwise it is passed as
  a raw string. `WORKFLOW_ID` accepts a unique prefix.

  ## Options

  * `--json-file PATH` - Read the JSON payload from a file instead
  * `--name NAME` - The Durable instance name (default: Durable)

  ## Examples

      # A form response
      mix durable.provide_input ab12 equipment_preferences '{"laptop":"mac"}'

      # A single choice
      mix durable.provide_input ab12 orientation_slot morning

      # From a file
      mix durable.provide_input ab12 manager_approval --json-file approval.json
  """

  use Mix.Task

  alias Durable.Mix.Helpers

  @impl Mix.Task
  def run(args) do
    Helpers.ensure_started_readonly()

    {opts, positional, _} =
      OptionParser.parse(args, strict: [json_file: :string, name: :string])

    case positional do
      [id, input_name | rest] ->
        with {:ok, data} <- build_payload(rest, opts),
             {:ok, resolved_id} <- Helpers.resolve_workflow_id(Helpers.get_durable_name(opts), id) do
          submit(resolved_id, input_name, data, opts)
        else
          {:error, :ambiguous, matches} ->
            Mix.shell().error("Prefix is ambiguous:\n  " <> Enum.join(matches, "\n  "))

          {:error, :not_found} ->
            Mix.shell().error("No workflow matches: #{id}")

          {:error, reason} ->
            Mix.shell().error("Invalid data: #{reason}")
        end

      _ ->
        Mix.shell().error(
          "Usage: mix durable.provide_input WORKFLOW_ID INPUT_NAME DATA [--json-file PATH]"
        )
    end
  end

  defp submit(workflow_id, input_name, data, opts) do
    durable = Helpers.get_durable_name(opts)

    case Durable.Wait.provide_input(workflow_id, input_name, data, durable: durable) do
      :ok ->
        Mix.shell().info("Provided input '#{input_name}' to #{Helpers.truncate_id(workflow_id)}.")

      {:error, %Ecto.Changeset{} = cs} ->
        errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
        Mix.shell().error("Validation failed: #{inspect(errors)}")

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp build_payload([], opts) do
    case Keyword.get(opts, :json_file) do
      nil ->
        {:error, "missing DATA positional arg or --json-file"}

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

  defp build_payload([raw | _], _opts), do: {:ok, parse_data(raw)}

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Parse as JSON when it starts with a JSON sentinel; otherwise treat
  # as a raw string (the library wraps non-map values as `%{"value" =>
  # raw}` before storage, which keeps single_choice / text / approval
  # submissions working the same way the dashboard does them).
  defp parse_data(raw) do
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
