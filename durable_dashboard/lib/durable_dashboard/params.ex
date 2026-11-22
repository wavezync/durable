defmodule DurableDashboard.Params do
  @moduledoc """
  Reads what the browser sent: URL params and event payloads. Any of them can
  be missing, a list or a map (`?q[]=a`), a number no page has, or bytes that
  aren't text. Pages read them through here so each falls back to its default
  instead of raising.
  """

  # 25 million rows at 25 a page; an offset past int8 is an error in Postgres.
  @max_page 1_000_000

  # Stands in for text Postgres can't hold: it reads as text and matches nothing.
  @unmatchable "�"

  @doc """
  A text param. `nil` when it's absent, blank or not text (a list or a map).
  Text with a NUL byte or invalid UTF-8 can't be stored, so it can't match
  anything: it becomes `"�"`, which is safe to query and to show, and
  finds nothing.
  """
  @spec text(term()) :: String.t() | nil
  def text(value) when is_binary(value) do
    cond do
      value == "" -> nil
      String.valid?(value) and not String.contains?(value, <<0>>) -> value
      true -> @unmatchable
    end
  end

  def text(_value), do: nil

  @doc "A page number from 1 to a million; 1 for anything that isn't a number."
  @spec page(term()) :: pos_integer()
  def page(value) when is_integer(value), do: value |> max(1) |> min(@max_page)

  def page(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> page(number)
      :error -> 1
    end
  end

  def page(_value), do: 1

  @doc "A comma-separated param as a list: `\"failed,cancelled\"` → `[\"failed\", \"cancelled\"]`."
  @spec list(term()) :: [String.t()]
  def list(value), do: String.split(text(value) || "", ",", trim: true)
end
