defmodule DurableDashboard.Components.ChartsTest do
  @moduledoc "Every chart mark carries a tooltip: its bucket's span and values."

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Charts

  defp bucket(minute, overrides \\ %{}) do
    Map.merge(
      %{
        at: DateTime.new!(~D[2026-10-17], Time.new!(2, minute, 0)),
        started: 4,
        completed: 3,
        failed: 1,
        cancelled: 0,
        failure_rate: 0.25,
        p50_ms: 120,
        p95_ms: 900
      },
      overrides
    )
  end

  defp tips(html, attr \\ "data-tip") do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("[#{attr}]") |> LazyHTML.attribute(attr)
  end

  test "a count axis halves to a whole number" do
    assert Enum.map([1, 3, 5, 7, 40], &Charts.count_max/1) == [2, 6, 6, 10, 50]
  end

  test "an empty window says so instead of drawing a scale" do
    empty = bucket(0, %{completed: 0, failed: 0, cancelled: 0, p50_ms: nil, p95_ms: nil})

    assert render_component(&Charts.stacked_bars/1, timeline: [empty]) =~ "No runs finished"
    assert render_component(&Charts.percentile_lines/1, timeline: [empty]) =~ "No runs completed"
  end

  test "a lone point in a line chart is drawn as a dot" do
    gap = bucket(0, %{p50_ms: nil, p95_ms: nil})
    html = render_component(&Charts.percentile_lines/1, timeline: [gap, bucket(30), gap])

    assert html =~ ~r/d="M500\.0,[\d.]+ h0"/
  end

  test "buckets are labelled with their span" do
    assert Charts.bucket_labels([bucket(0), bucket(30)]) == [
             "Oct 17, 02:00–02:30 UTC",
             "Oct 17, 02:30–03:00 UTC"
           ]
  end

  test "stacked bars: a tooltip per bucket with each series' count" do
    html = render_component(&Charts.stacked_bars/1, timeline: [bucket(0), bucket(30)])

    assert tips(html, "data-tip-title") == ["Oct 17, 02:00–02:30 UTC", "Oct 17, 02:30–03:00 UTC"]
    assert hd(tips(html)) == "3 completed\n1 failed\n0 cancelled"
    assert hd(tips(html, "data-tip-meta")) == "4 finished · 25% failed"
  end

  test "lines: a hover column per point, with a dot only where there's a value" do
    timeline = [bucket(0), bucket(30, %{p50_ms: nil, p95_ms: nil})]
    html = render_component(&Charts.percentile_lines/1, timeline: timeline)

    assert tips(html) == ["p95 900ms\np50 120ms", "no completed runs"]
    # Two series' dots on the first point, none on the empty one.
    assert html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(".rounded-full.bg-current")
           |> Enum.count() == 2
  end

  test "sparklines hover only when given labels" do
    assert tips(render_component(&Charts.sparkline/1, values: [1, 2])) == []

    html =
      render_component(&Charts.sparkline/1,
        values: [1, nil],
        labels: ["02:00", "02:01"],
        format: &"#{&1} ready"
      )

    assert tips(html) == ["1 ready", "no data"]
  end

  test "a meter says the value against its top" do
    assert tips(render_component(&Charts.meter/1, value: 3, top: 12)) == ["3 of 12 · 25%"]
  end
end
