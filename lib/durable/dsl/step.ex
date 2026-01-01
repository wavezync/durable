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
  """
  defmacro step(name, opts \\ [], do: body) do
    normalized_opts = normalize_step_opts(opts)

    quote do
      # Generate the step body function
      @doc false
      def unquote(:"__step_body__#{name}")(_ctx) do
        unquote(body)
      end

      # Register the step definition (without body - body is in the function above)
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
end
