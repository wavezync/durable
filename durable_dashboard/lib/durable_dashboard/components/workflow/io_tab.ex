defmodule DurableDashboard.Components.Workflow.IoTab do
  @moduledoc """
  I/O tab — shows the workflow's input payload and the accumulated context as
  pretty-printed JSON. Side-by-side on wide screens, stacked on narrow.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core

  attr :workflow, :map, required: true

  def io_tab(assigns) do
    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <Core.card padding="none">
        <:title>Input</:title>
        <:action>
          <span class="text-[11px] text-muted-foreground font-mono">
            {byte_size_kb(@workflow.input)}
          </span>
        </:action>

        <.json_block payload={@workflow.input} empty="No input" />
      </Core.card>

      <Core.card padding="none">
        <:title>Context</:title>
        <:action>
          <span class="text-[11px] text-muted-foreground font-mono">
            {byte_size_kb(@workflow.context)}
          </span>
        </:action>

        <.json_block payload={@workflow.context} empty="No context yet" />
      </Core.card>
    </div>
    """
  end

  attr :payload, :any, required: true
  attr :empty, :string, required: true

  defp json_block(assigns) do
    ~H"""
    <%= if empty?(@payload) do %>
      <div class="px-4 py-12 text-center text-[13px] text-muted-foreground">
        {@empty}
      </div>
    <% else %>
      <pre class={[
        "text-xs font-mono leading-relaxed",
        "px-4 py-3 max-h-[600px] overflow-auto thin-scroll",
        "bg-muted/20 text-foreground/90 whitespace-pre"
      ]}><code>{pretty(@payload)}</code></pre>
    <% end %>
    """
  end

  defp empty?(nil), do: true
  defp empty?(map) when is_map(map) and map_size(map) == 0, do: true
  defp empty?([]), do: true
  defp empty?(""), do: true
  defp empty?(_), do: false

  defp pretty(payload) do
    Jason.encode!(payload, pretty: true)
  rescue
    _ -> inspect(payload, pretty: true, limit: :infinity)
  end

  defp byte_size_kb(nil), do: "—"

  defp byte_size_kb(payload) do
    size =
      case Jason.encode(payload) do
        {:ok, bin} -> byte_size(bin)
        _ -> 0
      end

    cond do
      size == 0 -> "—"
      size < 1024 -> "#{size} B"
      size < 1_048_576 -> "#{Float.round(size / 1024, 1)} KB"
      true -> "#{Float.round(size / 1_048_576, 1)} MB"
    end
  end
end
