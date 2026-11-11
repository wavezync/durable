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
        use Durable.Helpers

        workflow "process_order", timeout: hours(2) do
          step :validate, fn order ->
            {:ok, %{order_id: order["id"], items: order["items"]}}
          end

          step :charge, [retry: [max_attempts: 3, backoff: :exponential]], fn data ->
            receipt = PaymentService.charge(data.order_id)
            {:ok, assign(data, :receipt, receipt)}
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
  * `:queues` - Queue configuration map
  * `:queue_enabled` - Enable/disable queue processing (default: `true`)

  See `Durable.Config` for the complete list of options.

  """

  @doc """
  Injects the Durable DSL into the calling module.

  ## Usage

      defmodule MyApp.OrderWorkflow do
        use Durable
        use Durable.Helpers

        workflow "process_order" do
          step :validate, fn data ->
            {:ok, %{order_id: data["id"]}}
          end
        end
      end

  """

  alias Durable.Config
  alias Durable.Queue.Control, as: QueueControl
  alias Durable.Queue.Drainer
  alias Durable.Scheduler.API, as: SchedulerAPI

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
    workflow_names = Enum.map(workflows, fn {name, _def_fn} -> name end)

    # Generate a function clause for each workflow
    # Each workflow registers {name, definition_fn} where definition_fn is a function
    # that returns the workflow definition. We call that function at runtime.
    workflow_clauses =
      Enum.map(workflows, fn {name, definition_fn} ->
        quote do
          def __workflow_definition__(unquote(name)) do
            {:ok, unquote(definition_fn)()}
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
        [{_name, definition_fn} | _] ->
          quote do
            def __default_workflow__ do
              {:ok, unquote(definition_fn)()}
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
  - `:key` - A workflow key, such as `"article:42"`: at most one run of this
    workflow holds a key at a time, so starting it again returns that run
    instead of creating another. A string of 1 to 255 bytes. Whether a key
    can be used again after its run finishes is the workflow's `reuse:`
    option. See the Workflow keys guide.
  - `:tags` - Labels for the run, such as `["account:7"]`, to find runs across
    workflows with `list_executions(tag: ...)` and stop them with
    `cancel_all/2`. Child runs don't inherit them; cancelling a run cancels
    its children anyway
  - `:on_duplicate` - What to do when the key is taken (the default is the
    workflow's, else `:use_existing`):
    - `:use_existing` - return `{:ok, holder_id}`
    - `:error` - return `{:error, {:key_taken, holder_id}}`
    - `:cancel_existing` - cancel the running holder and start a new run with
      this input, returning `{:ok, new_id}`
    - `:run_again` - leave one run waiting behind the running holder, with the
      newest input, returning `{:ok, waiting_id}`. It runs once the holder
      ends, if `reuse:` lets the key go
    - `{:send_event, name}` - send this input to the running holder as event
      `name` (kept until it waits for it) and return `{:ok, holder_id}`

    Only `:cancel_existing` and `:run_again` create a run; nothing is
    broadcast or run inline for the others. A finished holder that the workflow's `reuse:`
    keeps answers `:cancel_existing` and `{:send_event, name}` with
    `{:error, {:key_taken, holder_id}}`.
  - `:return` - `:details` makes a success `{:ok, %{id: id, created: boolean}}`,
    so a caller can tell a new run from a duplicate (default: `:id`)

  ## Returns

  - `{:ok, workflow_id}` for a new run, or the holder's id for a duplicate
    under `on_duplicate: :use_existing`
  - `{:error, {:key_taken, holder_id}}` for a duplicate under
    `on_duplicate: :error`
  - `{:error, %Ecto.Changeset{}}` for an invalid key, and
    `{:error, :key_contended}` in the rare case the key changed hands three
    times while this start ran
  - `{:error, :invalid_input}` for input that isn't a map

  Raises `ArgumentError` for a `:key`, `:tags` or `:queue` that PostgreSQL can't
  store, such as text with a NUL character.

  ## Examples

      {:ok, workflow_id} = Durable.start(OrderWorkflow, %{order_id: 123})

      # The same article twice: one run
      {:ok, id} = Durable.start(ProcessArticle, %{"id" => 42}, key: "article:42")
      {:ok, ^id} = Durable.start(ProcessArticle, %{"id" => 42}, key: "article:42")

      {:ok, workflow_id} = Durable.start(
        OrderWorkflow,
        %{order_id: 123},
        workflow: "process_order",
        queue: :high_priority
      )

  """
  @spec start(module(), map(), keyword()) ::
          {:ok, String.t() | %{id: String.t(), created: boolean()}} | {:error, term()}
  def start(module, input, opts \\ []) do
    Durable.Executor.start_workflow(module, input, opts)
  end

  @doc """
  Starts several runs at once: one `{module, input}` or `{module, input, opts}`
  per run, with `opts` (the options of `start/3`) applying to every item under
  the item's own.

  All the starts share one transaction, the caller's if it is in one, so they
  commit together. Keys are checked for every item, as `start/3` checks them,
  and each item gets its own result, in order. Two batches can name the same keys
  in any order. If the batch's locks can't be taken, nothing is started and
  every item gets `{:error, reason}`.

  ## Examples

      Durable.start_many([
        {ImportRow, %{"row" => 1}, key: "import:9:row:1"},
        {ImportRow, %{"row" => 2}, key: "import:9:row:2"}
      ], tags: ["import:9"])
      #=> [{:ok, id1}, {:ok, id2}]

  """
  @spec start_many([{module(), map()} | {module(), map(), keyword()}], keyword()) ::
          [{:ok, String.t() | map()} | {:error, term()}]
  def start_many(items, opts \\ []) do
    Durable.Executor.start_many(items, opts)
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
  - `:status` - Filter by status, or a list of statuses
  - `:queue` - Filter by queue
  - `:key` - Runs started with this workflow key
  - `:tag` - Runs started with this tag, across workflows
  - `:limit` - Maximum number of results (default: `50`)

  `Durable.Query.list_executions/1` lists every filter.

  ## Examples

      executions = Durable.list_executions(status: :running, limit: 100)

  """
  @spec list_executions(keyword()) :: [map()]
  def list_executions(filters \\ []) do
    Durable.Query.list_executions(filters)
  end

  @doc """
  Cancels a pending, running or waiting workflow, and its child workflows.

  The cancel is final: once it returns `:ok` the run stays `:cancelled` and no
  later step runs. A step in flight is stopped at the worker's next heartbeat
  (`:heartbeat_interval`, 30 s by default), killed like any process. To stop
  cleanly before that, a step can check `Durable.Context.cancelled?/0` between
  chunks of work. Cancelling does not run compensations.

  Returns `{:error, :already_completed}` if the run has already finished, and
  `{:error, :not_found}` for an unknown id.

  ## Examples

      :ok = Durable.cancel(workflow_id)
      :ok = Durable.cancel(workflow_id, "User requested cancellation")

  """
  @spec cancel(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def cancel(workflow_id, reason \\ nil) do
    Durable.Executor.cancel_workflow(workflow_id, reason)
  end

  @doc """
  Cancels every pending, running or waiting run that matches `filters`, the
  filters of `list_executions/1`, one by one as `cancel/2` would (children
  included). Returns `{:ok, count}`. At least one filter is required, and one
  that wouldn't narrow the runs (a misspelt name, a `nil`) raises rather than
  cancel everything else.

  ## Examples

      # An account was closed: stop everything started for it
      {:ok, 3} = Durable.cancel_all([tag: "account:7"], "account closed")

      {:ok, _} = Durable.cancel_all([workflow: MyApp.Export, status: :waiting])

  """
  @spec cancel_all(keyword(), String.t() | nil) :: {:ok, non_neg_integer()}
  def cancel_all(filters, reason \\ nil) do
    Durable.Executor.cancel_all(filters, reason)
  end

  @doc """
  Resumes a failed workflow at the step that failed.

  Steps that already completed are not re-run, and the failed step gets its
  full retry budget again. Inside a parallel block only the children that
  failed are re-queued.

  Returns `{:error, :rolled_back}` for runs whose compensations ran — use
  `rerun/2` for those — and `{:error, :not_failed}` for runs that aren't failed.

  A keyed run whose key moved to a newer run takes it back by the same rules
  as a start (the newer run is finished and the workflow's `reuse:` lets it
  go), or returns `{:error, {:key_taken, holder_id}}`.

  ## Options

  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      {:ok, ^workflow_id} = Durable.retry(workflow_id)

  """
  @spec retry(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def retry(workflow_id, opts \\ []) do
    Durable.Executor.retry_workflow(workflow_id, opts)
  end

  @doc """
  Starts a fresh run of a finished workflow, with its original input or a new
  one. The new run's `trigger` is `:rerun` and its `trigger_ref` is the
  original run's id.

  A keyed run's rerun keeps its key and follows the start rules, returning
  `{:error, {:key_taken, holder_id}}` when the key is held. Under
  `reuse: :never`, `release_key/2` first.

  ## Options

  - `:input` - Input for the new run (default: the original run's input)
  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      {:ok, new_id} = Durable.rerun(workflow_id)
      {:ok, new_id} = Durable.rerun(workflow_id, input: %{"order_id" => "ORD-1043"})

  """
  @spec rerun(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def rerun(workflow_id, opts \\ []) do
    Durable.Executor.rerun_workflow(workflow_id, opts)
  end

  @doc """
  Lets a finished run's workflow key go, so the next start with that key
  creates a new run even if the workflow's `reuse:` would refuse it — for
  processing an item again on purpose. The run keeps its history and its
  `key`; only `holds_key` changes.

  Recorded in `Durable.Activity` as `"key_released"`.

  Returns `{:error, :not_finished}` for a run that's still going (cancel it
  first), `{:error, :no_key}` for a run that doesn't hold a key, and
  `{:error, :not_found}` for an unknown id.

  ## Options

  - `:durable` - The Durable instance name (default: Durable)
  - `:by` - who released it, kept with the activity record

  ## Examples

      :ok = Durable.release_key(workflow_id, by: "ops@example.com")

  """
  @spec release_key(String.t(), keyword()) :: :ok | {:error, term()}
  def release_key(workflow_id, opts \\ []) do
    Durable.Keys.release(workflow_id, opts)
  end

  @doc """
  Pauses a queue on every node. Runs already executing finish; no node claims
  new work from the queue until `resume_queue/2`. The pause survives restarts.

  Recorded in `Durable.Activity` as `"queue_paused"`.

  ## Options

  - `:durable` - The Durable instance name (default: Durable)
  - `:by` - who paused it, kept with the activity record
  """
  @spec pause_queue(atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def pause_queue(queue, opts \\ []) do
    QueueControl.pause(Config.get(Keyword.get(opts, :durable, Durable)), queue, opts)
  end

  @doc """
  Resumes a queue paused with `pause_queue/2`, on every node.
  """
  @spec resume_queue(atom() | String.t(), keyword()) :: :ok | {:error, term()}
  def resume_queue(queue, opts \\ []) do
    QueueControl.resume(Config.get(Keyword.get(opts, :durable, Durable)), queue, opts)
  end

  @doc """
  Returns the names of queues currently paused with `pause_queue/2`.
  """
  @spec paused_queues(keyword()) :: [String.t()]
  def paused_queues(opts \\ []) do
    QueueControl.paused(Config.get(Keyword.get(opts, :durable, Durable)))
  end

  @doc """
  Lists the Durable nodes that have heartbeated recently, newest first. Each
  has `:id`, `:queues`, `:version`, `:started_at`, `:heartbeat_at`, a
  `:status` of `:alive` or `:missing` (no heartbeat for 30 s), and `:running`,
  the number of runs it is executing.
  """
  @spec list_nodes(keyword()) :: [map()]
  def list_nodes(opts \\ []) do
    Durable.NodeRegistry.list(Config.get(Keyword.get(opts, :durable, Durable)))
  end

  @doc """
  Stops this node taking new work and waits for what it's running.

  A node does this by itself when it stops. Call it to start earlier, such as
  from a Kubernetes `preStop` hook. Running runs finish their current step and
  go back on their queues for another node. The node doesn't claim again until
  it restarts, and other nodes aren't affected.

  Returns `:ok`, or `{:error, :timeout}` if work was still running when the time
  ran out. That work keeps going.

  ## Options

  - `:durable` - The Durable instance name (default: Durable)
  - `:timeout` - Milliseconds to wait (default: the `:shutdown_grace_period`)
  """
  @spec drain(keyword()) :: :ok | {:error, :timeout}
  def drain(opts \\ []) do
    config = Config.get(Keyword.get(opts, :durable, Durable))
    Drainer.drain(config, Keyword.get(opts, :timeout, config.shutdown_grace_period))
  end

  @doc """
  Deletes finished runs past the `:prune` retention now, instead of waiting
  for the hourly sweep. Returns the number deleted per group, or `%{}` when
  `:prune` isn't configured.
  """
  @spec prune(keyword()) :: %{atom() => non_neg_integer()}
  def prune(opts \\ []) do
    Durable.Pruner.prune(Config.get(Keyword.get(opts, :durable, Durable)))
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

  Returns `{:error, :not_found}` when the run isn't waiting for the event,
  unless `buffer: true` keeps it until the run reaches
  `wait_for_event(event_name)`.

  ## Options

  - `:buffer` - Keep the event for a run that isn't waiting for it yet
    (default: `false`). A run gets one event per name: if several were kept,
    it gets the newest.
  - `:durable` - The Durable instance name (default: Durable)

  ## Examples

      :ok = Durable.send_event(workflow_id, "payment_confirmed", %{amount: 99.99})
      :ok = Durable.send_event(workflow_id, "article_updated", %{rev: 7}, buffer: true)

  """
  @spec send_event(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def send_event(workflow_id, event_name, payload, opts \\ []) do
    Durable.Wait.send_event(workflow_id, event_name, payload, opts)
  end

  @doc """
  Lists child workflow executions for a parent workflow.

  ## Options

  - `:status` - Filter by status

  ## Examples

      children = Durable.list_children(parent_workflow_id)
      running_children = Durable.list_children(parent_workflow_id, status: :running)

  """
  @spec list_children(String.t(), keyword()) :: [map()]
  def list_children(parent_workflow_id, opts \\ []) do
    Durable.Query.list_child_executions(parent_workflow_id, opts)
  end

  # Scheduling API

  @doc """
  Creates a new scheduled workflow.

  ## Arguments

  - `module` - The workflow module
  - `cron_expression` - Cron expression (e.g., "0 9 * * *" for 9am daily)
  - `opts` - Options

  ## Options

  - `:name` - Schedule name (defaults to workflow name)
  - `:workflow` - Workflow name (defaults to first workflow in module)
  - `:input` - Input data for each execution
  - `:timezone` - Timezone for cron (default: "UTC")
  - `:queue` - Queue to run on (default: :default)
  - `:enabled` - Whether schedule is active (default: true)
  - `:durable` - Durable instance name (default: Durable)

  ## Examples

      {:ok, schedule} = Durable.schedule(MyApp.DailyReport, "0 9 * * *")

      {:ok, schedule} = Durable.schedule(
        MyApp.Reports,
        "0 9 * * MON-FRI",
        name: "weekday_report",
        workflow: "generate_report",
        timezone: "America/New_York"
      )

  """
  @spec schedule(module(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def schedule(module, cron_expression, opts \\ []) do
    SchedulerAPI.schedule(module, cron_expression, opts)
  end

  @doc """
  Lists scheduled workflows.

  ## Filters

  - `:enabled` - Filter by enabled status
  - `:workflow_module` - Filter by module
  - `:queue` - Filter by queue
  - `:limit` - Maximum results (default: 100)
  - `:durable` - Durable instance name

  ## Examples

      schedules = Durable.list_schedules(enabled: true)

  """
  @spec list_schedules(keyword()) :: [term()]
  def list_schedules(filters \\ []) do
    SchedulerAPI.list_schedules(filters)
  end

  @doc """
  Gets a scheduled workflow by name.

  ## Examples

      {:ok, schedule} = Durable.get_schedule("daily_report")

  """
  @spec get_schedule(String.t(), keyword()) :: {:ok, term()} | {:error, :not_found}
  def get_schedule(name, opts \\ []) do
    SchedulerAPI.get_schedule(name, opts)
  end

  @doc """
  Updates a scheduled workflow.

  ## Updatable Fields

  - `:cron_expression` - New cron expression
  - `:timezone` - New timezone
  - `:input` - New input data
  - `:queue` - New queue
  - `:enabled` - Enable/disable

  ## Examples

      {:ok, schedule} = Durable.update_schedule("daily_report", cron_expression: "0 10 * * *")

  """
  @spec update_schedule(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def update_schedule(name, changes) do
    SchedulerAPI.update_schedule(name, changes)
  end

  @doc """
  Deletes a scheduled workflow.

  ## Examples

      :ok = Durable.delete_schedule("daily_report")

  """
  @spec delete_schedule(String.t(), keyword()) :: :ok | {:error, :not_found}
  def delete_schedule(name, opts \\ []) do
    SchedulerAPI.delete_schedule(name, opts)
  end

  @doc """
  Enables a scheduled workflow.

  ## Examples

      {:ok, schedule} = Durable.enable_schedule("daily_report")

  """
  @spec enable_schedule(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def enable_schedule(name, opts \\ []) do
    SchedulerAPI.enable_schedule(name, opts)
  end

  @doc """
  Disables a scheduled workflow.

  ## Examples

      {:ok, schedule} = Durable.disable_schedule("daily_report")

  """
  @spec disable_schedule(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def disable_schedule(name, opts \\ []) do
    SchedulerAPI.disable_schedule(name, opts)
  end

  @doc """
  Triggers a scheduled workflow immediately.

  This starts a new workflow execution without waiting for the next scheduled time.

  ## Options

  - `:input` - Override the schedule's input
  - `:durable` - Durable instance name

  ## Examples

      {:ok, workflow_id} = Durable.trigger_schedule("daily_report")

  """
  @spec trigger_schedule(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def trigger_schedule(name, opts \\ []) do
    SchedulerAPI.trigger_schedule(name, opts)
  end

  # Supervision tree integration

  @doc """
  Starts a Durable instance.

  This function is used when adding Durable to your supervision tree.

  ## Options

  * `:repo` - The Ecto repo module (required)
  * `:name` - Instance name (default: `Durable`)
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
