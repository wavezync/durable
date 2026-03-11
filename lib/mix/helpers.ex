defmodule Durable.Mix.Helpers do
  @moduledoc false

  # Shared utilities for Durable mix tasks.

  @doc """
  Ensures the application is started.
  """
  def ensure_started do
    Mix.Task.run("app.start")
  end

  @doc """
  Parses --name option, returns Durable instance name atom.
  """
  def get_durable_name(opts) do
    case Keyword.get(opts, :name) do
      nil -> Durable
      name -> Module.concat([name])
    end
  end

  @doc """
  Formats rows into an aligned table with headers.
  """
  def format_table(rows, headers) do
    all = [headers | rows]

    widths =
      Enum.reduce(all, List.duplicate(0, length(headers)), fn row, widths ->
        row
        |> Enum.map(&String.length(to_string(&1)))
        |> Enum.zip(widths)
        |> Enum.map(fn {a, b} -> max(a, b) end)
      end)

    format_row = fn row ->
      row
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {val, width} ->
        String.pad_trailing(to_string(val), width)
      end)
    end

    header_line = format_row.(headers)
    data_lines = Enum.map(rows, format_row)
    [header_line | data_lines]
  end

  @doc """
  Truncates a UUID to the first 8 characters.
  """
  def truncate_id(nil), do: "—"

  def truncate_id(id) when is_binary(id) do
    String.slice(id, 0, 8)
  end

  @doc """
  Formats a duration between two datetimes as a human-readable string.
  """
  def format_duration(nil, _), do: "—"
  def format_duration(_, nil), do: "—"

  def format_duration(started_at, completed_at) do
    diff = DateTime.diff(completed_at, started_at, :second)
    format_seconds(diff)
  end

  @doc """
  Formats a number of seconds into a human-readable duration string.
  """
  def format_seconds(seconds) when seconds < 60, do: "#{seconds}s"

  def format_seconds(seconds) when seconds < 3600 do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    if s == 0, do: "#{m}m", else: "#{m}m #{s}s"
  end

  def format_seconds(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    if m == 0, do: "#{h}h", else: "#{h}h #{m}m"
  end

  @doc """
  Formats a DateTime as "YYYY-MM-DD HH:MM:SS" or "—" for nil.
  """
  def format_datetime(nil), do: "—"

  def format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  @doc """
  Formats an integer with comma separators.
  """
  def format_number(n) when is_integer(n) and n < 0 do
    "-" <> format_number(-n)
  end

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.reverse/1)
    |> String.reverse()
    |> String.reverse()
  end

  @doc """
  Strips the "Elixir." prefix from a module name string.
  """
  def strip_elixir_prefix(module_str) when is_binary(module_str) do
    String.replace_prefix(module_str, "Elixir.", "")
  end
end
