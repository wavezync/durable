defmodule Durable.Context do
  @moduledoc """
  Context management for workflow execution.

  The context is a key-value store that persists across steps within a workflow.
  It provides a way to share state between steps and is automatically persisted
  to the database after each step completes.

  ## Usage

      defmodule MyApp.OrderWorkflow do
        use Durable
        use Durable.Context

        workflow "process_order" do
          step :init do
            order = input().order
            put_context(:order_id, order.id)
            put_context(:items, order.items)
          end

          step :calculate_total do
            items = get_context(:items)
            total = Enum.sum(Enum.map(items, & &1.price))
            put_context(:total, total)
          end

          step :finalize do
            %{
              order_id: get_context(:order_id),
              total: get_context(:total)
            }
          end
        end
      end

  ## Context Storage

  During execution, context is stored in the process dictionary for fast access.
  After each step completes, the context is persisted to the database.
  When a workflow resumes (e.g., after a sleep or wait), the context is
  restored from the database.

  """

  @context_key :durable_context
  @input_key :durable_input
  @workflow_id_key :durable_workflow_id
  @step_key :durable_current_step

  @doc """
  Injects context management functions into the calling module.
  """
  defmacro __using__(_opts) do
    quote do
      import Durable.Context,
        only: [
          context: 0,
          get_context: 1,
          get_context: 2,
          put_context: 1,
          put_context: 2,
          update_context: 2,
          merge_context: 1,
          delete_context: 1,
          has_context?: 1,
          input: 0,
          workflow_id: 0,
          current_step: 0,
          append_context: 2,
          increment_context: 2,
          parallel_results: 0,
          parallel_result: 1,
          parallel_ok?: 1
        ]
    end
  end

  @doc """
  Returns the entire context map.

  ## Examples

      ctx = context()
      # => %{order_id: 123, items: [...]}

  """
  @spec context() :: map()
  def context do
    Process.get(@context_key, %{})
  end

  @doc """
  Gets a value from the context by key.

  Returns `nil` if the key doesn't exist.

  ## Examples

      order_id = get_context(:order_id)

  """
  @spec get_context(atom() | String.t()) :: any()
  def get_context(key) do
    get_context(key, nil)
  end

  @doc """
  Gets a value from the context by key with a default.

  ## Examples

      count = get_context(:retry_count, 0)
      count = get_context("retry_count", 0)

  """
  @spec get_context(atom() | String.t(), any()) :: any()
  def get_context(key, default) do
    context()
    |> Map.get(normalize_key(key), default)
  end

  @doc """
  Puts a single key-value pair into the context.

  ## Examples

      put_context(:order_id, 123)
      put_context("order_id", 123)

  """
  @spec put_context(atom() | String.t(), any()) :: :ok
  def put_context(key, value) do
    new_context = Map.put(context(), normalize_key(key), value)
    Process.put(@context_key, new_context)
    :ok
  end

  @doc """
  Merges a map into the context.

  ## Examples

      put_context(%{order_id: 123, customer_id: 456})

  """
  @spec put_context(map()) :: :ok
  def put_context(map) when is_map(map) do
    new_context = Map.merge(context(), map)
    Process.put(@context_key, new_context)
    :ok
  end

  @doc """
  Updates a context value using a function.

  ## Examples

      update_context(:retry_count, &(&1 + 1))
      update_context(:items, &[new_item | &1])

  """
  @spec update_context(atom() | String.t(), (any() -> any())) :: :ok
  def update_context(key, fun) when is_function(fun, 1) do
    current_value = get_context(key)
    new_value = fun.(current_value)
    put_context(key, new_value)
  end

  @doc """
  Deep merges a map into the context.

  ## Examples

      merge_context(%{settings: %{notifications: true}})

  """
  @spec merge_context(map()) :: :ok
  def merge_context(map) when is_map(map) do
    new_context = deep_merge(context(), map)
    Process.put(@context_key, new_context)
    :ok
  end

  @doc """
  Deletes a key from the context.

  ## Examples

      delete_context(:temporary_data)
      delete_context("temporary_data")

  """
  @spec delete_context(atom() | String.t()) :: :ok
  def delete_context(key) do
    new_context = Map.delete(context(), normalize_key(key))
    Process.put(@context_key, new_context)
    :ok
  end

  @doc """
  Checks if a key exists in the context.

  ## Examples

      if has_context?(:order_id) do
        # ...
      end

  """
  @spec has_context?(atom() | String.t()) :: boolean()
  def has_context?(key) do
    Map.has_key?(context(), normalize_key(key))
  end

  @doc """
  Returns the initial workflow input.

  ## Examples

      order = input().order

  """
  @spec input() :: map()
  def input do
    Process.get(@input_key, %{})
  end

  @doc """
  Returns the current workflow ID.

  ## Examples

      id = workflow_id()

  """
  @spec workflow_id() :: String.t() | nil
  def workflow_id do
    Process.get(@workflow_id_key)
  end

  @doc """
  Returns the current step name.

  ## Examples

      step = current_step()

  """
  @spec current_step() :: atom() | nil
  def current_step do
    Process.get(@step_key)
  end

  @doc """
  Appends a value to a list in the context.

  If the key doesn't exist, creates a new list with the value.

  ## Examples

      append_context(:events, %{type: :clicked, timestamp: DateTime.utc_now()})

  """
  @spec append_context(atom() | String.t(), any()) :: :ok
  def append_context(key, value) do
    current = get_context(key, [])
    put_context(key, current ++ [value])
  end

  @doc """
  Increments a numeric value in the context.

  If the key doesn't exist, starts from 0.

  ## Examples

      increment_context(:retry_count, 1)
      increment_context(:processed_items, 1)

  """
  @spec increment_context(atom() | String.t(), number()) :: :ok
  def increment_context(key, amount \\ 1) do
    current = get_context(key, 0)
    put_context(key, current + amount)
  end

  @doc """
  Returns the full parallel results map from context.

  The results map contains tagged tuples: `%{step_name => {:ok, data} | {:error, reason}}`

  ## Examples

      parallel do
        step :payment, fn ctx -> {:ok, %{id: 123}} end
        step :delivery, fn ctx -> {:error, :not_found} end
      end

      step :handle, fn ctx ->
        results = parallel_results()
        # => %{payment: {:ok, %{id: 123}}, delivery: {:error, :not_found}}
      end

  """
  @spec parallel_results() :: map()
  def parallel_results do
    get_context(:__results__, %{})
  end

  @doc """
  Returns a specific parallel step's result by name.

  ## Examples

      step :handle, fn ctx ->
        case parallel_result(:payment) do
          {:ok, payment} -> # handle success
          {:error, reason} -> # handle error
        end
      end

  """
  @spec parallel_result(atom()) :: {:ok, any()} | {:error, any()} | nil
  def parallel_result(step_name) when is_atom(step_name) do
    parallel_results() |> Map.get(step_name)
  end

  @doc """
  Checks if a parallel step succeeded.

  ## Examples

      step :handle, fn ctx ->
        if parallel_ok?(:payment) do
          # payment succeeded
        else
          # payment failed
        end
      end

  """
  @spec parallel_ok?(atom()) :: boolean()
  def parallel_ok?(step_name) when is_atom(step_name) do
    case parallel_result(step_name) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # Internal functions for executor use

  @doc false
  def init_context(input, workflow_id) do
    Process.put(@context_key, %{})
    Process.put(@input_key, input)
    Process.put(@workflow_id_key, workflow_id)
    :ok
  end

  @doc false
  def restore_context(context_map, input, workflow_id) do
    # Convert string keys to atoms since JSON encoding converts atoms to strings
    atomized_context = atomize_keys(context_map || %{})
    Process.put(@context_key, atomized_context)
    Process.put(@input_key, input)
    Process.put(@workflow_id_key, workflow_id)
    :ok
  end

  # Convert string keys to atoms (for context restored from database)
  # Only converts top-level keys, nested maps keep their original keys
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  @doc false
  def set_current_step(step_name) do
    Process.put(@step_key, step_name)
    :ok
  end

  @doc false
  def set_workflow_id(workflow_id) do
    Process.put(@workflow_id_key, workflow_id)
    :ok
  end

  @doc false
  def get_current_context do
    context()
  end

  @doc false
  def cleanup do
    Process.delete(@context_key)
    Process.delete(@input_key)
    Process.delete(@workflow_id_key)
    Process.delete(@step_key)
    # Log capture keys (cleanup in case of crashes)
    Process.delete(:durable_logs)
    Process.delete(:durable_original_group_leader)
    Process.delete(:durable_io_capture_pid)
    :ok
  end

  # Helper functions

  # Normalize keys to atoms for consistency
  # (JSON encoding converts atoms to strings, so we normalize back)
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end
end
