defmodule DurableDashboard.Components.Workflow.HistoryTab do
  @moduledoc """
  History tab — the workflow's chronological execution trace. Every step
  attempt is one event in order (so a failure and its retry appear as two
  rows), threaded on a status-colored spine down the left edge: the sequence
  is the information here, so it reads as a trace, not a flat table.

  Each event is a native `<details>` — click the row to expand the shared
  `StepDetail` panel (timing, I/O, error, logs) inline. No LiveComponent
  state needed; the browser owns the open/closed disclosure.
  """

  use Phoenix.Component

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Workflow.StepDetail

  attr :steps, :list, required: true

  def history_tab(assigns) do
    assigns = assign(assigns, :count, length(assigns.steps))

    ~H"""
    <%= if @steps == [] do %>
      <Core.empty_state
        icon="clock"
        title="No step executions yet"
        description="Step executions appear here as they run."
      />
    <% else %>
      <Core.card padding="md">
        <:title>Execution trace</:title>
        <:action>
          <span class="font-mono text-[10px] uppercase tracking-wider text-muted-foreground">
            {@count} {if @count == 1, do: "event", else: "events"}
          </span>
        </:action>

        <ol class="relative">
          <% last = @count - 1 %>
          <.event_row
            :for={{step, i} <- Enum.with_index(@steps)}
            step={step}
            first?={i == 0}
            last?={i == last}
          />
        </ol>
      </Core.card>
    <% end %>
    """
  end

  attr :step, :map, required: true
  attr :first?, :boolean, required: true
  attr :last?, :boolean, required: true

  defp event_row(assigns) do
    status = to_string(assigns.step.status)
    assigns = assign(assigns, status: status)

    ~H"""
    <li class="relative flex gap-3">
      <%!-- Spine rail: a continuous vertical line with a status node bead.
           The connector is trimmed at the first/last events so it doesn't
           dangle past the ends of the trace. --%>
      <div class="relative flex w-3 shrink-0 justify-center">
        <span class={[
          "absolute left-1/2 w-px -translate-x-1/2 bg-border",
          connector_class(@first?, @last?)
        ]}>
        </span>
        <span class={[
          "relative z-10 mt-3.5 size-2.5 rounded-full ring-4 ring-card",
          node_tone(@status),
          pulsing?(@status) && "led-dot"
        ]}>
        </span>
      </div>

      <details class="group/event min-w-0 flex-1 border-b border-border/50 last:border-0">
        <summary class={[
          "-mx-1 flex cursor-pointer list-none items-center gap-2.5 rounded-md px-1 py-2.5",
          "hover:bg-accent/20 [&::-webkit-details-marker]:hidden"
        ]}>
          <Core.code class="font-medium">{@step.step_name}</Core.code>
          <span class={["text-[11px] font-medium", status_text_tone(@status)]}>{@status}</span>
          <span
            :if={@step.attempt > 1}
            class="inline-flex items-center gap-1 rounded-full bg-warning/10 px-1.5 py-0.5 font-mono text-[10px] text-warning"
            title={"Retry — attempt #{@step.attempt}"}
          >
            <Core.icon name="arrow-path" class="size-2.5" /> retry {@step.attempt}
          </span>

          <span class="ml-auto flex shrink-0 items-center gap-3">
            <span
              :if={@step.duration_ms}
              class="font-mono text-[11px] tabular-nums text-muted-foreground"
            >
              {format_duration(@step.duration_ms)}
            </span>
            <Core.relative_time at={@step.inserted_at} class="text-muted-foreground/55" />
            <Core.icon
              name="chevron-right"
              class="size-3.5 text-muted-foreground/40 transition-transform group-open/event:rotate-90"
            />
          </span>
        </summary>

        <StepDetail.panel step={@step} class="mt-1 mb-3" />
      </details>
    </li>
    """
  end

  # The connector segment between this node and its neighbours. Full height in
  # the middle of the trace; trimmed to half at the first/last events; hidden
  # when there's only one.
  defp connector_class(true, true), do: "hidden"
  defp connector_class(true, false), do: "top-4 bottom-0"
  defp connector_class(false, true), do: "top-0 h-4"
  defp connector_class(_, _), do: "inset-y-0"

  defp status_kind(s) when is_atom(s), do: status_kind(to_string(s))
  defp status_kind("completed"), do: "success"
  defp status_kind("running"), do: "success"
  defp status_kind("waiting"), do: "warning"
  defp status_kind("compensating"), do: "warning"
  defp status_kind("failed"), do: "destructive"
  defp status_kind("timeout"), do: "destructive"
  defp status_kind("scheduled"), do: "info"
  defp status_kind(_), do: "muted"

  defp node_tone(s) do
    case status_kind(s) do
      "success" -> "bg-success"
      "warning" -> "bg-warning"
      "destructive" -> "bg-destructive"
      "info" -> "bg-info"
      _ -> "bg-muted-foreground/50"
    end
  end

  defp status_text_tone(s) do
    case status_kind(s) do
      "success" -> "text-success"
      "warning" -> "text-warning"
      "destructive" -> "text-destructive"
      "info" -> "text-info"
      _ -> "text-muted-foreground"
    end
  end

  defp pulsing?(s), do: to_string(s) in ["running", "waiting", "compensating"]

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration(ms), do: "#{div(ms, 60_000)}m"
end
