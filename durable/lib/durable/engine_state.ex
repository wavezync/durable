defmodule Durable.EngineState do
  @moduledoc false
  # The names the engine keeps its own state under. A run's data comes from
  # outside (a start's input, a step's result, an event's payload), so none of
  # these may reach the engine from it: `strip/1` drops them wherever the
  # user's data comes in.

  @keys ~w(
    __fail__ __rollback__ __done__ __string_keys__ __atom_keys__
    __parallel_step __parallel_children __parallel_wait_group_id __parallel_error_strategy
    __sleep_satisfied__ __timeout__ __cancelled__ __wait_group_result__ __wait_group_status__
    __call_children
  )

  # Followed by a ref or a run's id.
  @prefixes ~w(__child: __child_done: __fire_forget: __parallel_done:)

  @doc "Every engine key that is a whole name."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "The engine keys that are a prefix, followed by a ref or a run's id."
  @spec prefixes() :: [String.t()]
  def prefixes, do: @prefixes

  @doc "Whether a key of the user's, an atom or a string, is one of the engine's."
  @spec key?(term()) :: boolean()
  def key?(key) when is_binary(key),
    do: String.starts_with?(key, "__") and (key in @keys or String.starts_with?(key, @prefixes))

  def key?(key) when is_atom(key), do: key?(Atom.to_string(key))
  def key?(_key), do: false

  @doc "The user's data without the engine's keys. Only top-level keys are ever read."
  @spec strip(term()) :: term()
  def strip(data) when is_map(data) and not is_struct(data),
    do: Map.reject(data, fn {key, _value} -> key?(key) end)

  def strip(data), do: data
end
