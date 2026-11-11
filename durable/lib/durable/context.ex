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

  import Ecto.Query, only: [from: 2]

  alias Durable.Config
  alias Durable.Queue.Drainer
  alias Durable.Repo
  alias Durable.Storage.Schemas.WorkflowExecution

  @context_key :durable_context
  @input_key :durable_input
  @workflow_id_key :durable_workflow_id
  @step_key :durable_current_step
  @attempt_key :durable_attempt
  @instance_key :durable_instance

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
          attempt: 0,
          max_attempts: 0,
          last_attempt?: 0,
          shutting_down?: 0,
          cancelled?: 0,
          append_context: 2,
          increment_context: 2,
          parallel_results: 0,
          parallel_result: 1,
          parallel_ok?: 1,
          bind: 1
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
    context = context()
    Map.get(context, stored_key(context, key), default)
  end

  @doc """
  Puts a single key-value pair into the context.

  ## Examples

      put_context(:order_id, 123)
      put_context("order_id", 123)

  """
  @spec put_context(atom() | String.t(), any()) :: :ok
  def put_context(key, value) do
    context = context()
    Process.put(@context_key, Map.put(context, stored_key(context, key), value))
    :ok
  end

  @doc """
  Merges a map into the context.

  ## Examples

      put_context(%{order_id: 123, customer_id: 456})

  """
  @spec put_context(map()) :: :ok
  def put_context(map) when is_map(map) do
    context = context()
    Process.put(@context_key, Map.merge(context, as_stored(context, map)))
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
    context = context()
    Process.put(@context_key, deep_merge(context, as_stored(context, map)))
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
    context = context()
    Process.put(@context_key, Map.delete(context, stored_key(context, key)))
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
    context = context()
    Map.has_key?(context, stored_key(context, key))
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
  Returns which attempt of the current step this is, starting at 1.

  The count carries over when a run resumes after a crash, and starts again at
  1 after `Durable.retry/2`.

  ## Examples

      step :charge, [retry: [max_attempts: 5]], fn ctx ->
        Logger.info("charging, attempt \#{attempt()} of \#{max_attempts()}")
        ...
      end

  """
  @spec attempt() :: pos_integer()
  def attempt do
    {attempt, _max} = Process.get(@attempt_key, {1, 1})
    attempt
  end

  @doc """
  Returns how many attempts the current step gets: its `retry: [max_attempts: n]`,
  or 1 if it has no `retry:`.
  """
  @spec max_attempts() :: pos_integer()
  def max_attempts do
    {_attempt, max} = Process.get(@attempt_key, {1, 1})
    max
  end

  @doc """
  Returns `true` on the current step's last attempt: if it returns an error,
  the step won't be tried again.

  ## Examples

      step :charge, [retry: [max_attempts: 5]], fn ctx ->
        case Payments.charge(ctx.order) do
          {:ok, _} = ok -> ok
          {:error, reason} ->
            if last_attempt?(), do: Orders.mark_payment_failed(ctx.order)
            {:error, reason}
        end
      end

  """
  @spec last_attempt?() :: boolean()
  def last_attempt? do
    attempt() >= max_attempts()
  end

  @doc """
  Returns `true` once this node has started shutting down.

  The node finishes the step it's on, then hands the rest of the run to another
  node. A step that runs longer than the `:shutdown_grace_period` can check this
  and stop early. Snoozing doesn't use an attempt, and another node carries on
  straight away:

  ## Examples

      step :crawl, fn ctx ->
        for page <- pages_left(ctx), not shutting_down?(), do: crawl(page)

        if shutting_down?(),
          do: {:snooze, 0, "node stopping"},
          else: {:ok, ctx}
      end

  """
  @spec shutting_down?() :: boolean()
  def shutting_down? do
    Drainer.stopping?(Process.get(@instance_key, Durable))
  end

  @doc """
  Returns `true` once the run has been cancelled.

  A cancelled run's step is stopped at the worker's next heartbeat, killed like
  any process. A step that would rather stop cleanly, between two chunks of
  work, can check this first. It reads the database, so check it between chunks
  and not in a tight loop:

  ## Examples

      step :export, fn ctx ->
        for chunk <- chunks_left(ctx), not cancelled?(), do: export(chunk)
        {:ok, ctx}
      end

  """
  @spec cancelled?() :: boolean()
  def cancelled? do
    id = workflow_id()
    config = Config.get(Process.get(@instance_key, Durable))

    id != nil and
      Repo.one(config, from(w in WorkflowExecution, where: w.id == ^id, select: w.status)) ==
        :cancelled
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
    :__results__
    |> get_context(%{})
    |> Map.new(fn {name, result} -> {known_name(name), tagged_result(result)} end)
  end

  # Stored as JSON, as `["ok", data]` under the branch's name as a string.
  defp known_name(name) when is_binary(name), do: known_key(name)
  defp known_name(name), do: name

  defp tagged_result(["ok", value]), do: {:ok, value}
  defp tagged_result(["error", value]), do: {:error, value}
  defp tagged_result(result), do: result

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
  # A key restored from JSON becomes an atom only if that atom already exists, as
  # any key the code reads as `data.foo` does. One atom per distinct key is never
  # freed, and enough of them crash the VM.
  @spec known_key(String.t()) :: atom() | String.t()
  def known_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  # Everything of a step's that another process needs, leaving out the process's
  # own log buffer and IO capture.
  @unbound_keys [
    :durable_logs,
    :durable_log_step_body,
    :durable_io_capture_pid,
    :durable_original_group_leader
  ]

  @doc """
  Wraps a function so it runs as part of the current step in another process.

  A `Task` starts with none of the step's state. Wrapped, its function can read
  the context and has the step's Logger metadata and OpenTelemetry span, and
  its log lines are saved on the step's row. Lines from a plain `Task` still
  reach the console, but aren't saved.

      Task.await(Task.async(bind(fn -> fetch(order_id) end)))
      Task.async_stream(orders, bind(&fetch/1))

  Changes it makes to the context stay in its own process. Lines it logs after
  the step has ended aren't saved.
  """
  @spec bind((-> result)) :: (-> result) when result: term()
  @spec bind((arg -> result)) :: (arg -> result) when arg: term(), result: term()
  def bind(fun) when is_function(fun, 0) do
    state = step_state()

    fn ->
      restore_step_state(state)
      fun.()
    end
  end

  def bind(fun) when is_function(fun, 1) do
    state = step_state()

    fn arg ->
      restore_step_state(state)
      fun.(arg)
    end
  end

  @compile {:no_warn_undefined, :otel_ctx}

  defp step_state do
    %{
      dict: for({key, _} = entry <- Process.get(), step_key?(key), do: entry),
      logger: :logger.get_process_metadata(),
      otel: if(Code.ensure_loaded?(:otel_ctx), do: :otel_ctx.get_current())
    }
  end

  defp step_key?({Durable.Telemetry, _}), do: true

  defp step_key?(key) when is_atom(key),
    do: key not in @unbound_keys and String.starts_with?(Atom.to_string(key), "durable_")

  defp step_key?(_key), do: false

  defp restore_step_state(%{dict: dict, logger: logger, otel: otel}) do
    Enum.each(dict, fn {key, value} -> Process.put(key, value) end)
    if is_map(logger), do: :logger.set_process_metadata(logger)
    if otel, do: :otel_ctx.attach(otel)
  end

  @doc false
  def init_context(input, workflow_id) do
    Process.put(@context_key, %{})
    Process.put(@input_key, input)
    Process.put(@workflow_id_key, workflow_id)
    :ok
  end

  @doc false
  def restore_context(context_map, input, workflow_id) do
    # JSON turned atom keys into strings; turn back the ones the code knows.
    atomized_context = atomize_keys(context_map || %{})
    Process.put(@context_key, atomized_context)
    Process.put(@input_key, input)
    Process.put(@workflow_id_key, workflow_id)
    :ok
  end

  # Keys the code knows become atoms again (for context restored from database)
  # Only converts top-level keys, nested maps keep their original keys
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {known_key(key), value}
      {key, value} -> {key, value}
    end)
  end

  @doc false
  def set_current_step(step_name) do
    Process.put(@step_key, step_name)
    :ok
  end

  @doc false
  def set_attempt(attempt, max_attempts) do
    Process.put(@attempt_key, {attempt, max_attempts})
    :ok
  end

  @doc false
  def set_instance(name) do
    Process.put(@instance_key, name)
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
    Process.delete(@attempt_key)
    # Log capture keys (cleanup in case of crashes)
    Durable.LogCapture.clear_logs()
    Process.delete(:durable_original_group_leader)
    Process.delete(:durable_io_capture_pid)
    Durable.Telemetry.clear_log_metadata()
    :ok
  end

  # Helper functions

  # Normalize keys to atoms for consistency
  # (JSON encoding converts atoms to strings, so we normalize back)
  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: known_key(key)

  # The key as this context holds it. Data keeps its shape across a run, so a
  # key can be a string here though the code knows the atom, or the other way
  # round. A key that isn't there yet takes the normal form.
  defp stored_key(context, key) do
    normalized = normalize_key(key)
    other = if is_atom(normalized), do: Atom.to_string(normalized), else: key

    if Map.has_key?(context, normalized) or not Map.has_key?(context, other),
      do: normalized,
      else: other
  end

  # A map's keys as the context holds them, as put_context/2 would write each.
  # Merged raw, `count:` lands beside a stored "count", and the old one wins.
  defp as_stored(context, map), do: Map.new(map, fn {k, v} -> {stored_key(context, k), v} end)

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end
end
