defmodule Durable.DSL.Step do
  @moduledoc """
  Provides macros for defining workflow steps using a pure pipeline model.

  ## Pipeline Model

  Data flows from step to step. Each step receives the previous step's output
  and returns `{:ok, data}` or `{:error, reason}`.

  ## Usage

      workflow "process_order" do
        step :validate, fn order ->
          {:ok, %{order_id: order["id"], items: order["items"]}}
        end

        step :calculate, fn data ->
          total = data.items |> Enum.map(& &1["price"]) |> Enum.sum()
          {:ok, assign(data, :total, total)}
        end

        step :charge, [retry: [max_attempts: 3]], fn data ->
          {:ok, assign(data, :receipt, PaymentService.charge(data.total))}
        end
      end

  ## Options

  - `:retry` - Retry configuration
    - `:max_attempts` - Maximum retry attempts (default: 1)
    - `:backoff` - Backoff strategy: `:exponential`, `:linear`, `:constant`
    - `:base` - Base for backoff calculation (default: 2)
    - `:max_backoff` - Maximum backoff in ms (default: 3600000)
  - `:timeout` - Step timeout in milliseconds
  - `:compensate` - Name of compensation function for saga pattern
  - `:queue` - Override queue for this step

  """

  @doc """
  Defines a step within a workflow.

  The step receives the previous step's output (or workflow input for the first step)
  and must return `{:ok, data}` or `{:error, reason}`.

  ## Examples

      step :validate, fn order ->
        {:ok, %{order_id: order["id"], items: order["items"]}}
      end

      step :charge, [retry: [max_attempts: 3]], fn data ->
        {:ok, assign(data, :receipt, PaymentService.charge(data.total))}
      end

  """
  defmacro step(name, opts_or_fn, maybe_fn \\ nil)

  defmacro step(name, {:fn, _, _} = body_fn, nil) do
    # step :name, fn data -> ... end
    build_step(name, [], body_fn)
  end

  defmacro step(name, opts, {:fn, _, _} = body_fn) when is_list(opts) do
    # step :name, [opts], fn data -> ... end
    build_step(name, opts, body_fn)
  end

  defp build_step(name, opts, body_fn) do
    normalized_opts = normalize_step_opts(opts)
    # Generate a unique function name for this step's body
    func_name = :"__step_body_#{name}__"

    quote do
      # Define a named function for the step body
      @doc false
      def unquote(func_name)(data), do: unquote(body_fn).(data)

      @durable_current_steps %Durable.Definition.Step{
        name: unquote(name),
        type: :step,
        module: __MODULE__,
        body_fn: &(__MODULE__.unquote(func_name) / 1),
        opts: unquote(Macro.escape(normalized_opts))
      }
    end
  end

  @doc false
  def normalize_step_opts(opts) do
    opts
    |> Keyword.take([:retry, :timeout, :compensate, :queue])
    |> Enum.into(%{})
    |> normalize_retry_opts()
  end

  defp normalize_retry_opts(%{retry: retry} = opts) when is_list(retry) do
    normalized_retry =
      retry
      |> Keyword.take([:max_attempts, :backoff, :base, :max_backoff])
      |> Enum.into(%{})

    %{opts | retry: normalized_retry}
  end

  defp normalize_retry_opts(opts), do: opts

  @doc """
  Defines a decision step for conditional branching.

  Decision steps can return:
  - `{:ok, data}` - Continue to the next sequential step
  - `{:goto, :step_name, data}` - Jump to the named step

  ## Examples

      decision :check_amount, fn data ->
        if data.total > 1000 do
          {:goto, :manual_review, data}
        else
          {:ok, data}
        end
      end

  """
  defmacro decision(name, opts_or_fn, maybe_fn \\ nil)

  defmacro decision(name, {:fn, _, _} = body_fn, nil) do
    build_decision(name, [], body_fn)
  end

  defmacro decision(name, opts, {:fn, _, _} = body_fn) when is_list(opts) do
    build_decision(name, opts, body_fn)
  end

  defp build_decision(name, opts, body_fn) do
    normalized_opts = normalize_step_opts(opts)
    func_name = :"__decision_body_#{name}__"

    quote do
      @doc false
      def unquote(func_name)(data), do: unquote(body_fn).(data)

      @durable_current_steps %Durable.Definition.Step{
        name: unquote(name),
        type: :decision,
        module: __MODULE__,
        body_fn: &(__MODULE__.unquote(func_name) / 1),
        opts: unquote(Macro.escape(normalized_opts))
      }
    end
  end

  @doc """
  Defines a compensation handler for saga pattern.

  Compensations receive the current data and return `{:ok, data}`.

  ## Examples

      compensate :cancel_flight, fn data ->
        FlightAPI.cancel(data.flight_booking_id)
        {:ok, data}
      end

  """
  defmacro compensate(name, opts_or_fn, maybe_fn \\ nil)

  defmacro compensate(name, {:fn, _, _} = body_fn, nil) do
    build_compensate(name, [], body_fn)
  end

  defmacro compensate(name, opts, {:fn, _, _} = body_fn) when is_list(opts) do
    build_compensate(name, opts, body_fn)
  end

  defp build_compensate(name, opts, body_fn) do
    normalized_opts = normalize_compensate_opts(opts)
    func_name = :"__compensate_body_#{name}__"

    quote do
      @doc false
      def unquote(func_name)(data), do: unquote(body_fn).(data)

      @durable_compensations %Durable.Definition.Compensation{
        name: unquote(name),
        module: __MODULE__,
        body_fn: &(__MODULE__.unquote(func_name) / 1),
        opts: unquote(Macro.escape(normalized_opts))
      }
    end
  end

  @doc false
  def normalize_compensate_opts(opts) do
    opts
    |> Keyword.take([:retry, :timeout])
    |> Enum.into(%{})
    |> normalize_retry_opts()
  end

  # ============================================================================
  # Branch Macro
  # ============================================================================

  @doc """
  Defines a conditional branch within a workflow.

  The `:on` option takes a function that extracts the value to match.
  Only ONE branch executes based on the condition value.

  ## Examples

      branch on: fn data -> data.type end do
        "physical" ->
          step :ship, fn data -> {:ok, assign(data, :shipped, true)} end
        "digital" ->
          step :download, fn data -> {:ok, assign(data, :download_url, "...")} end
        _ ->
          step :manual, fn data -> {:ok, assign(data, :needs_review, true)} end
      end

  """
  defmacro branch(opts, do: block) do
    condition_fn = Keyword.fetch!(opts, :on)
    clauses = extract_clauses(block)

    branch_id = :erlang.unique_integer([:positive])

    {clause_data, all_step_defs} = process_branch_clauses(clauses, branch_id)

    branch_clauses =
      Enum.map(clause_data, fn {pattern, idx, step_names, _step_defs} ->
        {{pattern_to_key(pattern), idx}, step_names}
      end)
      |> Map.new()

    all_step_names = Enum.flat_map(all_step_defs, fn {name, _, _} -> [name] end)

    # Generate named functions for each nested step
    step_registrations =
      Enum.map(all_step_defs, fn {qualified_name, body_fn, step_opts} ->
        func_name = :"__step_body_#{qualified_name}__"

        quote do
          @doc false
          def unquote(func_name)(data), do: unquote(body_fn).(data)

          @durable_current_steps %Durable.Definition.Step{
            name: unquote(qualified_name),
            type: :step,
            module: __MODULE__,
            body_fn: &(__MODULE__.unquote(func_name) / 1),
            opts: unquote(Macro.escape(step_opts))
          }
        end
      end)

    # Generate named function for branch condition
    condition_func_name = :"__branch_condition_#{branch_id}__"

    quote do
      # Named function for branch condition
      @doc false
      def unquote(condition_func_name)(data), do: unquote(condition_fn).(data)

      @durable_current_steps %Durable.Definition.Step{
        name: unquote(:"branch_#{branch_id}"),
        type: :branch,
        module: __MODULE__,
        body_fn: &(__MODULE__.unquote(condition_func_name) / 1),
        opts: %{
          clauses: unquote(Macro.escape(branch_clauses)),
          all_steps: unquote(all_step_names)
        }
      }

      unquote_splicing(step_registrations)
    end
  end

  defp extract_clauses(block) do
    clauses =
      case block do
        {:__block__, _, items} -> items
        clauses when is_list(clauses) -> clauses
        clause -> [clause]
      end

    Enum.map(clauses, &parse_clause/1)
  end

  defp parse_clause({:->, _meta, [[pattern], body]}) do
    {pattern, body}
  end

  defp process_branch_clauses(clauses, branch_id) do
    {clause_data, all_steps} =
      clauses
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {{pattern, body}, idx}, acc_steps ->
        clause_name = pattern_to_clause_name(pattern)
        steps = extract_steps_from_body(body, branch_id, clause_name)
        step_names = Enum.map(steps, fn {name, _, _} -> name end)
        {{pattern, idx, step_names, steps}, steps ++ acc_steps}
      end)

    {clause_data, Enum.reverse(all_steps)}
  end

  defp extract_steps_from_body(body, branch_id, clause_name) do
    case body do
      {:__block__, _, statements} ->
        Enum.flat_map(statements, &extract_step_call(&1, branch_id, clause_name))

      statement ->
        extract_step_call(statement, branch_id, clause_name)
    end
  end

  # step :name, fn data -> ... end
  defp extract_step_call({:step, _meta, [name, {:fn, _, _} = body_fn]}, branch_id, clause_name)
       when is_atom(name) do
    qualified_name = :"branch_#{branch_id}__#{clause_name}__#{name}"

    step_opts = %{
      branch_id: branch_id,
      clause: clause_name,
      original_name: name
    }

    [{qualified_name, body_fn, step_opts}]
  end

  # step :name, [opts], fn data -> ... end
  defp extract_step_call(
         {:step, _meta, [name, opts, {:fn, _, _} = body_fn]},
         branch_id,
         clause_name
       )
       when is_atom(name) and is_list(opts) do
    qualified_name = :"branch_#{branch_id}__#{clause_name}__#{name}"

    step_opts =
      opts
      |> normalize_step_opts()
      |> Map.merge(%{
        branch_id: branch_id,
        clause: clause_name,
        original_name: name
      })

    [{qualified_name, body_fn, step_opts}]
  end

  defp extract_step_call(_other, _branch_id, _clause_name), do: []

  defp pattern_to_clause_name({:_, _, _}), do: :default
  defp pattern_to_clause_name(atom) when is_atom(atom), do: atom
  defp pattern_to_clause_name(true), do: true
  defp pattern_to_clause_name(false), do: false
  defp pattern_to_clause_name(string) when is_binary(string), do: String.to_atom(string)
  defp pattern_to_clause_name(int) when is_integer(int), do: :"val_#{int}"
  defp pattern_to_clause_name(_), do: :match

  defp pattern_to_key({:_, _, _}), do: :default
  defp pattern_to_key(atom) when is_atom(atom), do: atom
  defp pattern_to_key(string) when is_binary(string), do: string
  defp pattern_to_key(int) when is_integer(int), do: int
  defp pattern_to_key(_), do: :match

  # ============================================================================
  # Parallel Macro
  # ============================================================================

  @doc """
  Defines a parallel execution block.

  All steps inside execute concurrently. Each step receives a copy of the data.
  Results are merged according to the merge strategy.

  ## Options

  - `:merge` - Context merge strategy (default: `:deep_merge`)
    - `:deep_merge` - Deep merge all step outputs
    - `:last_wins` - Last step's output wins on conflicts
    - `:collect` - Collect into `%{step_name => output}`
  - `:on_error` - Error handling (default: `:fail_fast`)
    - `:fail_fast` - Cancel siblings on first failure
    - `:complete_all` - Wait for all, collect errors

  ## Examples

      parallel merge: :deep_merge do
        step :send_email, fn data ->
          EmailService.send(data.order_id)
          {:ok, assign(data, :email_sent, true)}
        end

        step :update_inventory, fn data ->
          InventoryService.decrement(data.items)
          {:ok, assign(data, :inventory_updated, true)}
        end
      end

  """
  defmacro parallel(opts \\ [], do: block) do
    parallel_id = :erlang.unique_integer([:positive])

    step_defs = extract_parallel_steps(block, parallel_id)
    step_names = Enum.map(step_defs, fn {name, _, _} -> name end)

    merge_strategy = Keyword.get(opts, :merge, :deep_merge)
    error_strategy = Keyword.get(opts, :on_error, :fail_fast)

    # Generate named functions for each parallel step
    step_registrations =
      Enum.map(step_defs, fn {qualified_name, body_fn, step_opts} ->
        func_name = :"__step_body_#{qualified_name}__"

        quote do
          @doc false
          def unquote(func_name)(data), do: unquote(body_fn).(data)

          @durable_current_steps %Durable.Definition.Step{
            name: unquote(qualified_name),
            type: :step,
            module: __MODULE__,
            body_fn: &(__MODULE__.unquote(func_name) / 1),
            opts: unquote(Macro.escape(step_opts))
          }
        end
      end)

    quote do
      @durable_current_steps %Durable.Definition.Step{
        name: unquote(:"parallel_#{parallel_id}"),
        type: :parallel,
        module: __MODULE__,
        opts: %{
          steps: unquote(step_names),
          all_steps: unquote(step_names),
          merge_strategy: unquote(merge_strategy),
          error_strategy: unquote(error_strategy)
        }
      }

      unquote_splicing(step_registrations)
    end
  end

  defp extract_parallel_steps(body, parallel_id) do
    case body do
      {:__block__, _, statements} ->
        Enum.flat_map(statements, &extract_parallel_step_call(&1, parallel_id))

      statement ->
        extract_parallel_step_call(statement, parallel_id)
    end
  end

  # step :name, fn data -> ... end
  defp extract_parallel_step_call({:step, _meta, [name, {:fn, _, _} = body_fn]}, parallel_id)
       when is_atom(name) do
    qualified_name = :"parallel_#{parallel_id}__#{name}"

    step_opts = %{
      parallel_id: parallel_id,
      original_name: name
    }

    [{qualified_name, body_fn, step_opts}]
  end

  # step :name, [opts], fn data -> ... end
  defp extract_parallel_step_call(
         {:step, _meta, [name, opts, {:fn, _, _} = body_fn]},
         parallel_id
       )
       when is_atom(name) and is_list(opts) do
    qualified_name = :"parallel_#{parallel_id}__#{name}"

    step_opts =
      opts
      |> normalize_step_opts()
      |> Map.merge(%{
        parallel_id: parallel_id,
        original_name: name
      })

    [{qualified_name, body_fn, step_opts}]
  end

  defp extract_parallel_step_call(_other, _parallel_id), do: []

  # ============================================================================
  # ForEach Macro
  # ============================================================================

  @doc """
  Defines a foreach block that iterates over a collection.

  The `:items` option takes a function that extracts items from the data.
  Steps inside receive 3 arguments: `(data, item, index)`.

  ## Options

  - `:items` - Required. Function that extracts items from data.
  - `:concurrency` - Items to process concurrently (default: 1)
  - `:on_error` - Error handling (default: `:fail_fast`)
  - `:collect_as` - Context key to store results

  ## Examples

      foreach :process_items,
        items: fn data -> data.items end do

        step :process_item, fn data, item, idx ->
          processed = %{name: item["name"], position: idx}
          {:ok, append(data, :processed_items, processed)}
        end
      end

  """
  defmacro foreach(name, opts, do: block) when is_atom(name) do
    foreach_id = :erlang.unique_integer([:positive])

    items_fn =
      Keyword.get(opts, :items) ||
        raise ArgumentError, "foreach requires :items option with a function"

    # Validate items is a function
    case items_fn do
      {:fn, _, _} ->
        :ok

      other ->
        raise ArgumentError,
              "foreach :items must be a function, got: #{inspect(other)}"
    end

    concurrency = Keyword.get(opts, :concurrency, 1)
    on_error = Keyword.get(opts, :on_error, :fail_fast)
    collect_as = Keyword.get(opts, :collect_as)

    step_defs = extract_foreach_steps(block, foreach_id, name)
    step_names = Enum.map(step_defs, fn {step_name, _, _} -> step_name end)

    # Generate named functions for each foreach step (3-arity: data, item, index)
    step_registrations =
      Enum.map(step_defs, fn {qualified_name, body_fn, step_opts} ->
        func_name = :"__step_body_#{qualified_name}__"

        quote do
          @doc false
          def unquote(func_name)(data, item, index), do: unquote(body_fn).(data, item, index)

          @durable_current_steps %Durable.Definition.Step{
            name: unquote(qualified_name),
            type: :step,
            module: __MODULE__,
            body_fn: &(__MODULE__.unquote(func_name) / 3),
            opts: unquote(Macro.escape(step_opts))
          }
        end
      end)

    # Generate named function for items extractor
    items_func_name = :"__foreach_items_#{name}__"

    quote do
      # Named function for items extraction
      @doc false
      def unquote(items_func_name)(data), do: unquote(items_fn).(data)

      @durable_current_steps %Durable.Definition.Step{
        name: unquote(:"foreach_#{name}"),
        type: :foreach,
        module: __MODULE__,
        body_fn: &(__MODULE__.unquote(items_func_name) / 1),
        opts: %{
          foreach_id: unquote(foreach_id),
          foreach_name: unquote(name),
          concurrency: unquote(concurrency),
          on_error: unquote(on_error),
          collect_as: unquote(collect_as),
          steps: unquote(step_names),
          all_steps: unquote(step_names)
        }
      }

      unquote_splicing(step_registrations)
    end
  end

  defp extract_foreach_steps(body, foreach_id, foreach_name) do
    case body do
      {:__block__, _, statements} ->
        Enum.flat_map(statements, &extract_foreach_step_call(&1, foreach_id, foreach_name))

      statement ->
        extract_foreach_step_call(statement, foreach_id, foreach_name)
    end
  end

  # step :name, fn data, item, idx -> ... end
  defp extract_foreach_step_call(
         {:step, _meta, [name, {:fn, _, _} = body_fn]},
         foreach_id,
         foreach_name
       )
       when is_atom(name) do
    qualified_name = :"foreach_#{foreach_name}__#{name}"

    step_opts = %{
      foreach_id: foreach_id,
      foreach_name: foreach_name,
      original_name: name
    }

    [{qualified_name, body_fn, step_opts}]
  end

  # step :name, [opts], fn data, item, idx -> ... end
  defp extract_foreach_step_call(
         {:step, _meta, [name, opts, {:fn, _, _} = body_fn]},
         foreach_id,
         foreach_name
       )
       when is_atom(name) and is_list(opts) do
    qualified_name = :"foreach_#{foreach_name}__#{name}"

    step_opts =
      opts
      |> normalize_step_opts()
      |> Map.merge(%{
        foreach_id: foreach_id,
        foreach_name: foreach_name,
        original_name: name
      })

    [{qualified_name, body_fn, step_opts}]
  end

  defp extract_foreach_step_call(_other, _foreach_id, _foreach_name), do: []
end
