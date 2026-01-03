defmodule Durable.DSL.Workflow do
  @moduledoc """
  Provides the `workflow` macro for defining durable workflows.

  ## Usage

      defmodule MyApp.OrderWorkflow do
        use Durable

        workflow "process_order", timeout: hours(2) do
          step :validate do
            # ...
          end

          step :charge do
            # ...
          end
        end
      end

  ## Options

  - `:timeout` - Maximum workflow duration in milliseconds
  - `:max_retries` - Maximum retry attempts for the entire workflow
  - `:queue` - Default queue for this workflow

  """

  @doc """
  Defines a workflow with the given name and options.
  """
  defmacro workflow(name, opts \\ [], do: block) do
    normalized_opts = normalize_workflow_opts(opts)

    quote do
      # Reset current steps accumulator
      Module.delete_attribute(__MODULE__, :durable_current_steps)
      Module.register_attribute(__MODULE__, :durable_current_steps, accumulate: true)

      # Reset compensations accumulator
      Module.delete_attribute(__MODULE__, :durable_compensations)
      Module.register_attribute(__MODULE__, :durable_compensations, accumulate: true)

      # Execute the block to collect steps and compensations
      unquote(block)

      # Get collected steps (in reverse order due to accumulation)
      steps = Module.get_attribute(__MODULE__, :durable_current_steps) |> Enum.reverse()

      # Get collected compensations and build map
      compensations =
        __MODULE__
        |> Module.get_attribute(:durable_compensations)
        |> Enum.reduce(%{}, fn comp, acc -> Map.put(acc, comp.name, comp) end)

      # Build workflow definition
      workflow_def = %Durable.Definition.Workflow{
        name: unquote(name),
        module: __MODULE__,
        steps: steps,
        compensations: compensations,
        opts: unquote(Macro.escape(normalized_opts))
      }

      # Register the workflow
      @durable_workflows {unquote(name), workflow_def}
    end
  end

  @doc false
  def normalize_workflow_opts(opts) do
    opts
    |> Keyword.take([:timeout, :max_retries, :queue])
    |> Enum.into(%{})
  end
end
