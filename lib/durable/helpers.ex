defmodule Durable.Helpers do
  @moduledoc """
  Helper functions for working with workflow data in the pipeline model.

  These functions provide a convenient, pipe-friendly API for updating
  the data that flows through workflow steps.

  ## Usage

      use Durable.Helpers

  This imports all helper functions into your workflow module.

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
    Map.put(data, key, value)
  end

  @doc """
  Merges a map into the data.

  ## Examples

      assign(data, %{order_id: 123, status: :pending})

  """
  @spec assign(map(), map()) :: map()
  def assign(data, map) when is_map(data) and is_map(map) do
    Map.merge(data, map)
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
    Map.update(data, key, default, fun)
  end

  @doc """
  Updates an existing value in the data using a function.

  Raises if the key doesn't exist.

  ## Examples

      update(data, :count, &(&1 + 1))

  """
  @spec update(map(), atom() | String.t(), (term() -> term())) :: map()
  def update(data, key, fun) when is_map(data) and is_function(fun, 1) do
    Map.update!(data, key, fun)
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
    update(data, key, [], fn list -> list ++ [value] end)
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
    update(data, key, 0, fn val -> val + amount end)
  end

  @doc """
  Deletes a key from the data.

  ## Examples

      delete(data, :temporary_value)

  """
  @spec delete(map(), atom() | String.t()) :: map()
  def delete(data, key) when is_map(data) do
    Map.delete(data, key)
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
    Map.has_key?(data, key)
  end

  @doc """
  Gets a value from the data.

  Returns nil if the key doesn't exist.

  ## Examples

      order_id = get(data, :order_id)

  """
  @spec get(map(), atom() | String.t()) :: term()
  def get(data, key) when is_map(data) do
    Map.get(data, key)
  end

  @doc """
  Gets a value from the data with a default.

  ## Examples

      count = get(data, :retry_count, 0)

  """
  @spec get(map(), atom() | String.t(), term()) :: term()
  def get(data, key, default) when is_map(data) do
    Map.get(data, key, default)
  end
end
