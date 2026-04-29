defmodule DurableDashboard.Components.Workflow.HistoryTab do
  @moduledoc """
  History tab — chronological step execution timeline. Each row shows the
  step name, status, attempt, duration, and an expandable details block
  with input/output/error if present.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core

  attr :steps, :list, required: true

  def history_tab(assigns) do
    ~H"""
    <%= if @steps == [] do %>
      <Core.empty_state
        icon="clock"
        title="No step executions yet"
        description="Step executions appear here as they run."
      />
    <% else %>
      <Core.card padding="none">
        <ol class="divide-y divide-border">
          <li :for={step <- @steps} class="px-4 py-3">
            <.step_row step={step} />
          </li>
        </ol>
      </Core.card>
    <% end %>
    """
  end

  attr :step, :map, required: true

  defp step_row(assigns) do
    ~H"""
    <div class="flex items-start gap-3">
      <div class="pt-0.5 shrink-0">
        <Core.status_pill status={@step.status} />
      </div>

      <div class="flex flex-col gap-1 min-w-0 flex-1">
        <div class="flex items-baseline justify-between gap-3">
          <div class="flex items-center gap-2 min-w-0">
            <Core.code class="font-medium">{@step.step_name}</Core.code>
            <span :if={@step.step_type} class="text-[11px] text-muted-foreground uppercase tracking-wider">
              {@step.step_type}
            </span>
            <span :if={@step.attempt > 1} class="text-[11px] text-warning">
              attempt {@step.attempt}
            </span>
          </div>
          <div class="flex items-center gap-3 text-xs text-muted-foreground shrink-0">
            <span :if={@step.duration_ms} class="text-numeric">
              {format_duration(@step.duration_ms)}
            </span>
            <Core.relative_time at={@step.inserted_at} />
          </div>
        </div>

        <details :if={has_details?(@step)} class="text-xs mt-1">
          <summary class="cursor-pointer text-muted-foreground hover:text-foreground">
            Details
          </summary>
          <div class="mt-2 space-y-2 pl-3 border-l border-border">
            <.detail_block :if={@step.input} label="Input" payload={@step.input} />
            <.detail_block :if={@step.output} label="Output" payload={@step.output} />
            <.detail_block :if={@step.error} label="Error" payload={@step.error} variant="error" />
          </div>
        </details>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :payload, :any, required: true
  attr :variant, :string, default: "default"

  defp detail_block(assigns) do
    ~H"""
    <div>
      <span class={[
        "block text-[10px] uppercase tracking-wider mb-1",
        if(@variant == "error", do: "text-destructive", else: "text-muted-foreground")
      ]}>
        {@label}
      </span>
      <pre class={[
        "text-[11px] font-mono leading-relaxed thin-scroll",
        "px-3 py-2 max-h-48 overflow-auto rounded-md",
        "bg-muted/30 text-foreground/90 whitespace-pre-wrap"
      ]}><code>{pretty(@payload)}</code></pre>
    </div>
    """
  end

  defp has_details?(step) do
    not is_nil(step.input) or not is_nil(step.output) or not is_nil(step.error)
  end

  defp pretty(payload) do
    Jason.encode!(payload, pretty: true)
  rescue
    _ -> inspect(payload, pretty: true, limit: :infinity)
  end

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{div(ms, 60_000)}m"
end
