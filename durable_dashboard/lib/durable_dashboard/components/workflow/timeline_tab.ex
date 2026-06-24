defmodule DurableDashboard.Components.Workflow.TimelineTab do
  @moduledoc """
  Timeline tab — absolute-time Gantt of step executions for a single
  workflow run.

  ## Model

  - X-axis is *wall-clock time* spanning the workflow's run window.
  - One row per step name; multiple step_execs for the same name
    (suspend/resume cycles, retries) render as multiple segments on
    that row at their actual `started_at` positions.
  - This is what makes parallel blocks read as parallel — three
    children that started together overlap horizontally on three rows.
    Sequential steps appear left-to-right. Suspensions are visible as
    gaps in the row.

  ## Tiny-bar visibility

  Naively scaling 4ms inside a 28s window produces an invisible 1px
  sliver. Bars carry an inline `width: max(6px, X%)` so they're always
  visible regardless of how wide the workflow window is. The trailing
  duration in the gutter (`active 11ms · waited 28s`) plus the
  per-bar tooltip carry the precise numbers.

  ## Window calculation

  - `window_start` = earliest `started_at` across all step_execs.
  - `window_end`:
      * `now` when the workflow is in-flight (live grow).
      * else the latest real timestamp we have:
        `completed_at` || `updated_at` || `started_at` per row.

  Uses `workflow_live?/1` (driven off the workflow's status, not step
  statuses) to avoid stale `:waiting` step_exec rows from durable's
  wait/resume model pulling the window forward to "now" indefinitely.

  ## Live updates

  `WorkflowLive` ticks `assigns.now` every 500ms while the workflow is
  in-flight. Running segments grow toward `now`; the bar's `width`
  transitions over 150ms for smooth animation.

  ## Click to inspect

  Each row is a button: clicking it expands an inline detail panel
  (timing, I/O, error, and the step's captured logs) directly under the
  bar — a lightweight in-place inspector so issues are spottable without
  leaving the timeline. Multiple rows can be open at once. Stateful
  (the open set), so this is a `LiveComponent`.

  Pure HEEx + CSS for the chart — no SVG, no React island.
  """

  use Phoenix.LiveComponent

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Components.Workflow.StepDetail

  @impl true
  def mount(socket) do
    {:ok, assign(socket, expanded: MapSet.new())}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle-row", %{"row" => key}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, expanded: expanded)}
  end

  @impl true
  def render(assigns) do
    now = assigns.now || DateTime.utc_now()
    workflow_live? = workflow_live?(assigns.workflow)
    {rows, window} = build(assigns.steps, now, workflow_live?)

    track_min = track_min_px(rows, window.span_ms)

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:window, window)
      |> assign(:track_min, track_min)
      # gutter (240) + gap (12) so the whole chart overflows together
      |> assign(:chart_min, track_min + 252)

    ~H"""
    <div>
      <%= if @rows == [] do %>
        <Core.empty_state
          icon="clock"
          title="No step executions yet"
          description="Once steps run, you'll see their durations and ordering here."
        />
      <% else %>
        <Core.card padding="md">
          <:title>Step timeline</:title>
          <:action>
            <span class="font-mono text-[10px] uppercase tracking-wider text-muted-foreground">
              <span class="text-foreground">{format_duration_ms(@window.span_ms)}</span>
              <%= if @window.live? do %>
                · <span class="text-success">live</span>
              <% end %>
            </span>
          </:action>

          <%!-- Horizontal scroll viewport: the chart grows to `chart_min`,
                overflowing (and scrolling) when the timeline is dense or long.
                The step/status gutter is frozen (sticky) on the left so labels
                stay visible while the time axis scrolls. --%>
          <div class="thin-scroll -mx-4 overflow-x-auto px-4">
            <div class="flex flex-col gap-1.5" style={"min-width: #{@chart_min}px"}>
              <%!-- Header: one axis row — frozen caption + scrollable time
                    labels, both seated on a single baseline. --%>
              <div class="flex items-end gap-3 border-b border-border/50">
                <div class="sticky left-0 z-20 flex h-6 w-[240px] shrink-0 items-end border-r border-border/60 bg-card pb-1.5 pl-7">
                  <span class="font-mono text-[9px] uppercase tracking-[0.12em] text-muted-foreground/80">
                    step · status
                  </span>
                </div>
                <div class="min-w-0 flex-1 self-end">
                  <.tick_axis ticks={@window.ticks} />
                </div>
              </div>

              <%!-- Step rows + their expandable detail panels --%>
              <%= for row <- @rows do %>
                <% open? = MapSet.member?(@expanded, row.raw_step_name) %>
                <div>
                  <div
                    role="button"
                    tabindex="0"
                    phx-click="toggle-row"
                    phx-value-row={row.raw_step_name}
                    phx-target={@myself}
                    aria-expanded={to_string(open?)}
                    class="group/row flex cursor-pointer items-center gap-3"
                  >
                    <%!-- Frozen label column: opaque so bars scrolling under it
                          stay hidden. State shows via the chevron + the track
                          tint, not a translucent gutter fill. --%>
                    <div class="sticky left-0 z-10 flex shrink-0 items-center self-stretch border-r border-border/60 bg-card">
                      <.row_gutter row={row} open?={open?} />
                    </div>
                    <div class={[
                      "min-w-0 flex-1 rounded-md py-0.5 transition-colors",
                      if(open?, do: "bg-accent/30", else: "group-hover/row:bg-accent/15")
                    ]}>
                      <.row_track row={row} />
                    </div>
                  </div>

                  <StepDetail.panel
                    :if={open?}
                    step={row.exec}
                    duration_ms={row.active_ms}
                    class="sticky left-0 ml-7 mt-1 mb-0.5"
                  />
                </div>
              <% end %>
            </div>
          </div>
        </Core.card>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Row gutter
  # ============================================================================

  attr :row, :map, required: true
  attr :open?, :boolean, required: true

  defp row_gutter(assigns) do
    ~H"""
    <div class="flex h-7 w-[240px] shrink-0 items-center gap-2 min-w-0 pr-2">
      <Core.icon
        name="chevron-right"
        class={
          "size-3 shrink-0 transition-transform " <>
            if(@open?, do: "rotate-90 text-muted-foreground", else: "text-muted-foreground/50")
        }
      />
      <%!-- Compact status dot instead of a wide pill — the bar colour already
           carries status, so this just frees the gutter for the step name
           (the primary identifier, which was truncating to "aut…"). --%>
      <span
        class={[
          "size-2 shrink-0 rounded-full",
          gutter_dot_tone(@row.status),
          pulsing?(@row.status) && "led-dot"
        ]}
        title={to_string(@row.status)}
      >
      </span>
      <span
        class="min-w-0 flex-1 truncate font-mono text-[11px] text-foreground"
        title={@row.raw_step_name}
      >
        {@row.step_name}
      </span>
      <span :if={@row.attempt_count > 1} class="shrink-0 text-[9px] font-mono text-warning">
        ×{@row.attempt_count}
      </span>
      <span class="shrink-0 font-mono text-[10px] tabular-nums text-muted-foreground">
        {format_duration_ms(@row.active_ms)}
      </span>
    </div>
    """
  end

  # The intrinsic width the time track wants, so a dense or long run gets room
  # to breathe (and scrolls) instead of crushing every segment into the
  # viewport. Driven by segment count (the user's "lots of segments") with a
  # span-based floor, clamped so an hour-long run doesn't build an absurd
  # canvas. Below the floor the track simply fills the viewport (no scroll).
  defp track_min_px(rows, span_ms) do
    segments = Enum.reduce(rows, 0, fn r, acc -> acc + length(r.segments) end)

    [720, segments * 56, div(span_ms, 6)]
    |> Enum.max()
    |> min(4000)
  end

  defp gutter_dot_tone(status) do
    case to_string(status) do
      s when s in ["completed", "running"] -> "bg-success"
      s when s in ["waiting", "compensating"] -> "bg-warning"
      s when s in ["failed", "timeout"] -> "bg-destructive"
      _ -> "bg-muted-foreground/50"
    end
  end

  defp pulsing?(status), do: to_string(status) in ["running", "waiting", "compensating"]

  # ============================================================================
  # Row track — absolute-time-positioned segments
  # ============================================================================

  attr :row, :map, required: true

  defp row_track(assigns) do
    ~H"""
    <div class="relative h-7 rounded-sm bg-muted/15">
      <%= if @row.segments == [] do %>
        <span class="absolute inset-y-0 left-2 flex items-center font-mono text-[9px] uppercase tracking-wider text-muted-foreground/70">
          pending
        </span>
      <% else %>
        <%= for segment <- @row.segments do %>
          <span
            class={[
              "absolute top-1 bottom-1 rounded-sm shadow-sm transition-[left,width] duration-150",
              tone(segment.status),
              if(segment.in_flight?, do: "ring-1 ring-inset", else: ""),
              if(segment.in_flight?, do: ring_tone(segment.status), else: ""),
              if(segment.status == :running, do: "animate-pulse", else: "")
            ]}
            style={
              "left: #{segment.left_pct}%; " <>
                "width: max(6px, #{segment.width_pct}%)"
            }
            title={segment_tooltip(segment, @row)}
          >
            <span
              :if={segment.in_flight?}
              class={[
                "absolute -right-0.5 top-1/2 -translate-y-1/2 size-1.5 rounded-full",
                dot_tone(segment.status),
                "led-dot"
              ]}
            />
          </span>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Tick axis — absolute time offsets from window_start
  # ============================================================================

  attr :ticks, :list, required: true

  # Each tick is a left-anchored label sitting on the baseline with a short
  # mark pointing at its exact time offset. Bottom-aligned so the labels share
  # the caption's baseline (one clean axis row, not two stacked bands).
  defp tick_axis(assigns) do
    ~H"""
    <div class="relative h-6">
      <%= for tick <- @ticks do %>
        <div class="absolute bottom-0 flex flex-col items-start" style={"left: #{tick.pct}%"}>
          <span class="px-1 pb-1 font-mono text-[9px] uppercase tracking-wider text-muted-foreground/80 whitespace-nowrap">
            {tick.label}
          </span>
          <span class="h-1.5 w-px bg-border"></span>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Computation
  # ============================================================================

  defp workflow_live?(%{status: status})
       when status in [:pending, :running, :waiting, :compensating],
       do: true

  defp workflow_live?(_), do: false

  defp build(steps, now, workflow_live?) do
    started_steps = Enum.filter(steps, &(&1.started_at != nil))

    if started_steps == [] do
      {[], %{span_ms: 0, ticks: [], live?: workflow_live?}}
    else
      window_start =
        started_steps
        |> Enum.map(& &1.started_at)
        |> Enum.min_by(&DateTime.to_unix(&1, :millisecond))

      window_end =
        if workflow_live? do
          now
        else
          steps
          |> Enum.map(&latest_real_timestamp/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.max_by(&DateTime.to_unix(&1, :millisecond), fn -> now end)
        end

      span_ms = max(DateTime.diff(window_end, window_start, :millisecond), 1)

      rows =
        steps
        |> Enum.group_by(& &1.step_name)
        |> Enum.map(fn {name, group} ->
          build_row(
            name,
            Enum.sort_by(group, & &1.inserted_at, DateTime),
            window_start,
            span_ms,
            now,
            workflow_live?
          )
        end)
        |> Enum.sort_by(&row_sort_key/1)

      {rows, %{span_ms: span_ms, ticks: build_ticks(span_ms), live?: workflow_live?}}
    end
  end

  defp latest_real_timestamp(step) do
    step.completed_at || step.updated_at || step.started_at
  end

  # Sort rows by the earliest started_at they have so parallel rows
  # cluster together at their fan-out point and sequential rows
  # cascade naturally.
  defp row_sort_key(%{first_started_at: nil}), do: {1, 0}

  defp row_sort_key(%{first_started_at: at}) do
    {0, DateTime.to_unix(at, :millisecond)}
  end

  defp build_row(step_name, group, window_start, span_ms, now, workflow_live?) do
    segments =
      group
      |> Enum.filter(&(&1.started_at != nil))
      |> Enum.map(&build_segment(&1, window_start, span_ms, now, workflow_live?))

    latest = List.last(group)
    first = hd(group)
    max_attempt = group |> Enum.map(& &1.attempt) |> Enum.max(fn -> 1 end)
    active_ms = Enum.reduce(segments, 0, &(&2 + &1.duration_ms))

    %{
      step_name: display_name(step_name),
      raw_step_name: step_name,
      status: latest.status,
      attempt_count: max_attempt,
      first_started_at: first.started_at || first.inserted_at,
      segments: segments,
      active_ms: active_ms,
      # The step execution surfaced when the row is expanded — the latest
      # attempt carries the final outcome, I/O, error, and captured logs.
      exec: latest
    }
  end

  defp build_segment(step_exec, window_start, span_ms, now, workflow_live?) do
    in_flight? =
      step_exec.status == :running and is_nil(step_exec.completed_at) and workflow_live?

    end_at =
      cond do
        not is_nil(step_exec.completed_at) -> step_exec.completed_at
        in_flight? -> now
        not is_nil(step_exec.updated_at) -> step_exec.updated_at
        true -> step_exec.started_at
      end

    offset_ms = DateTime.diff(step_exec.started_at, window_start, :millisecond)
    duration_ms = max(DateTime.diff(end_at, step_exec.started_at, :millisecond), 0)

    %{
      status: step_exec.status,
      in_flight?: in_flight?,
      attempt: step_exec.attempt,
      started_at: step_exec.started_at,
      completed_at: step_exec.completed_at,
      duration_ms: step_exec.duration_ms || duration_ms,
      left_pct: pct(offset_ms, span_ms),
      width_pct: pct(duration_ms, span_ms)
    }
  end

  defp pct(part_ms, span_ms) when span_ms > 0 do
    Float.round(part_ms / span_ms * 100, 2)
  end

  defp pct(_, _), do: 0

  # Strip the parallel/branch macro qualifier so the row label matches
  # what the user wrote in the workflow definition. Mirror logic in
  # `DurableDashboard.GraphBuilder.extract_display_name/2`.
  defp display_name(name) when is_binary(name) do
    case String.split(name, "__") do
      [_prefix, _clause, step] -> step
      [_prefix, step] -> step
      _ -> name
    end
  end

  defp display_name(name), do: to_string(name)

  # ============================================================================
  # Tick generation — wall-clock offsets, adaptive scale
  # ============================================================================

  defp build_ticks(span_ms) do
    interval = nice_interval(span_ms)

    0..ceil_div(span_ms, interval)
    |> Enum.map(fn n -> n * interval end)
    |> Enum.take_while(&(&1 <= span_ms))
    |> Enum.map(fn offset_ms ->
      %{
        pct: Float.round(offset_ms / max(span_ms, 1) * 100, 2),
        label: format_duration_ms(offset_ms)
      }
    end)
  end

  @nice_intervals_ms [
    1,
    5,
    10,
    25,
    50,
    100,
    250,
    500,
    1_000,
    2_000,
    5_000,
    10_000,
    15_000,
    30_000,
    60_000,
    2 * 60_000,
    5 * 60_000,
    10 * 60_000,
    15 * 60_000,
    30 * 60_000,
    60 * 60_000,
    2 * 60 * 60_000,
    6 * 60 * 60_000,
    12 * 60 * 60_000,
    24 * 60 * 60_000
  ]

  defp nice_interval(span_ms) do
    target_max_ticks = 6

    Enum.find(@nice_intervals_ms, List.last(@nice_intervals_ms), fn iv ->
      ceil_div(span_ms, iv) <= target_max_ticks
    end)
  end

  defp ceil_div(_a, 0), do: 0
  defp ceil_div(a, b) when a >= 0 and b > 0, do: div(a + b - 1, b)

  # ============================================================================
  # Tone & formatting helpers
  # ============================================================================

  defp tone(:running), do: "bg-primary/70"
  defp tone(:completed), do: "bg-success/55"
  defp tone(:failed), do: "bg-destructive/70"
  defp tone(:waiting), do: "bg-warning/45"
  defp tone(:cancelled), do: "bg-muted-foreground/35"
  defp tone(_), do: "bg-muted-foreground/25"

  defp ring_tone(:running), do: "ring-primary/60"
  defp ring_tone(:waiting), do: "ring-warning/60"
  defp ring_tone(_), do: "ring-foreground/20"

  defp dot_tone(:running), do: "bg-primary"
  defp dot_tone(:waiting), do: "bg-warning"
  defp dot_tone(_), do: "bg-foreground"

  defp format_duration_ms(nil), do: "—"
  defp format_duration_ms(0), do: "0ms"
  defp format_duration_ms(ms) when ms < 1_000, do: "#{ms}ms"

  defp format_duration_ms(ms) when ms < 60_000 do
    secs = ms / 1_000
    if secs == Float.floor(secs), do: "#{trunc(secs)}s", else: "#{Float.round(secs, 1)}s"
  end

  defp format_duration_ms(ms) when ms < 3_600_000 do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1_000)
    if seconds == 0, do: "#{minutes}m", else: "#{minutes}m #{seconds}s"
  end

  defp format_duration_ms(ms) do
    hours = div(ms, 3_600_000)
    minutes = div(rem(ms, 3_600_000), 60_000)
    if minutes == 0, do: "#{hours}h", else: "#{hours}h #{minutes}m"
  end

  defp segment_tooltip(segment, row) do
    parts = [
      row.step_name,
      "attempt ##{segment.attempt}",
      "#{segment.status}",
      format_duration_ms(segment.duration_ms)
    ]

    Enum.join(parts, " · ")
  end
end
