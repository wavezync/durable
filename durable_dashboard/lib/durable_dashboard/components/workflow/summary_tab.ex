defmodule DurableDashboard.Components.Workflow.SummaryTab do
  @moduledoc """
  Summary tab for the workflow detail view. Shows core metadata, timing,
  pending inputs, and the error payload (when failed) at a glance.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core

  attr :workflow, :map, required: true
  attr :steps, :list, required: true
  attr :pending_inputs, :list, required: true

  def summary_tab(assigns) do
    assigns = assign(assigns, stats: compute_stats(assigns.workflow, assigns.steps))

    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
      <div class="lg:col-span-2 space-y-4">
        <Core.card>
          <:title>Metadata</:title>
          <dl class="grid grid-cols-2 md:grid-cols-3 gap-x-6 gap-y-3 text-[13px]">
            <.row label="Status">
              <Core.status_pill status={@workflow.status} />
            </.row>
            <.row label="Queue">{@workflow.queue}</.row>
            <.row label="Priority">
              <span class="text-numeric">{@workflow.priority}</span>
            </.row>
            <.row label="Current step">
              <%= if @workflow.current_step do %>
                <Core.code>{@workflow.current_step}</Core.code>
              <% else %>
                <span class="text-muted-foreground">—</span>
              <% end %>
            </.row>
            <.row label="Inserted">
              <Core.relative_time at={@workflow.inserted_at} />
            </.row>
            <.row label="Updated">
              <Core.relative_time at={@workflow.updated_at} />
            </.row>
          </dl>
        </Core.card>

        <Core.card :if={@workflow.error}>
          <:title>Error</:title>
          <div class="space-y-2">
            <div class="flex items-center gap-2">
              <Core.badge kind="destructive">{error_type(@workflow.error)}</Core.badge>
              <span class="text-[13px] text-foreground">{error_message(@workflow.error)}</span>
            </div>
            <pre :if={error_stacktrace(@workflow.error)}
              class="text-[11px] text-muted-foreground font-mono whitespace-pre-wrap thin-scroll max-h-64 overflow-auto"
            >{error_stacktrace(@workflow.error)}</pre>
          </div>
        </Core.card>

        <Core.card :if={@pending_inputs != []}>
          <:title>Awaiting input</:title>
          <ul class="space-y-2">
            <li
              :for={input <- @pending_inputs}
              class="flex items-start justify-between gap-3 p-3 rounded-md border border-border bg-card/40"
            >
              <div class="flex flex-col gap-1 min-w-0">
                <div class="flex items-center gap-2">
                  <Core.badge kind="info">{input.input_type}</Core.badge>
                  <span class="text-[13px] font-medium">{input.input_name}</span>
                </div>
                <p :if={input.prompt} class="text-xs text-muted-foreground line-clamp-2">
                  {input.prompt}
                </p>
              </div>
              <Core.relative_time at={input.inserted_at} />
            </li>
          </ul>
        </Core.card>
      </div>

      <div class="space-y-4">
        <Core.card>
          <:title>Steps</:title>
          <dl class="grid grid-cols-3 gap-3 text-center">
            <.stat label="Total" value={@stats.total} kind="muted" />
            <.stat label="Completed" value={@stats.completed} kind="success" />
            <.stat label="Failed" value={@stats.failed} kind="destructive" />
            <.stat label="Running" value={@stats.running} kind="success" />
            <.stat label="Waiting" value={@stats.waiting} kind="warning" />
            <.stat label="Other" value={@stats.other} kind="muted" />
          </dl>
        </Core.card>

        <Core.card>
          <:title>Timing</:title>
          <dl class="space-y-3 text-[13px]">
            <.row label="Started">
              <Core.relative_time at={@workflow.started_at} />
            </.row>
            <.row label="Completed">
              <Core.relative_time at={@workflow.completed_at} />
            </.row>
            <.row label="Duration">
              <span class="text-numeric">{format_duration(@workflow)}</span>
            </.row>
          </dl>
        </Core.card>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Layout helpers
  # ============================================================================

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp row(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5 min-w-0">
      <dt class="text-[10px] uppercase tracking-wider text-muted-foreground">{@label}</dt>
      <dd class="text-[13px]">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :kind, :string, default: "muted"

  defp stat(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-numeric text-2xl font-semibold tabular-nums text-foreground">
        {@value}
      </span>
      <span class={[
        "text-[10px] uppercase tracking-wider",
        stat_label_class(@kind)
      ]}>
        {@label}
      </span>
    </div>
    """
  end

  defp stat_label_class("success"), do: "text-success"
  defp stat_label_class("warning"), do: "text-warning"
  defp stat_label_class("destructive"), do: "text-destructive"
  defp stat_label_class(_), do: "text-muted-foreground"

  # ============================================================================
  # Stats / formatting
  # ============================================================================

  defp compute_stats(_workflow, steps) do
    by_status =
      steps
      |> Enum.group_by(fn s -> to_string(s.status) end)
      |> Enum.map(fn {k, v} -> {k, length(v)} end)
      |> Map.new()

    total = length(steps)

    %{
      total: total,
      completed: Map.get(by_status, "completed", 0),
      failed: Map.get(by_status, "failed", 0),
      running: Map.get(by_status, "running", 0),
      waiting: Map.get(by_status, "waiting", 0),
      other:
        total -
          (Map.get(by_status, "completed", 0) +
             Map.get(by_status, "failed", 0) +
             Map.get(by_status, "running", 0) +
             Map.get(by_status, "waiting", 0))
    }
  end

  defp format_duration(%{started_at: nil}), do: "—"

  defp format_duration(%{completed_at: nil, started_at: started}) do
    diff_ms = DateTime.diff(DateTime.utc_now(), started, :millisecond)
    humanize_ms(diff_ms) <> " (running)"
  end

  defp format_duration(%{started_at: started, completed_at: completed}) do
    diff_ms = DateTime.diff(completed, started, :millisecond)
    humanize_ms(diff_ms)
  end

  defp humanize_ms(ms) when ms < 1000, do: "#{ms}ms"
  defp humanize_ms(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp humanize_ms(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m #{rem(div(ms, 1000), 60)}s"
  defp humanize_ms(ms), do: "#{div(ms, 3_600_000)}h #{rem(div(ms, 60_000), 60)}m"

  defp error_type(%{"type" => t}), do: to_string(t)
  defp error_type(%{type: t}), do: to_string(t)
  defp error_type(_), do: "error"

  defp error_message(%{"message" => m}), do: to_string(m)
  defp error_message(%{message: m}), do: to_string(m)
  defp error_message(_), do: ""

  defp error_stacktrace(%{"stacktrace" => st}) when is_binary(st), do: st
  defp error_stacktrace(%{stacktrace: st}) when is_binary(st), do: st
  defp error_stacktrace(_), do: nil
end
