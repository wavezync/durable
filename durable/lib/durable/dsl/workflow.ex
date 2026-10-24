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

  - `:timeout` - How long a run may take, in milliseconds, from when it is due
    to start — waits and sleeps included. A run past it fails with a
    `"timeout"` error, running compensations like any failure: a step still
    running is stopped (and not retried), and a waiting run is woken to fail.
    Steps in a run with a timeout run in their own process; see the step
    `:timeout` option.
  - `:queue` - The queue runs start on unless `Durable.start/3` names one

  """

  alias Durable.Scheduler.DSL, as: SchedulerDSL

  @doc """
  Defines a workflow with the given name and options.
  """
  defmacro workflow(name, opts \\ [], do: block) do
    validate_workflow_opts!(opts, name)

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
          # Evaluated here, in the workflow module, so `timeout: hours(2)` is
          # a number rather than the quoted call.
          opts: Map.new(unquote(opts))
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

  @workflow_opts [:timeout, :queue]

  defp validate_workflow_opts!(opts, name) when is_list(opts) do
    case Keyword.keys(opts) -- @workflow_opts do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option(s) #{inspect(unknown)} for workflow #{inspect(name)}; " <>
                "supported: #{inspect(@workflow_opts)}"
    end
  end

  defp validate_workflow_opts!(_opts, _name), do: :ok
end
