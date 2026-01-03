defmodule Durable.DSL.Step do
  @moduledoc """
  Provides the `step` macro for defining workflow steps.

  ## Usage

      workflow "process_order" do
        step :validate do
          # Step implementation
        end

        step :charge, retry: [max_attempts: 3, backoff: :exponential] do
          # Step with retry
        end

        step :notify, timeout: minutes(5) do
          # Step with timeout
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

  When used inside a `branch` block, the step is automatically qualified
  with the branch and clause information to ensure unique naming.
  """
  defmacro step(name, opts \\ [], do: body) do
    normalized_opts = normalize_step_opts(opts)

    quote do
      @doc false
      def unquote(:"__step_body__#{name}")(_ctx) do
        unquote(body)
      end

      # Register the step definition
      @durable_current_steps %Durable.Definition.Step{
        name: unquote(name),
        type: :step,
        module: __MODULE__,
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
  Defines a decision step for conditional branching within a workflow.

  Decision steps evaluate conditions and determine which step to execute next.
  They can return:
  - `{:goto, :step_name}` - Jump forward to the named step, skipping intermediate steps
  - `{:continue}` - Continue to the next sequential step
  - Any other value - Treated as `{:continue}` with the value stored as output

  ## Examples

      workflow "order_processing" do
        step :validate do
          put_context(:amount, input().amount)
        end

        decision :check_amount do
          if get_context(:amount) > 1000 do
            {:goto, :manager_approval}
          else
            {:goto, :auto_approve}
          end
        end

        step :auto_approve do
          put_context(:approved_by, "system")
        end

        step :manager_approval do
          put_context(:approved_by, "manager")
        end
      end

  ## Options

  Decision steps support the same options as regular steps:
  - `:retry` - Retry configuration for the decision logic
  - `:timeout` - Decision timeout in milliseconds

  ## Constraints

  - Target steps must exist in the workflow
  - Jumps must be forward-only (cannot jump to earlier steps)
  - Jumping to self is not allowed
  """
  defmacro decision(name, opts \\ [], do: body) do
    normalized_opts = normalize_step_opts(opts)

    quote do
      @doc false
      def unquote(:"__step_body__#{name}")(_ctx) do
        unquote(body)
      end

      @durable_current_steps %Durable.Definition.Step{
        name: unquote(name),
        type: :decision,
        module: __MODULE__,
        opts: unquote(Macro.escape(normalized_opts))
      }
    end
  end

  @doc """
  Defines a compensation handler for saga pattern.

  Compensations are executed in reverse order when a workflow step fails
  and the workflow needs to undo previously completed steps.

  ## Examples

      workflow "book_trip" do
        step :book_flight, compensate: :cancel_flight do
          FlightAPI.book(get_context(:flight))
        end

        step :book_hotel, compensate: :cancel_hotel do
          HotelAPI.book(get_context(:hotel))
        end

        step :charge_payment do
          # If this fails, compensations run in reverse order:
          # cancel_hotel first, then cancel_flight
          PaymentService.charge(get_context(:total))
        end

        compensate :cancel_flight do
          FlightAPI.cancel(get_context(:flight_booking))
        end

        compensate :cancel_hotel do
          HotelAPI.cancel(get_context(:hotel_booking))
        end
      end

  ## Options

  - `:retry` - Retry configuration for the compensation
    - `:max_attempts` - Maximum retry attempts (default: 1)
    - `:backoff` - Backoff strategy: `:exponential`, `:linear`, `:constant`
  - `:timeout` - Compensation timeout in milliseconds

  """
  defmacro compensate(name, opts \\ [], do: body) do
    normalized_opts = normalize_compensate_opts(opts)

    quote do
      @doc false
      def unquote(:"__compensation_body__#{name}")(_ctx) do
        unquote(body)
      end

      @durable_compensations %Durable.Definition.Compensation{
        name: unquote(name),
        module: __MODULE__,
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

  @doc """
  Defines a conditional branch within a workflow.

  The `branch` macro provides intuitive conditional execution that reads
  top-to-bottom like normal code. Only ONE branch executes based on the
  condition value, then execution continues after the branch block.

  ## Examples

      workflow "process_order" do
        step :validate do
          put_context(:total, input()["total"])
        end

        branch on: get_context(:doc_type) do
          :invoice ->
            step :extract_invoice do
              AI.extract(doc(), schema: :invoice)
            end

            step :validate_invoice do
              validate_totals(get_context(:extracted))
            end

          :contract ->
            step :extract_contract do
              AI.extract(doc(), schema: :contract)
            end

          _ ->
            step :manual_review do
              wait_for_input("classification")
            end
        end

        step :store do
          # Runs after ANY branch completes
          save_result()
        end
      end

  ## Options

  - `:on` - (required) Expression to evaluate for branch selection

  ## Pattern Matching

  Supports simple pattern matching:
  - Literal values: `:invoice`, `"pdf"`, `1`
  - Default clause: `_`

  """
  defmacro branch(opts, do: block) do
    condition_expr = Keyword.fetch!(opts, :on)
    clauses = extract_clauses(block)

    # Generate a unique branch ID at macro expansion time
    branch_id = :erlang.unique_integer([:positive])

    # Process each clause - extract steps and generate qualified names
    {clause_data, all_step_defs} = process_branch_clauses(clauses, branch_id)

    # Build clauses map: {pattern_key, idx} => [step_names]
    branch_clauses =
      Enum.map(clause_data, fn {pattern, idx, step_names, _step_defs} ->
        {{pattern_to_key(pattern), idx}, step_names}
      end)
      |> Map.new()

    # All step names for skipping
    all_step_names = Enum.flat_map(all_step_defs, fn {name, _, _} -> [name] end)

    # Generate the condition function name
    condition_fn_name = :"__branch_condition__#{branch_id}"

    # Generate step function definitions and registrations
    step_code =
      Enum.map(all_step_defs, fn {qualified_name, body, opts} ->
        quote do
          @doc false
          def unquote(:"__step_body__#{qualified_name}")(_ctx) do
            unquote(body)
          end

          @durable_current_steps %Durable.Definition.Step{
            name: unquote(qualified_name),
            type: :step,
            module: __MODULE__,
            opts: unquote(Macro.escape(opts))
          }
        end
      end)

    quote do
      # Define the condition function
      @doc false
      def unquote(condition_fn_name)() do
        unquote(condition_expr)
      end

      # Create the branch step definition FIRST (before nested steps)
      # This ensures the branch control comes before its steps in the workflow
      @durable_current_steps %Durable.Definition.Step{
        name: unquote(:"branch_#{branch_id}"),
        type: :branch,
        module: __MODULE__,
        opts: %{
          condition_fn: unquote(condition_fn_name),
          clauses: unquote(Macro.escape(branch_clauses)),
          all_steps: unquote(all_step_names)
        }
      }

      # Include all nested step definitions AFTER the branch control
      unquote_splicing(step_code)
    end
  end

  # Extract clauses from the branch block AST
  defp extract_clauses(block) do
    clauses =
      case block do
        {:__block__, _, items} -> items
        # Already a list of clauses (multiple ->)
        clauses when is_list(clauses) -> clauses
        # Single clause
        clause -> [clause]
      end

    Enum.map(clauses, &parse_clause/1)
  end

  # Parse a single clause: pattern -> body
  defp parse_clause({:->, _meta, [[pattern], body]}) do
    {pattern, body}
  end

  # Process all clauses, extracting step definitions
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

  # Extract step calls from body AST
  defp extract_steps_from_body(body, branch_id, clause_name) do
    case body do
      {:__block__, _, statements} ->
        Enum.flat_map(statements, &extract_step_call(&1, branch_id, clause_name))

      statement ->
        extract_step_call(statement, branch_id, clause_name)
    end
  end

  # Extract a single step call
  defp extract_step_call({:step, _meta, [name | rest]}, branch_id, clause_name)
       when is_atom(name) do
    {opts, body} = parse_step_args(rest)
    qualified_name = :"branch_#{branch_id}__#{clause_name}__#{name}"

    step_opts =
      opts
      |> normalize_step_opts()
      |> Map.merge(%{
        branch_id: branch_id,
        clause: clause_name,
        original_name: name
      })

    [{qualified_name, body, step_opts}]
  end

  defp extract_step_call(_other, _branch_id, _clause_name), do: []

  # Parse step arguments (opts and body)
  defp parse_step_args([[do: body]]), do: {[], body}
  defp parse_step_args([opts, [do: body]]) when is_list(opts), do: {opts, body}
  defp parse_step_args(_), do: {[], nil}

  # Convert pattern to a clause name for qualified step names
  defp pattern_to_clause_name({:_, _, _}), do: :default
  defp pattern_to_clause_name(atom) when is_atom(atom), do: atom
  defp pattern_to_clause_name(true), do: true
  defp pattern_to_clause_name(false), do: false
  defp pattern_to_clause_name(string) when is_binary(string), do: String.to_atom(string)
  defp pattern_to_clause_name(int) when is_integer(int), do: :"val_#{int}"
  defp pattern_to_clause_name(_), do: :match

  # Convert pattern AST to a simple key for clause lookup
  defp pattern_to_key({:_, _, _}), do: :default
  defp pattern_to_key(atom) when is_atom(atom), do: atom
  defp pattern_to_key(string) when is_binary(string), do: string
  defp pattern_to_key(int) when is_integer(int), do: int
  defp pattern_to_key(_), do: :match

  @doc """
  Defines a parallel execution block within a workflow.

  All steps inside the parallel block execute concurrently.
  Execution continues after the block only when ALL parallel steps complete.

  ## Options

  - `:merge` - Context merge strategy (default: `:deep_merge`)
    - `:deep_merge` - Deep merge all step contexts
    - `:last_wins` - Last step's context wins on conflicts
    - `:collect` - Collect into `%{step_name => context_changes}`
  - `:on_error` - Error handling strategy (default: `:fail_fast`)
    - `:fail_fast` - Cancel siblings on first failure
    - `:complete_all` - Wait for all, collect errors

  ## Examples

      workflow "onboard_user" do
        step :create_user do
          put_context(:user_id, Users.create(input()))
        end

        parallel do
          step :send_welcome_email do
            Mailer.send_welcome(get_context(:user_id))
          end

          step :provision_workspace do
            Workspaces.create(get_context(:user_id))
          end

          step :setup_billing do
            Billing.setup(get_context(:user_id))
          end
        end

        step :complete do
          Logger.info("Onboarding complete")
        end
      end

  With options:

      parallel merge: :collect, on_error: :complete_all do
        step :task_a do ... end
        step :task_b do ... end
      end

  """
  defmacro parallel(opts \\ [], do: block) do
    parallel_id = :erlang.unique_integer([:positive])

    # Extract nested steps from block
    step_defs = extract_parallel_steps(block, parallel_id)
    step_names = Enum.map(step_defs, fn {name, _, _} -> name end)

    # Options with defaults
    merge_strategy = Keyword.get(opts, :merge, :deep_merge)
    error_strategy = Keyword.get(opts, :on_error, :fail_fast)

    # Generate step function definitions
    step_code =
      Enum.map(step_defs, fn {qualified_name, body, step_opts} ->
        quote do
          @doc false
          def unquote(:"__step_body__#{qualified_name}")(_ctx) do
            unquote(body)
          end

          @durable_current_steps %Durable.Definition.Step{
            name: unquote(qualified_name),
            type: :step,
            module: __MODULE__,
            opts: unquote(Macro.escape(step_opts))
          }
        end
      end)

    quote do
      # Register the parallel control step FIRST
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

      # Include all nested step definitions AFTER the parallel control
      unquote_splicing(step_code)
    end
  end

  # Extract step calls from parallel block body
  defp extract_parallel_steps(body, parallel_id) do
    case body do
      {:__block__, _, statements} ->
        Enum.flat_map(statements, &extract_parallel_step_call(&1, parallel_id))

      statement ->
        extract_parallel_step_call(statement, parallel_id)
    end
  end

  defp extract_parallel_step_call({:step, _meta, [name | rest]}, parallel_id)
       when is_atom(name) do
    {opts, body} = parse_step_args(rest)
    qualified_name = :"parallel_#{parallel_id}__#{name}"

    step_opts =
      opts
      |> normalize_step_opts()
      |> Map.merge(%{
        parallel_id: parallel_id,
        original_name: name
      })

    [{qualified_name, body, step_opts}]
  end

  defp extract_parallel_step_call(_other, _parallel_id), do: []

  # ============================================================================
  # ForEach Macro
  # ============================================================================

  @doc """
  Defines a foreach block that iterates over a collection.

  Each item in the collection is processed by the steps defined within the block.
  The current item is accessible via `current_item()` from `Durable.Context`.

  ## Options

  - `:items` - Required. Specifies where to get the collection. Can be:
    - An atom (context key): `items: :my_items` - reads from context
    - A `{module, function, args}` tuple: `items: {MyModule, :get_items, []}`
  - `:concurrency` - Optional. Number of items to process concurrently (default: 1).
    When set to 1, items are processed sequentially.
  - `:on_error` - Error handling strategy (default: `:fail_fast`)
    - `:fail_fast` - Stop processing on first error
    - `:continue` - Continue processing, collect errors
  - `:collect_as` - Optional. Context key to store results as a list

  ## Examples

  Sequential processing with context key:

      workflow "process_orders" do
        step :fetch_orders do
          put_context(:orders, Orders.fetch_pending())
        end

        foreach :process_each_order, items: :orders do
          step :process do
            order = current_item()
            result = Orders.process(order)
            append_context(:processed, result)
          end
        end

        step :notify do
          Logger.info("Processed \#{length(get_context(:processed))} orders")
        end
      end

  Concurrent processing with limit:

      foreach :process_items, items: :items, concurrency: 5 do
        step :process do
          item = current_item()
          # Process item
        end
      end

  With MFA tuple for dynamic item fetching:

      foreach :process_items,
        items: {MyModule, :get_pending_items, []},
        on_error: :continue do

        step :send do
          process(current_item())
        end
      end

  """
  defmacro foreach(name, opts, do: block) when is_atom(name) do
    foreach_id = :erlang.unique_integer([:positive])

    # items is required - can be an atom (context key) or {mod, fun, args} tuple
    items_spec =
      Keyword.get(opts, :items) ||
        raise ArgumentError, "foreach requires :items option"

    # Validate items_spec at compile time
    items_spec =
      case items_spec do
        key when is_atom(key) ->
          {:context_key, key}

        {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
          {:mfa, {mod, fun, args}}

        other ->
          raise ArgumentError,
                "foreach :items must be an atom (context key) or {module, function, args} tuple, got: #{inspect(other)}"
      end

    # Options with defaults
    concurrency = Keyword.get(opts, :concurrency, 1)
    on_error = Keyword.get(opts, :on_error, :fail_fast)
    collect_as = Keyword.get(opts, :collect_as)

    # Extract nested steps from block
    step_defs = extract_foreach_steps(block, foreach_id, name)
    step_names = Enum.map(step_defs, fn {step_name, _, _} -> step_name end)

    # Generate step function definitions
    step_code =
      Enum.map(step_defs, fn {qualified_name, body, step_opts} ->
        quote do
          @doc false
          def unquote(:"__step_body__#{qualified_name}")(_ctx) do
            unquote(body)
          end

          @durable_current_steps %Durable.Definition.Step{
            name: unquote(qualified_name),
            type: :step,
            module: __MODULE__,
            opts: unquote(Macro.escape(step_opts))
          }
        end
      end)

    quote do
      # Register the foreach control step
      @durable_current_steps %Durable.Definition.Step{
        name: unquote(:"foreach_#{name}"),
        type: :foreach,
        module: __MODULE__,
        opts: %{
          foreach_id: unquote(foreach_id),
          foreach_name: unquote(name),
          items_spec: unquote(Macro.escape(items_spec)),
          concurrency: unquote(concurrency),
          on_error: unquote(on_error),
          collect_as: unquote(collect_as),
          steps: unquote(step_names),
          all_steps: unquote(step_names)
        }
      }

      # Include all nested step definitions
      unquote_splicing(step_code)
    end
  end

  # Extract step calls from foreach block body
  defp extract_foreach_steps(body, foreach_id, foreach_name) do
    case body do
      {:__block__, _, statements} ->
        Enum.flat_map(statements, &extract_foreach_step_call(&1, foreach_id, foreach_name))

      statement ->
        extract_foreach_step_call(statement, foreach_id, foreach_name)
    end
  end

  defp extract_foreach_step_call({:step, _meta, [name | rest]}, foreach_id, foreach_name)
       when is_atom(name) do
    {opts, body} = parse_step_args(rest)
    qualified_name = :"foreach_#{foreach_name}__#{name}"

    step_opts =
      opts
      |> normalize_step_opts()
      |> Map.merge(%{
        foreach_id: foreach_id,
        foreach_name: foreach_name,
        original_name: name
      })

    [{qualified_name, body, step_opts}]
  end

  defp extract_foreach_step_call(_other, _foreach_id, _foreach_name), do: []
end
