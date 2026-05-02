defmodule Durable.DSL.TimeHelpers do
  @moduledoc """
  Helper functions for expressing time durations in workflow definitions.

  ## Examples

      workflow "process_order", timeout: hours(2) do
        step :wait_for_confirmation do
          sleep_for(minutes(30))
        end
      end

  """

  @doc """
  Converts seconds to milliseconds.

  ## Examples

      iex> seconds(30)
      30_000

  """
  defmacro seconds(n) do
    quote do: unquote(n) * 1_000
  end

  @doc """
  Converts minutes to milliseconds.

  ## Examples

      iex> minutes(5)
      300_000

  """
  defmacro minutes(n) do
    quote do: unquote(n) * 60 * 1_000
  end

  @doc """
  Converts hours to milliseconds.

  ## Examples

      iex> hours(2)
      7_200_000

  """
  defmacro hours(n) do
    quote do: unquote(n) * 60 * 60 * 1_000
  end

  @doc """
  Converts days to milliseconds.

  ## Examples

      iex> days(7)
      604_800_000

  """
  defmacro days(n) do
    quote do: unquote(n) * 24 * 60 * 60 * 1_000
  end
end
