defmodule DurableDashboard.Components.Charts do
  @moduledoc """
  Panels and the three chart forms the dashboard uses, drawn from
  `Durable.Stats.timeline/1` buckets — see `DESIGN.md` §6 "Charts".

    * `stacked_bars/1` — runs finished per bucket: completed, failed, cancelled
    * `rate_line/1` — failure rate per bucket, ceiling adapts to the peak
    * `percentile_lines/1` — p50 / p95 duration per bucket

  One axis per chart, legends whenever there's more than one series, chart
  colors from `--chart-*` tokens. Every bucket has a tooltip (`DESIGN.md`
  "Tooltips"): its time span, then each series' value. Bars take hover on the
  whole column; lines on a column centred on each point, which shows a guide
  line and a dot on the point while hovered — CSS only.
  """

  use Phoenix.Component

  alias DurableDashboard.Format

  # ---- Panel ------------------------------------------------------------------

  attr :title, :string, required: true
  attr :sub, :string, default: nil
  attr :class, :any, default: nil
  slot :legend
  slot :action
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section class={["min-w-0 overflow-hidden rounded-[10px] border border-border bg-card", @class]}>
      <header class="flex flex-wrap items-baseline justify-between gap-3 px-4 pb-2.5 pt-3.5">
        <div>
          <h2 class="text-sm font-semibold">{@title}</h2>
          <p :if={@sub} class="text-xs text-muted-foreground">{@sub}</p>
        </div>
        <div :if={@legend != []} class="flex flex-wrap gap-3.5 text-xs text-subtle-foreground">
          {render_slot(@legend)}
        </div>
        {render_slot(@action)}
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :class, :string, required: true
  attr :line, :boolean, default: false
  slot :inner_block, required: true

  def swatch(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5">
      <i class={[if(@line, do: "h-0.5 w-3.5 rounded-full", else: "size-2.5 rounded-sm"), @class]}></i>
      {render_slot(@inner_block)}
    </span>
    """
  end

  # ---- Range switch -----------------------------------------------------------

  attr :range, :string, required: true
  attr :ranges, :list, default: ~w(1h 24h 7d 30d)
  attr :path, :string, required: true, doc: "page path; `?range=` is appended"

  def range_switch(assigns) do
    ~H"""
    <nav class="inline-flex overflow-hidden rounded-md border border-input bg-card" aria-label="Time range">
      <.link
        :for={r <- @ranges}
        patch={@path <> "?range=" <> r}
        aria-current={@range == r && "page"}
        class={[
          "inline-flex h-7 items-center px-3 text-xs font-medium [&+&]:border-l [&+&]:border-border",
          if(@range == r, do: "bg-secondary text-foreground", else: "text-subtle-foreground hover:text-foreground")
        ]}
      >
        {r}
      </.link>
    </nav>
    """
  end

  @doc "`{span seconds, bucket seconds}` for a range key."
  def range_window("1h"), do: {3_600, 60}
  def range_window("7d"), do: {604_800, 14_400}
  def range_window("30d"), do: {2_592_000, 86_400}
  def range_window(_24h), do: {86_400, 1_800}

  def valid_range(range) when range in ~w(1h 24h 7d 30d), do: range
  def valid_range(_range), do: "24h"

  # ---- Charts -----------------------------------------------------------------

  attr :timeline, :list, required: true

  def stacked_bars(assigns) do
    max =
      assigns.timeline
      |> Enum.map(&(&1.completed + &1.failed + &1.cancelled))
      |> Enum.max(fn -> 0 end)

    assigns =
      assign(assigns,
        top: count_max(max),
        empty?: max == 0,
        buckets: Enum.zip(assigns.timeline, bucket_labels(assigns.timeline))
      )

    ~H"""
    <div class="relative mx-4 ml-[52px] h-[168px]">
      <.gridlines :if={!@empty?} top={Format.int(@top)} mid={Format.int(div(@top, 2))} />
      <.empty :if={@empty?}>No runs finished in this window</.empty>
      <div class="absolute inset-0 flex items-end gap-0.5">
        <div
          :for={{b, label} <- @buckets}
          class="group flex h-full min-w-0 flex-1 items-end rounded-t-[2px] hover:bg-foreground/[0.04]"
          data-tip-title={label}
          data-tip={"#{Format.int(b.completed)} completed\n#{Format.int(b.failed)} failed\n#{Format.int(b.cancelled)} cancelled"}
          data-tip-meta={finished_meta(b)}
        >
          <div
            class="flex w-full flex-col-reverse gap-px group-hover:brightness-125"
            style={"height: #{bar_pct(b.completed + b.failed + b.cancelled, @top)}%"}
          >
            <i class="block bg-chart-ok" style={"flex-grow: #{b.completed}"}></i>
            <i class="block bg-chart-fail" style={"flex-grow: #{b.failed}"}></i>
            <i class="block rounded-t-[2px] bg-off" style={"flex-grow: #{b.cancelled}"}></i>
          </div>
        </div>
      </div>
    </div>
    <.x_axis timeline={@timeline} />
    """
  end

  attr :timeline, :list, required: true

  def rate_line(assigns) do
    rates = Enum.map(assigns.timeline, & &1.failure_rate)
    peak = Enum.max(rates, fn -> 0.0 end)
    ceiling = Enum.find([0.1, 0.25, 0.5, 1.0], 1.0, &(&1 >= peak))
    points = points(rates, ceiling)

    assigns =
      assign(assigns,
        line: path(points),
        dots: dots(points),
        area: if(points == [], do: "", else: path(points) <> " L1000,100 L0,100 Z"),
        peak: peak,
        top: Format.pct(ceiling),
        mid: Format.pct(ceiling / 2),
        series: [%{ys: ys(points), class: "text-chart-fail"}],
        tips: tips(assigns.timeline, &rate_tip/1),
        empty?: Enum.all?(assigns.timeline, &(finished(&1) == 0))
      )

    ~H"""
    <div class="relative mx-4 ml-[52px] h-[168px]">
      <.gridlines :if={!@empty?} top={@top} mid={@mid} />
      <.empty :if={@empty?}>No runs finished in this window</.empty>
      <svg viewBox="0 0 1000 100" preserveAspectRatio="none" class="absolute inset-0 h-full w-full overflow-visible" aria-hidden="true">
        <path d={@area} class="text-chart-fail" fill="currentColor" opacity="0.14" />
        <path d={@line} class="text-chart-fail" fill="none" stroke="currentColor" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round" />
        <path d={@dots} class="text-chart-fail" stroke="currentColor" stroke-width="6" vector-effect="non-scaling-stroke" stroke-linecap="round" />
      </svg>
      <.point_hover tips={@tips} series={@series} />
    </div>
    <.x_axis timeline={@timeline} />
    <p :if={!@empty?} class="mx-4 mb-3 mt-1 text-right font-mono text-xs text-destructive">peak {Format.pct(@peak)}</p>
    """
  end

  attr :timeline, :list, required: true

  def percentile_lines(assigns) do
    values = Enum.flat_map(assigns.timeline, &[&1.p50_ms, &1.p95_ms]) |> Enum.reject(&is_nil/1)
    top = nice_max(Enum.max(values, fn -> 0 end))

    p50 = points(Enum.map(assigns.timeline, & &1.p50_ms), top)
    p95 = points(Enum.map(assigns.timeline, & &1.p95_ms), top)

    assigns =
      assign(assigns,
        top: top,
        p50: path(p50),
        p95: path(p95),
        p50_points: p50,
        p95_points: p95,
        series: [%{ys: ys(p95), class: "text-chart-2"}, %{ys: ys(p50), class: "text-chart-1"}],
        tips: tips(assigns.timeline, &percentile_tip/1),
        empty?: values == []
      )

    ~H"""
    <div class="relative mx-4 ml-[52px] h-[168px]">
      <.gridlines :if={!@empty?} top={Format.ms(@top)} mid={Format.ms(div(@top, 2))} />
      <.empty :if={@empty?}>No runs completed in this window</.empty>
      <svg viewBox="0 0 1000 100" preserveAspectRatio="none" class="absolute inset-0 h-full w-full overflow-visible" aria-hidden="true">
        <path d={@p95} class="text-chart-2" fill="none" stroke="currentColor" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round" />
        <path d={@p50} class="text-chart-1" fill="none" stroke="currentColor" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round" />
        <path d={dots(@p95_points)} class="text-chart-2" stroke="currentColor" stroke-width="6" vector-effect="non-scaling-stroke" stroke-linecap="round" />
        <path d={dots(@p50_points)} class="text-chart-1" stroke="currentColor" stroke-width="6" vector-effect="non-scaling-stroke" stroke-linecap="round" />
      </svg>
      <.point_hover tips={@tips} series={@series} />
    </div>
    <.x_axis timeline={@timeline} />
    """
  end

  defp rate_tip(b) do
    case finished(b) do
      0 ->
        {"nothing finished", nil}

      n ->
        {"#{Format.pct(b.failure_rate)} failed",
         "#{Format.int(b.failed)} of #{Format.int(n)} finished"}
    end
  end

  defp percentile_tip(%{p50_ms: nil}), do: {"no completed runs", nil}

  defp percentile_tip(b),
    do:
      {"p95 #{Format.ms(b.p95_ms)}\np50 #{Format.ms(b.p50_ms)}",
       "over #{Format.int(b.completed)} completed runs"}

  defp finished(b), do: b.completed + b.failed + b.cancelled

  defp finished_meta(b) do
    case finished(b) do
      0 -> nil
      n -> "#{Format.int(n)} finished · #{Format.pct(b.failure_rate)} failed"
    end
  end

  # {title, body, meta} per bucket: its span, then what `fun` says about it.
  defp tips(timeline, fun) do
    Enum.zip_with(timeline, bucket_labels(timeline), fn b, label ->
      {body, meta} = fun.(b)
      {label, body, meta}
    end)
  end

  @doc """
  Each bucket's span as a tooltip title — `"Oct 17, 02:00–02:30 UTC"`, or the
  day for day-sized buckets — for charts drawn from a `Durable.Stats.timeline/1`.
  """
  def bucket_labels(timeline) do
    step =
      case timeline do
        [a, b | _] -> DateTime.diff(b.at, a.at)
        _ -> nil
      end

    Enum.map(timeline, &span_label(&1.at, step))
  end

  defp span_label(at, step) when is_integer(step) and step >= 86_400,
    do: Calendar.strftime(at, "%a %b %-d") <> " · UTC"

  defp span_label(at, step) when is_integer(step) do
    Calendar.strftime(at, "%b %-d, %H:%M") <>
      "–" <> Calendar.strftime(DateTime.add(at, step, :second), "%H:%M") <> " UTC"
  end

  defp span_label(at, _step), do: stamp(at)

  attr :tips, :list, required: true, doc: "`{title, body, meta}` per point"

  attr :series, :list,
    required: true,
    doc: "`%{ys: [percent from the top | nil], class: text color}` per line"

  # One hover column per point, centred on it: a guide line and a dot per
  # series show while it's hovered. Columns overhang the plot by half a step
  # at each end so the first and last points get a full-width target.
  defp point_hover(assigns) do
    last = max(length(assigns.tips) - 1, 1)

    dots =
      assigns.series
      |> Enum.map(fn s -> Enum.map(s.ys, &(&1 && {&1, s.class})) end)
      |> Enum.zip_with(&Enum.reject(&1, fn dot -> is_nil(dot) end))

    assigns =
      assign(assigns,
        width: 100 / last,
        columns: Enum.zip(assigns.tips, dots) |> Enum.with_index(),
        last: last
      )

    ~H"""
    <div class="pointer-events-none absolute inset-0">
      <div
        :for={{{{title, body, meta}, dots}, i} <- @columns}
        class="group pointer-events-auto absolute inset-y-0"
        style={"left: #{Float.round(i / @last * 100 - @width / 2, 3)}%; width: #{Float.round(@width, 3)}%"}
        data-tip-title={title}
        data-tip={body}
        data-tip-meta={meta}
      >
        <span class="absolute inset-y-0 left-1/2 w-px bg-input opacity-0 group-hover:opacity-100"></span>
        <span
          :for={{y, class} <- dots}
          class={[
            "absolute left-1/2 size-[9px] -translate-x-1/2 -translate-y-1/2 rounded-full bg-current ring-2 ring-card",
            "opacity-0 group-hover:opacity-100",
            class
          ]}
          style={"top: #{y}%"}
        >
        </span>
      </div>
    </div>
    """
  end

  attr :top, :string, required: true
  attr :mid, :string, required: true

  defp gridlines(assigns) do
    ~H"""
    <div class="absolute inset-x-0 top-0 border-t border-dashed border-border">
      <span class="absolute right-[calc(100%+8px)] -top-2 whitespace-nowrap font-mono text-[11px] text-muted-foreground">{@top}</span>
    </div>
    <div class="absolute inset-x-0 top-1/2 border-t border-dashed border-border">
      <span class="absolute right-[calc(100%+8px)] -top-2 whitespace-nowrap font-mono text-[11px] text-muted-foreground">{@mid}</span>
    </div>
    <div class="absolute inset-x-0 top-full border-t border-border">
      <span class="absolute right-[calc(100%+8px)] -top-2 font-mono text-[11px] text-muted-foreground">0</span>
    </div>
    """
  end

  slot :inner_block, required: true

  # An empty plot says so, instead of a scale with nothing on it.
  defp empty(assigns) do
    ~H"""
    <div class="absolute inset-0 flex items-center justify-center border-b border-border">
      <p class="text-xs text-muted-foreground">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr :timeline, :list, required: true

  defp x_axis(assigns) do
    assigns = assign(assigns, labels: axis(assigns.timeline))

    ~H"""
    <div class="mx-4 mb-3.5 ml-[52px] mt-2 flex justify-between font-mono text-[11px] text-muted-foreground">
      <span :for={label <- @labels}>{label}</span>
    </div>
    """
  end

  # ---- Sparkline ----------------------------------------------------------------

  attr :values, :list, required: true
  attr :class, :string, default: "text-subtle-foreground"

  attr :zero, :boolean,
    default: false,
    doc: "anchor the baseline at 0 (counts) rather than the minimum"

  attr :labels, :list,
    default: nil,
    doc: "a tooltip title per value (e.g. `bucket_labels/1`); without them, no hover"

  attr :format, :any,
    default: &Format.int/1,
    doc: "a value as its tooltip body, e.g. `&\"\#{Format.pct(&1)} failed\"`"

  def sparkline(assigns) do
    coords = spark(assigns.values, assigns.zero)

    assigns =
      assign(assigns,
        points: coords && Enum.map_join(coords, " ", fn {x, y} -> "#{x},#{y}" end),
        tips: spark_tips(assigns),
        series: [
          %{ys: Enum.map(coords || [], &Float.round(elem(&1, 1) / 28 * 100, 2)), class: nil}
        ]
      )

    ~H"""
    <div :if={@points} class={["relative h-7 w-full", @class]}>
      <svg viewBox="0 0 100 28" preserveAspectRatio="none" class="h-full w-full" aria-hidden="true">
        <polyline points={@points} fill="none" stroke="currentColor" stroke-width="1.5" vector-effect="non-scaling-stroke" stroke-linejoin="round" />
      </svg>
      <.point_hover :if={@tips} tips={@tips} series={@series} />
    </div>
    """
  end

  defp spark_tips(%{labels: labels, values: values, format: format})
       when is_list(labels) and length(labels) == length(values) do
    Enum.zip_with(labels, values, fn
      label, nil -> {label, "no data", nil}
      label, value -> {label, format.(value), nil}
    end)
  end

  defp spark_tips(_assigns), do: nil

  attr :value, :any, required: true
  attr :top, :any, required: true
  attr :class, :string, default: "bg-primary"
  attr :tip, :string, default: nil, doc: "tooltip body; default: the value against the top"
  attr :tip_title, :string, default: nil

  def meter(assigns) do
    assigns = assign(assigns, tip: assigns.tip || meter_tip(assigns.value, assigns.top))

    ~H"""
    <div class="-my-1.5 py-1.5" data-tip={@tip} data-tip-title={@tip_title}>
      <div class="h-1.5 rounded-full bg-secondary">
        <div class={["h-1.5 rounded-full", @class]} style={"width: #{bar_pct(@value, @top)}%"}></div>
      </div>
    </div>
    """
  end

  defp meter_tip(nil, _top), do: nil
  defp meter_tip(value, top) when top in [0, nil], do: Format.int(value)

  defp meter_tip(value, top),
    do: "#{Format.int(value)} of #{Format.int(top)} · #{Format.pct(value / top)}"

  # ---- Math -------------------------------------------------------------------

  @doc false
  def bar_pct(nil, _top), do: 0
  def bar_pct(_value, top) when top in [0, nil], do: 0
  def bar_pct(value, top), do: Float.round(min(value / top * 100, 100.0), 2)

  @doc false
  def nice_max(max) when max <= 0, do: 10

  def nice_max(max) do
    magnitude = :math.pow(10, floor(:math.log10(max))) |> round() |> max(1)
    Enum.find([1, 2, 5, 10], 10, &(&1 * magnitude >= max)) * magnitude
  end

  # A count axis whose middle gridline is a whole number: 1 → 2, 5 → 6.
  @doc false
  def count_max(max) do
    top = nice_max(max)
    if top < 10 and rem(top, 2) == 1, do: top + 1, else: top
  end

  defp spark([], _zero), do: nil

  defp spark(values, zero) do
    values = Enum.map(values, &(&1 || 0))
    {lo, hi} = Enum.min_max(values)
    lo = if zero, do: min(lo, 0), else: lo
    span = if hi == lo, do: 1, else: hi - lo
    last = max(length(values) - 1, 1)

    values
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      {Float.round(i / last * 100, 1), Float.round(26 - (v - lo) / span * 24, 1)}
    end)
  end

  # Each point's height as a percent from the top (the viewBox is 100 tall).
  defp ys(points), do: Enum.map(points, &(&1 && elem(&1, 1)))

  # Missing values (no data in a bucket) break the line instead of dropping
  # it to zero.
  defp points(values, ceiling) do
    last = max(length(values) - 1, 1)

    values
    |> Enum.with_index()
    |> Enum.map(fn
      {nil, _i} ->
        nil

      {v, i} ->
        {Float.round(i / last * 1000, 1), Float.round(100 - min(v / ceiling, 1.0) * 100, 1)}
    end)
  end

  # A point with no neighbour has no line through it; draw it as a dot (a
  # zero-length stroke with round caps) so a lone bucket still shows.
  defp dots(points) do
    points
    |> Enum.chunk_by(&is_nil/1)
    |> Enum.flat_map(fn
      [{x, y}] -> ["M#{x},#{y} h0"]
      _chunk -> []
    end)
    |> Enum.join(" ")
  end

  defp path(points) do
    points
    |> Enum.chunk_by(&is_nil/1)
    |> Enum.reject(&(hd(&1) == nil))
    |> Enum.map_join(" ", fn [{x, y} | rest] ->
      "M#{x},#{y}" <> Enum.map_join(rest, "", fn {x, y} -> " L#{x},#{y}" end)
    end)
  end

  defp axis([]), do: []

  defp axis(timeline) do
    first = hd(timeline).at
    span = DateTime.diff(List.last(timeline).at, first, :second)
    fmt = if span > 172_800, do: "%b %-d", else: "%H:%M"

    labels =
      for i <- 0..3, do: Calendar.strftime(DateTime.add(first, div(span * i, 4), :second), fmt)

    labels ++ ["now"]
  end

  defp stamp(at), do: Calendar.strftime(at, "%b %-d %H:%M") <> " UTC"
end
