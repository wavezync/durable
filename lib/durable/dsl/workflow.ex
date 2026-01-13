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

  alias Durable.Scheduler.DSL, as: SchedulerDSL

  @doc """
  Defines a workflow with the given name and options.
  """
  defmacro workflow(name, opts \\ [], do: block) do
    normalized_opts = normalize_workflow_opts(opts)

    # Generate unique function names for this workflow
    definition_fn = :"__workflow_def_#{name}__"
    steps_fn = :"__workflow_steps_#{name}__"
    compensations_fn = :"__workflow_compensations_#{name}__"

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
      # Store in module attribute for use in the steps function
      @durable_collected_steps_list Module.get_attribute(__MODULE__, :durable_current_steps)
                                    |> Enum.reverse()

      # Get collected compensations
      @durable_collected_comps_list Module.get_attribute(__MODULE__, :durable_compensations)

      # Define a function that returns the steps list
      # The steps contain function references like &Module.func/1 which are valid at runtime
      @doc false
      def unquote(steps_fn)() do
        @durable_collected_steps_list
      end

      # Define a function that returns the compensations map
      @doc false
      def unquote(compensations_fn)() do
        @durable_collected_comps_list
        |> Enum.reduce(%{}, fn comp, acc -> Map.put(acc, comp.name, comp) end)
      end

      # Define a function that returns this workflow's definition
      @doc false
      def unquote(definition_fn)() do
        %Durable.Definition.Workflow{
          name: unquote(name),
          module: __MODULE__,
          steps: unquote(steps_fn)(),
          compensations: unquote(compensations_fn)(),
          opts: unquote(Macro.escape(normalized_opts))
        }
      end

      # Register just the workflow name and function reference
      @durable_workflows {unquote(name), unquote(definition_fn)}

      # Capture any @schedule attribute for this workflow
      if Code.ensure_loaded?(Durable.Scheduler.DSL) do
        SchedulerDSL.capture_schedule(__MODULE__, unquote(name))
      end
    end
  end

  @doc false
  def normalize_workflow_opts(opts) do
    opts
    |> Keyword.take([:timeout, :max_retries, :queue])
    |> Enum.into(%{})
  end
end
