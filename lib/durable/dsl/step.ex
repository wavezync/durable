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

  All steps inside execute concurrently. Each step receives a copy of the context.
  Results are collected into a `__results__` map with tagged tuples.

  ## Options

  - `:into` - Optional callback to transform results (default: none)
    - Receives `(ctx, results)` where results = `%{step_name => {:ok, data} | {:error, reason}}`
    - Returns `{:ok, ctx}` | `{:error, reason}` | `{:goto, step, ctx}`
  - `:on_error` - Error handling (default: `:fail_fast`)
    - `:fail_fast` - Cancel siblings on first failure
    - `:complete_all` - Wait for all, collect results

  ## Behavior

  Without `:into`, results go to `ctx.__results__` and the next step handles them:

      parallel do
        step :payment, fn ctx -> {:ok, %{id: 123}} end
        step :delivery, fn ctx -> {:error, :not_found} end
      end
      # Next step receives:
      # %{...ctx, __results__: %{payment: {:ok, %{id: 123}}, delivery: {:error, :not_found}}}

  With `:into`, you control what the next step receives:

      parallel into: fn ctx, results ->
        case {results.payment, results.delivery} do
          {{:ok, payment}, {:ok, _}} ->
            {:ok, Map.put(ctx, :payment_id, payment.id)}
          {{:ok, _}, {:error, :not_found}} ->
            {:goto, :handle_backorder, ctx}
          _ ->
            {:error, "Critical failure"}
        end
      end do
        step :payment, fn ctx -> {:ok, %{id: 123}} end
        step :delivery, fn ctx -> {:error, :not_found} end
      end

  ## Step Options

  - `:returns` - Key name for this step's result (default: step name)

      parallel do
        step :fetch_order, returns: :order do
          fn ctx -> {:ok, %{items: [...]}} end
        end
      end
      # Result: %{...ctx, __results__: %{order: {:ok, %{items: [...]}}}}

  """
  defmacro parallel(opts \\ [], do: block) do
    parallel_id = :erlang.unique_integer([:positive])

    step_defs = extract_parallel_steps(block, parallel_id)
    step_names = Enum.map(step_defs, fn {name, _, _} -> name end)

    error_strategy = Keyword.get(opts, :on_error, :fail_fast)
    into_fn = Keyword.get(opts, :into)

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

    # Generate named function for into callback if provided
    {into_fn_ref, into_fn_def} =
      if into_fn do
        into_func_name = :"__parallel_into_#{parallel_id}__"

        def_ast =
          quote do
            @doc false
            def unquote(into_func_name)(ctx, results), do: unquote(into_fn).(ctx, results)
          end

        ref_ast =
          quote do
            &(__MODULE__.unquote(into_func_name) / 2)
          end

        {ref_ast, def_ast}
      else
        {nil, nil}
      end

    quote do
      unquote(into_fn_def)

      @durable_current_steps %Durable.Definition.Step{
        name: unquote(:"parallel_#{parallel_id}"),
        type: :parallel,
        module: __MODULE__,
        opts: %{
          steps: unquote(step_names),
          all_steps: unquote(step_names),
          error_strategy: unquote(error_strategy),
          into_fn: unquote(into_fn_ref)
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
      original_name: name,
      returns: name
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

    # Extract returns option, default to original name
    returns_key = Keyword.get(opts, :returns, name)

    step_opts =
      opts
      |> normalize_parallel_step_opts()
      |> Map.merge(%{
        parallel_id: parallel_id,
        original_name: name,
        returns: returns_key
      })

    [{qualified_name, body_fn, step_opts}]
  end

  # step :name, returns: :key do fn data -> ... end end
  defp extract_parallel_step_call(
         {:step, _meta, [name, opts, [do: {:fn, _, _} = body_fn]]},
         parallel_id
       )
       when is_atom(name) and is_list(opts) do
    qualified_name = :"parallel_#{parallel_id}__#{name}"

    # Extract returns option, default to original name
    returns_key = Keyword.get(opts, :returns, name)

    step_opts =
      opts
      |> normalize_parallel_step_opts()
      |> Map.merge(%{
        parallel_id: parallel_id,
        original_name: name,
        returns: returns_key
      })

    [{qualified_name, body_fn, step_opts}]
  end

  defp extract_parallel_step_call(_other, _parallel_id), do: []

  # Normalize parallel step options (includes :returns)
  defp normalize_parallel_step_opts(opts) do
    opts
    |> Keyword.take([:retry, :timeout, :compensate, :queue, :returns])
    |> Enum.into(%{})
    |> normalize_retry_opts()
  end
end
