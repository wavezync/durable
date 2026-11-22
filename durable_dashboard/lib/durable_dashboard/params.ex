defmodule DurableDashboard.Params do
  @moduledoc """
  Reads what the browser sent: URL params and event payloads. Any of them can
  be missing, a list or a map (`?q[]=a`), a number no page has, or bytes that
  aren't text. Pages read them through here so each falls back to its default
  instead of raising.
  """

  require Logger

  @doc """
  The reply to an event nothing handles: one the page doesn't have, or one
  that came without what its handler needs (no run loaded, a param missing or
  of the wrong shape). Ignored, and logged at debug. Every LiveView and live
  component ends its `handle_event/3` clauses with this.
  """
  @spec ignore(term(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def ignore(event, socket) do
    Logger.debug(fn ->
      "DurableDashboard: ignored event #{inspect(event, limit: 5, printable_limit: 80)} " <>
        "on #{inspect(socket.view)}"
    end)

    {:noreply, socket}
  end

  # 25 million rows at 25 a page; an offset past int8 is an error in Postgres.
  @max_page 1_000_000

  # Stands in for text Postgres can't hold: it reads as text and matches nothing.
  @unmatchable <<0xFFFD::utf8>>

  @doc """
  A text param. `nil` when it's absent, blank or not text (a list or a map).
  Text with a NUL byte or invalid UTF-8 can't be stored, so it can't match
  anything: it becomes U+FFFD (the replacement character), which is safe to query and to show, and
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
  def page(value), do: value |> int(1) |> max(1) |> min(@max_page)

  @doc "A whole number, sent as one or as text; `default` for anything else."
  @spec int(term(), integer()) :: integer()
  def int(value, _default) when is_integer(value), do: value

  def int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> default
    end
  end

  def int(_value, default), do: default

  @doc "A comma-separated param as a list: `\"failed,cancelled\"` → `[\"failed\", \"cancelled\"]`."
  @spec list(term()) :: [String.t()]
  def list(value), do: String.split(text(value) || "", ",", trim: true)
end
