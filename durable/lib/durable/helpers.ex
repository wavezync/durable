defmodule Durable.Helpers do
  @moduledoc """
  Helper functions for working with workflow data in the pipeline model.

  These functions provide a convenient, pipe-friendly API for updating
  the data that flows through workflow steps.

  ## Usage

      use Durable.Helpers

  This imports all helper functions into your workflow module.

  ## Keys

  A workflow's data has string keys at every depth, as it is stored. Each
  helper takes a key as an atom or a string and reads or writes the string:
  `assign(data, :status, "paid")` sets `data["status"]`.

  ## Best practice

  Read and write a workflow's data through these helpers. They let a step name
  its keys with atoms, as Elixir code usually does, over data that is stored
  with strings:

      step :charge, fn order ->
        total = get(order, :total)                  # order["total"]
        city = get(order, [:customer, :city])       # order["customer"]["city"]
        {:ok, assign(order, :charged, total)}       # sets order["charged"]
      end

  `order.total`, `order[:total]` and `%{total: total} = order` don't read the
  data: its keys are strings. `Map.put(order, :total, 1)` in the middle of a
  step leaves `:total` beside the stored `"total"` until the step returns, so
  a later `get(order, :total)` in that step still reads the old one;
  `assign/3` writes the string and has no such gap.

  ## Examples

      step :process, fn data ->
        {:ok, data
        |> assign(:status, :processing)
        |> assign(%{started_at: DateTime.utc_now()})
        |> increment(:step_count)}
      end

  """

  @doc """
  Injects helper functions into the calling module.
  """
  defmacro __using__(_opts) do
    quote do
      import Durable.Helpers,
        only: [
          assign: 2,
          assign: 3,
          update: 3,
          update: 4,
          append: 3,
          increment: 2,
          increment: 3,
          delete: 2,
          has_key?: 2,
          get: 2,
          get: 3
        ]
    end
  end

  @doc """
  Assigns a value to a key in the data map.

  ## Examples

      assign(data, :order_id, 123)
      assign(data, "order_id", 123)

  """
  @spec assign(map(), atom() | String.t(), term()) :: map()
  def assign(data, key, value) when is_map(data) and (is_atom(key) or is_binary(key)) do
    Map.put(data, to_string(key), value)
  end

  @doc """
  Merges a map into the data.

  ## Examples

      assign(data, %{order_id: 123, status: :pending})

  """
  @spec assign(map(), map()) :: map()
  def assign(data, map) when is_map(data) and is_map(map) do
    Map.merge(data, Map.new(map, fn {key, value} -> {to_string(key), value} end))
  end

  @doc """
  Updates a value in the data using a function.

  If the key doesn't exist, uses the default value.

  ## Examples

      update(data, :count, 0, &(&1 + 1))
      update(data, :items, [], &[new_item | &1])

  """
  @spec update(map(), atom() | String.t(), term(), (term() -> term())) :: map()
  def update(data, key, default, fun) when is_map(data) and is_function(fun, 1) do
    Map.update(data, to_string(key), default, fun)
  end

  @doc """
  Updates an existing value in the data using a function.

  Raises if the key doesn't exist.

  ## Examples

      update(data, :count, &(&1 + 1))

  """
  @spec update(map(), atom() | String.t(), (term() -> term())) :: map()
  def update(data, key, fun) when is_map(data) and is_function(fun, 1) do
    Map.update!(data, to_string(key), fun)
  end

  @doc """
  Appends a value to a list in the data.

  If the key doesn't exist, creates a new list with the value.

  ## Examples

      append(data, :items, new_item)
      append(data, :events, %{type: :clicked, time: DateTime.utc_now()})

  """
  @spec append(map(), atom() | String.t(), term()) :: map()
  def append(data, key, value) when is_map(data) do
    update(data, key, [value], fn list -> list ++ [value] end)
  end

  @doc """
  Increments a numeric value in the data.

  If the key doesn't exist, starts from 0.

  ## Examples

      increment(data, :retry_count)
      increment(data, :total, 100)

  """
  @spec increment(map(), atom() | String.t(), number()) :: map()
  def increment(data, key, amount \\ 1) when is_map(data) and is_number(amount) do
    update(data, key, amount, fn val -> val + amount end)
  end

  @doc """
  Deletes a key from the data.

  ## Examples

      delete(data, :temporary_value)

  """
  @spec delete(map(), atom() | String.t()) :: map()
  def delete(data, key) when is_map(data) do
    Map.delete(data, to_string(key))
  end

  @doc """
  Checks if a key exists in the data.

  ## Examples

      if has_key?(data, :order_id) do
        # ...
      end

  """
  @spec has_key?(map(), atom() | String.t()) :: boolean()
  def has_key?(data, key) when is_map(data) do
    Map.has_key?(data, to_string(key))
  end

  @doc """
  Gets a value from the data.

  Returns nil if the key doesn't exist.

  ## Examples

      order_id = get(data, :order_id)

  A list is a path into the maps inside the data:

      total = get(data, [:invoice, :total])

  """
  @spec get(map(), atom() | String.t() | [atom() | String.t()]) :: term()
  def get(data, key) when is_map(data), do: get(data, key, nil)

  @doc """
  Gets a value from the data with a default.

  ## Examples

      count = get(data, :retry_count, 0)

  """
  @spec get(map(), atom() | String.t() | [atom() | String.t()], term()) :: term()
  def get(data, path, default) when is_map(data) and is_list(path) do
    case get_in(data, Enum.map(path, &to_string/1)) do
      nil -> default
      value -> value
    end
  end

  def get(data, key, default) when is_map(data) do
    Map.get(data, to_string(key), default)
  end
end
