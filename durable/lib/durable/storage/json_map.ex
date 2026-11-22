defmodule Durable.Storage.JsonMap do
  @moduledoc false
  # A `:map` column that hands a float back as a float.
  #
  # A JSON encoder writes a whole float the short way, `2.0e6` or `1.0e3`.
  # jsonb keeps a number's digits and not how it was written, and that one has
  # none after the point: it prints `2000000`, which is read back as an integer.
  # Written out with its point, `2000000.0`, it stays a float.

  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value), do: Ecto.Type.cast(:map, value)

  @impl true
  def load(value), do: Ecto.Type.load(:map, value)

  @impl true
  def dump(value) when is_map(value) do
    # ponytail: Jason only. Another `config :postgrex, :json_library` can't
    # take a Jason.Fragment, so there a whole float still comes back an integer.
    if Application.get_env(:postgrex, :json_library, Jason) == Jason,
      do: {:ok, with_point(value)},
      else: {:ok, value}
  end

  def dump(_value), do: :error

  defp with_point(float) when is_float(float) and trunc(float) == float and float != 0.0,
    do: Jason.Fragment.new(Integer.to_string(trunc(float)) <> ".0")

  defp with_point(%_{} = struct), do: struct
  defp with_point(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, with_point(v)} end)
  defp with_point(list) when is_list(list), do: Enum.map(list, &with_point/1)
  defp with_point(other), do: other
end
