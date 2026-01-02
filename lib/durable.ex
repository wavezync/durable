defmodule Durable do
  @moduledoc """
  A durable, resumable workflow engine for Elixir.

  Durable provides a clean DSL for defining workflows with built-in support for:

  - **Resumability**: Sleep, wait for events, wait for human input
  - **Reliability**: Automatic retries with configurable backoff strategies
  - **Observability**: Built-in log capture and graph visualization
  - **Composability**: Decision steps, loops, parallel execution, and more

  ## Installation

  Add Durable to your supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            MyApp.Repo,
            {Durable, repo: MyApp.Repo}
          ]

          opts = [strategy: :one_for_one, name: MyApp.Supervisor]
          Supervisor.start_link(children, opts)
        end
      end

  Create a migration for Durable tables:

      defmodule MyApp.Repo.Migrations.AddDurable do
        use Ecto.Migration

        def up, do: Durable.Migration.up()
        def down, do: Durable.Migration.down()
      end

  ## Quick Start

  Define a workflow using the DSL:

      defmodule MyApp.OrderWorkflow do
        use Durable
        use Durable.Context

        workflow "process_order", timeout: hours(2) do
          step :validate do
            order = input().order
            put_context(:order_id, order.id)
          end

          step :charge, retry: [max_attempts: 3, backoff: :exponential] do
            PaymentService.charge(get_context(:order_id))
          end
        end
      end

  Start a workflow:

      {:ok, workflow_id} = Durable.start(MyApp.OrderWorkflow, %{order: order})

  Query execution status:

      {:ok, execution} = Durable.get_execution(workflow_id)

  ## Configuration Options

  * `:repo` - The Ecto repo module (required)
  * `:name` - Instance name for multiple Durable instances (default: `Durable`)
  * `:prefix` - PostgreSQL schema name (default: `"durable"`)
  * `:queues` - Queue configuration map
  * `:queue_enabled` - Enable/disable queue processing (default: `true`)

  See `Durable.Config` for the complete list of options.

  """

  @doc """
  Injects the Durable DSL into the calling module.

  ## Usage

      defmodule MyApp.OrderWorkflow do
        use Durable

        workflow "process_order" do
          step :validate do
            # ...
          end
        end
      end

  """
  defmacro __using__(_opts) do
    quote do
      import Durable.DSL.Workflow
      import Durable.DSL.Step
      import Durable.DSL.TimeHelpers

      Module.register_attribute(__MODULE__, :durable_workflows, accumulate: true)

      @before_compile Durable
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    workflows = Module.get_attribute(env.module, :durable_workflows) || []
    workflow_names = Enum.map(workflows, fn {name, _def} -> name end)

    # Generate a function clause for each workflow
    workflow_clauses =
      Enum.map(workflows, fn {name, definition} ->
        quote do
          def __workflow_definition__(unquote(name)) do
            {:ok, unquote(Macro.escape(definition, unquote: true))}
          end
        end
      end)

    # Add fallback clause
    fallback_clause =
      quote do
        def __workflow_definition__(_name), do: {:error, :not_found}
      end

    # Generate default workflow function
    default_workflow =
      case workflows do
        [{_name, definition} | _] ->
          quote do
            def __default_workflow__ do
              {:ok, unquote(Macro.escape(definition, unquote: true))}
            end
          end

        [] ->
          quote do
            def __default_workflow__, do: {:error, :no_workflows}
          end
      end

    quote do
      @doc """
      Returns a list of workflow names defined in this module.
      """
      @spec __workflows__() :: [String.t()]
      def __workflows__, do: unquote(workflow_names)

      @doc """
      Returns the workflow definition for the given workflow name.
      """
      @spec __workflow_definition__(String.t()) ::
              {:ok, Durable.Definition.Workflow.t()} | {:error, :not_found}
      unquote_splicing(workflow_clauses)
      unquote(fallback_clause)

      @doc """
      Returns the default workflow definition (first defined workflow).
      """
      @spec __default_workflow__() ::
              {:ok, Durable.Definition.Workflow.t()} | {:error, :no_workflows}
      unquote(default_workflow)
    end
  end

  # Public API

  @doc """
  Starts a new workflow execution.

  ## Arguments

  - `module` - The workflow module
  - `input` - Initial input data for the workflow
  - `opts` - Options (optional)

  ## Options

  - `:workflow` - The workflow name (defaults to the first workflow in the module)
  - `:queue` - The queue to run the workflow on (default: `:default`)
  - `:priority` - Priority level (higher = more important, default: `0`)
  - `:scheduled_at` - Schedule execution for a future time

  ## Examples

      {:ok, workflow_id} = Durable.start(OrderWorkflow, %{order_id: 123})

      {:ok, workflow_id} = Durable.start(
        OrderWorkflow,
        %{order_id: 123},
        workflow: "process_order",
        queue: :high_priority
      )

  """
  @spec start(module(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(module, input, opts \\ []) do
    Durable.Executor.start_workflow(module, input, opts)
  end

  @doc """
  Gets the execution details for a workflow.

  ## Options

  - `:include_steps` - Include step execution details (default: `false`)
  - `:include_logs` - Include logs for each step (default: `false`)

  ## Examples

      {:ok, execution} = Durable.get_execution(workflow_id)

  """
  @spec get_execution(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_execution(workflow_id, opts \\ []) do
    Durable.Query.get_execution(workflow_id, opts)
  end

  @doc """
  Lists workflow executions with optional filters.

  ## Filters

  - `:workflow` - Filter by workflow module
  - `:status` - Filter by status
  - `:queue` - Filter by queue
  - `:limit` - Maximum number of results (default: `50`)

  ## Examples

      executions = Durable.list_executions(status: :running, limit: 100)

  """
  @spec list_executions(keyword()) :: [map()]
  def list_executions(filters \\ []) do
    Durable.Query.list_executions(filters)
  end

  @doc """
  Cancels a running or pending workflow.

  ## Examples

      :ok = Durable.cancel(workflow_id)
      :ok = Durable.cancel(workflow_id, "User requested cancellation")

  """
  @spec cancel(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def cancel(workflow_id, reason \\ nil) do
    Durable.Executor.cancel_workflow(workflow_id, reason)
  end

  @doc """
  Provides input for a waiting workflow (human-in-the-loop).

  ## Examples

      :ok = Durable.provide_input(workflow_id, "approval", %{approved: true})

  """
  @spec provide_input(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def provide_input(workflow_id, input_name, data) do
    Durable.Wait.provide_input(workflow_id, input_name, data)
  end

  @doc """
  Sends an event to a waiting workflow.

  ## Examples

      :ok = Durable.send_event(workflow_id, "payment_confirmed", %{amount: 99.99})

  """
  @spec send_event(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def send_event(workflow_id, event_name, payload) do
    Durable.Wait.send_event(workflow_id, event_name, payload)
  end

  # Supervision tree integration

  @doc """
  Starts a Durable instance.

  This function is used when adding Durable to your supervision tree.

  ## Options

  * `:repo` - The Ecto repo module (required)
  * `:name` - Instance name (default: `Durable`)
  * `:prefix` - Database schema prefix (default: `"durable"`)
  * `:queues` - Queue configuration

  See `Durable.Config` for the complete list of options.

  ## Examples

      # In your application supervisor
      children = [
        MyApp.Repo,
        {Durable, repo: MyApp.Repo}
      ]

      # With custom queues
      {Durable,
       repo: MyApp.Repo,
       queues: %{
         default: [concurrency: 10],
         high_priority: [concurrency: 20]
       }}

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Durable.Supervisor.start_link(opts)
  end

  @doc """
  Returns a child specification for Durable.

  This allows Durable to be used in supervision trees with the
  `{Durable, opts}` syntax.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end
end
