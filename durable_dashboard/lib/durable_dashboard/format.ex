defmodule DurableDashboard.Format do
  @moduledoc "Number formatting shared by the dashboard's pages."

  @doc "`12482` → `12,482`; nil → `—`."
  def int(nil), do: "—"

  def int(n) when is_integer(n),
    do: n |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  def int(n) when is_float(n), do: int(round(n))

  @doc "A count and its noun: `count(1, \"queue\")` → `1 queue`, `count(1200, \"run\")` → `1,200 runs`."
  def count(n, singular, plural \\ nil)
  def count(1, singular, _plural), do: "1 #{singular}"
  def count(n, singular, plural), do: "#{int(n)} #{plural || singular <> "s"}"

  @doc "A ratio as a percentage: `0.0172` → `1.7%`."
  def pct(nil), do: "—"
  def pct(ratio) when ratio == 0, do: "0%"

  def pct(ratio) do
    text = :erlang.float_to_binary(ratio * 100, decimals: 1)
    String.replace_suffix(text, ".0", "") <> "%"
  end

  @doc "Milliseconds, readable at a glance (see `DurableDashboard.Trace.format_ms/1`)."
  defdelegate ms(value), to: DurableDashboard.Trace, as: :format_ms

  @doc """
  A configured duration in its largest whole unit: `30_000` → `30 s`,
  `1_209_600_000` → `14 days`, `250` → `250 ms`.
  """
  def duration(ms) do
    Enum.find_value(
      [{86_400_000, "day"}, {3_600_000, "h"}, {60_000, "min"}, {1_000, "s"}],
      "#{ms} ms",
      fn {size, unit} -> rem(ms, size) == 0 and ms >= size and unit_text(div(ms, size), unit) end
    )
  end

  defp unit_text(1, "day"), do: "1 day"
  defp unit_text(n, "day"), do: "#{n} days"
  defp unit_text(n, unit), do: "#{n} #{unit}"

  @doc "Change between two counts as `▲ 8.1%` / `▼ 3.0%` / nil when there's no baseline."
  def change(_now, 0), do: nil
  def change(_now, nil), do: nil

  def change(now, before) do
    delta = (now - before) / before * 100
    arrow = if delta >= 0, do: "▲", else: "▼"
    "#{arrow} #{:erlang.float_to_binary(abs(delta), decimals: 1)}%"
  end

  @doc "Change between two ratios in percentage points: `▲ 0.9 pt`."
  def pt_change(now, before) do
    delta = (now - before) * 100
    arrow = if delta >= 0, do: "▲", else: "▼"
    "#{arrow} #{:erlang.float_to_binary(abs(delta), decimals: 1)} pt"
  end
end
