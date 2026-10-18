defmodule DurableDashboard.Components.Workflow.IoTab do
  @moduledoc """
  I/O tab — shows the workflow's input payload and the accumulated context as
  pretty-printed JSON. Side-by-side on wide screens, stacked on narrow.

  Keys starting with `__` are the engine's own bookkeeping (child runs,
  parallel results); they're folded away under the run's own context.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core

  attr :workflow, :map, required: true

  def io_tab(assigns) do
    {internal, own} =
      case assigns.workflow.context do
        %{} = context -> Enum.split_with(context, fn {k, _v} -> internal_key?(k) end)
        _ -> {[], []}
      end

    assigns =
      assign(assigns,
        own:
          if(is_map(assigns.workflow.context), do: Map.new(own), else: assigns.workflow.context),
        internal: Map.new(internal)
      )

    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <Core.card padding="none">
        <:title>Input</:title>
        <:action>
          <span
            class="text-[11px] text-muted-foreground font-mono"
            data-tip-title="Input size"
            data-tip="What the run was started with, as JSON"
          >
            {byte_size_kb(@workflow.input)}
          </span>
        </:action>

        <.json_block payload={@workflow.input} empty="No input" />
      </Core.card>

      <Core.card padding="none">
        <:title>Context</:title>
        <:action>
          <span
            class="text-[11px] text-muted-foreground font-mono"
            data-tip-title="Context size"
            data-tip="What steps stored with put_context, as JSON · saved after every step"
          >
            {byte_size_kb(@workflow.context)}
          </span>
        </:action>

        <.json_block payload={@own} empty="No context yet" />
        <details :if={@internal != %{}} class="group/internal border-t border-border">
          <summary
            class="flex cursor-pointer list-none items-center gap-1.5 px-4 py-2 text-xs text-muted-foreground hover:text-foreground [&::-webkit-details-marker]:hidden"
            data-tip="Keys Durable keeps for itself — child runs, parallel results · not written by your steps"
          >
            <Core.icon name="chevron-right" class="size-3 transition-transform group-open/internal:rotate-90" />
            Engine bookkeeping · {map_size(@internal)} {if map_size(@internal) == 1, do: "key", else: "keys"}
          </summary>
          <Core.json value={@internal} bare class="max-h-[400px] bg-muted/20 px-4 py-3" />
        </details>
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
      <Core.json value={@payload} bare class="max-h-[600px] bg-muted/20 px-4 py-3" />
    <% end %>
    """
  end

  defp internal_key?(key), do: key |> to_string() |> String.starts_with?("__")

  defp empty?(nil), do: true
  defp empty?(map) when is_map(map) and map_size(map) == 0, do: true
  defp empty?([]), do: true
  defp empty?(""), do: true
  defp empty?(_), do: false

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
