defmodule DurableDashboard.Components.Workflow.StepDetail do
  @moduledoc """
  Shared expand panel for a single step execution — the in-place inspector
  used by both the Timeline tab and the History tab (and conceptually the
  same content as the Flow step inspector). One source of truth so a step's
  details read identically wherever you open them.

  Layout: a compact horizontal stat strip (timing facts), input/output as
  content-hugging syntax-highlighted JSON, an error panel when the step
  failed, and the step's captured logs via the shared `LogLine` row.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Workflow.LogLine

  @doc """
  Render the detail panel for a `step` (a `StepExecution` map/struct).

  `duration_ms` overrides the displayed duration (the Timeline sums it across
  resume segments); it defaults to the step's own `:duration_ms`. `class` is
  merged onto the outer container for positioning/margins at the call site.
  """
  attr :step, :map, required: true
  attr :duration_ms, :any, default: nil
  attr :class, :any, default: nil

  def panel(assigns) do
    step = assigns.step

    logs =
      step
      |> Map.get(:logs)
      |> List.wrap()
      |> Enum.sort_by(&Map.get(&1, "timestamp", ""))

    assigns =
      assigns
      |> assign(:logs, logs)
      |> assign(:has_error, present?(Map.get(step, :error)))
      |> assign(:duration, assigns.duration_ms || Map.get(step, :duration_ms))
      |> assign(
        :both_io,
        present?(Map.get(step, :input)) and present?(Map.get(step, :output))
      )

    ~H"""
    <div class={[
      "overflow-hidden rounded-lg border border-border bg-muted/25 shadow-sm",
      @class
    ]}>
      <%!-- Stat strip — compact horizontal header (no tall field column). --%>
      <div class="flex flex-wrap items-center gap-x-5 gap-y-1.5 border-b border-border/60 bg-muted/20 px-3.5 py-2.5">
        <.stat label="started"><Core.local_time at={@step.started_at} format="time" /></.stat>
        <.stat :if={@step.completed_at} label="completed">
          <Core.local_time at={@step.completed_at} format="time" />
        </.stat>
        <.stat label="duration">{format_duration(@duration)}</.stat>
        <.stat label="attempt">{@step.attempt}</.stat>
      </div>

      <%!-- I/O — boxes fill their column (w-full). Two columns only when both
           input and output have data; if one side is empty the present value
           spans the full panel width instead of being penned into a half. --%>
      <div class={["grid items-start gap-x-6 gap-y-3 p-3.5", @both_io && "md:grid-cols-2"]}>
        <div class="min-w-0 space-y-1">
          <Core.label>input</Core.label>
          <.io_value value={Map.get(@step, :input)} empty="No input" />
        </div>
        <div class="min-w-0 space-y-1">
          <Core.label>output</Core.label>
          <.io_value value={Map.get(@step, :output)} empty="No output" />
        </div>
      </div>

      <%!-- Error (if any) --%>
      <div
        :if={@has_error}
        class="space-y-1.5 border-t border-destructive/30 bg-destructive/5 px-3.5 py-3"
      >
        <Core.label class="text-destructive">error</Core.label>
        <Core.json
          value={@step.error}
          class="w-full max-h-48 border-destructive/30 bg-destructive/5"
        />
      </div>

      <%!-- Logs (reuses the shared LogLine row) --%>
      <div :if={@logs != []} class="border-t border-border/60 bg-card">
        <div class="flex items-center justify-between px-3.5 pt-2.5 pb-1.5">
          <Core.label>logs</Core.label>
          <span class="font-mono text-[9px] tabular-nums text-muted-foreground/60">
            {length(@logs)}
          </span>
        </div>
        <div class="thin-scroll max-h-64 overflow-auto border-t border-border/40">
          <LogLine.row :for={entry <- @logs} entry={entry} show_step={false} />
        </div>
      </div>

      <div
        :if={@logs == [] and not @has_error}
        class="border-t border-border/40 px-3.5 py-2.5 font-mono text-[10px] text-muted-foreground/60"
      >
        No logs captured for this step.
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp stat(assigns) do
    ~H"""
    <div class="flex items-baseline gap-1.5">
      <Core.label>{@label}</Core.label>
      <span class="font-mono text-[11px] tabular-nums text-foreground/85">
        {render_slot(@inner_block)}
      </span>
    </div>
    """
  end

  attr :value, :any, required: true
  attr :empty, :string, required: true

  defp io_value(assigns) do
    ~H"""
    <%= if present?(@value) do %>
      <Core.json value={@value} class="w-full max-h-48" />
    <% else %>
      <p class="font-mono text-[11px] text-muted-foreground/55">{@empty}</p>
    <% end %>
    """
  end

  defp present?(nil), do: false
  defp present?(m) when is_map(m) and map_size(m) == 0, do: false
  defp present?([]), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp format_duration(nil), do: "—"
  defp format_duration(0), do: "0ms"
  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"

  defp format_duration(ms) when ms < 60_000 do
    secs = ms / 1_000
    if secs == Float.floor(secs), do: "#{trunc(secs)}s", else: "#{Float.round(secs, 1)}s"
  end

  defp format_duration(ms), do: "#{div(ms, 60_000)}m"
end
