defmodule DurableDashboard.Path do
  @moduledoc """
  Path helpers for the dashboard.

  `base_path` is the full mount prefix the host's router declares with
  `dashboard_routes/2` — e.g. `"/dashboard"` or `"/admin/durable"`. These
  helpers append the per-page suffix; they do NOT add any v2/legacy segment.

  ## Usage

      <.link navigate={Path.workflows(@base_path)}>Workflows</.link>
      <.link navigate={Path.workflow(@base_path, exec.id)}>...</.link>
      <.link patch={Path.workflow_tab(@base_path, exec.id, "logs")}>Logs</.link>
  """

  @spec base(String.t()) :: String.t()
  def base(base_path), do: normalize_root(base_path)

  @spec overview(String.t()) :: String.t()
  def overview(base_path), do: normalize_root(base_path)

  @spec workflows(String.t()) :: String.t()
  def workflows(base_path), do: prefix(base_path, "/workflows")

  @spec workflow(String.t(), String.t()) :: String.t()
  def workflow(base_path, id), do: prefix(base_path, "/workflows/#{id}")

  @spec workflow_tab(String.t(), String.t(), String.t() | atom()) :: String.t()
  def workflow_tab(base_path, id, tab),
    do: prefix(base_path, "/workflows/#{id}/#{tab}")

  @spec inputs(String.t()) :: String.t()
  def inputs(base_path), do: prefix(base_path, "/inputs")

  @spec schedules(String.t()) :: String.t()
  def schedules(base_path), do: prefix(base_path, "/schedules")

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
