defmodule DurableDashboard.Path do
  @moduledoc """
  Path helpers for the dashboard.

  `base_path` is the full mount prefix the host's router declares with
  `dashboard_routes/2` — e.g. `"/dashboard"` or `"/admin/durable"`. These
  helpers append the per-page suffix.

  ## Usage

      # Workflow definitions list
      <.link navigate={Path.workflows(@base_path)}>Workflows</.link>

      # Executions for a specific workflow definition
      <.link navigate={Path.workflow_executions(@base_path, name)}>...</.link>

      # All executions, filterable
      <.link navigate={Path.executions(@base_path)}>Executions</.link>

      # Single execution detail (and its tabs)
      <.link navigate={Path.execution(@base_path, exec.id)}>...</.link>
      <.link patch={Path.execution_tab(@base_path, exec.id, "logs")}>Logs</.link>
  """

  @spec base(String.t()) :: String.t()
  def base(base_path), do: normalize_root(base_path)

  @spec overview(String.t()) :: String.t()
  def overview(base_path), do: normalize_root(base_path)

  @spec workflows(String.t()) :: String.t()
  def workflows(base_path), do: prefix(base_path, "/workflows")

  @doc "A workflow's page: its health, steps and errors."
  @spec workflow_detail(String.t(), String.t()) :: String.t()
  def workflow_detail(base_path, name), do: prefix(base_path, "/workflows/#{URI.encode(name)}")

  @doc "The runs of one workflow."
  @spec workflow_executions(String.t(), String.t()) :: String.t()
  def workflow_executions(base_path, name),
    do: prefix(base_path, "/workflows/#{URI.encode(name)}/runs")

  @spec executions(String.t()) :: String.t()
  def executions(base_path), do: prefix(base_path, "/executions")

  @spec execution(String.t(), String.t()) :: String.t()
  def execution(base_path, id), do: prefix(base_path, "/executions/#{id}")

  @spec execution_tab(String.t(), String.t(), String.t() | atom()) :: String.t()
  def execution_tab(base_path, id, tab),
    do: prefix(base_path, "/executions/#{id}/#{tab}")

  @spec inputs(String.t()) :: String.t()
  def inputs(base_path), do: prefix(base_path, "/inputs")

  @spec queues(String.t()) :: String.t()
  def queues(base_path), do: prefix(base_path, "/queues")

  @spec schedules(String.t()) :: String.t()
  def schedules(base_path), do: prefix(base_path, "/schedules")

  @doc "One schedule's page: its runs, next fires and input."
  @spec schedule(String.t(), String.t()) :: String.t()
  def schedule(base_path, name), do: prefix(base_path, "/schedules/#{URI.encode(name)}")

  @spec telemetry(String.t()) :: String.t()
  def telemetry(base_path), do: prefix(base_path, "/telemetry")

  @spec settings(String.t()) :: String.t()
  def settings(base_path), do: prefix(base_path, "/settings")

  defp prefix(base_path, suffix) do
    base = String.trim_trailing(base_path || "", "/")
    normalize(base <> suffix)
  end

  defp normalize_root(nil), do: "/"
  defp normalize_root(""), do: "/"
  defp normalize_root(path), do: normalize(path)

  defp normalize(path) do
    path
    |> String.replace(~r{/+}, "/")
    |> trim_to_root()
  end

  defp trim_to_root("/"), do: "/"
  defp trim_to_root(path), do: String.trim_trailing(path, "/")
end
