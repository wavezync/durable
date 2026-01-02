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
end
