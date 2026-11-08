defmodule Durable.Storage.Schemas.WorkflowExecution do
  @moduledoc """
  Ecto schema for workflow execution records.

  Each workflow execution represents a single run of a workflow, tracking its
  status, context, and progress through steps.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type status ::
          :pending
          | :running
          | :completed
          | :failed
          | :waiting
          | :cancelled
          | :compensating
          | :compensated
          | :compensation_failed

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          workflow_module: String.t(),
          workflow_name: String.t(),
          status: status(),
          queue: String.t(),
          priority: integer(),
          input: map(),
          context: map(),
          current_step: String.t() | nil,
          error: map() | nil,
          parent_workflow_id: Ecto.UUID.t() | nil,
          scheduled_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          locked_by: String.t() | nil,
          locked_at: DateTime.t() | nil,
          compensation_results: list(map()),
          compensated_at: DateTime.t() | nil,
          retried_at: DateTime.t() | nil,
          trigger: :api | :schedule | :parent | :rerun | nil,
          trigger_ref: String.t() | nil,
          key: String.t() | nil,
          holds_key: boolean(),
          tags: [String.t()],
          runs_after_id: Ecto.UUID.t() | nil,
          home_queue: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "durable"
  schema "workflow_executions" do
    field(:workflow_module, :string)
    field(:workflow_name, :string)

    field(:status, Ecto.Enum,
      values: [
        :pending,
        :running,
        :completed,
        :failed,
        :waiting,
        :cancelled,
        :compensating,
        :compensated,
        :compensation_failed
      ],
      default: :pending
    )

    field(:queue, :string, default: "default")
    field(:priority, :integer, default: 0)
    field(:input, :map, default: %{})
    field(:context, :map, default: %{})
    field(:current_step, :string)
    field(:error, :map)
    field(:parent_workflow_id, :binary_id)
    field(:scheduled_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:locked_by, :string)
    field(:locked_at, :utc_datetime_usec)
    # Per-claim fencing token (fresh UUID stamped on each claim). Lets a worker
    # detect its claim was superseded by stale-lock recovery + reclaim.
    field(:lock_token, :binary_id)

    # Compensation/Saga support
    field(:compensation_results, {:array, :map}, default: [])
    field(:compensated_at, :utc_datetime_usec)

    # Operator controls: when Durable.retry/2 last resumed this run (attempt
    # budgets count from here), and what started it.
    field(:retried_at, :utc_datetime_usec)
    field(:trigger, Ecto.Enum, values: [:api, :schedule, :parent, :rerun], default: :api)
    field(:trigger_ref, :string)

    # Set from the workflow's `timeout:` when the run is created; a run past it
    # fails with a "timeout" error before its next step.
    field(:deadline_at, :utc_datetime_usec)

    # Workflow key (`Durable.start(..., key: "article:42")`). Every keyed run
    # keeps its key; the one run per workflow and key that holds it has
    # `holds_key`. Status changes never write `holds_key` — see Durable.Keys.
    field(:key, :string)
    field(:holds_key, :boolean, default: false)
    field(:tags, {:array, :string}, default: [])
    # A run waiting for this run to end before it takes the key (run_again).
    field(:runs_after_id, :binary_id)
    # The queue to go back to while a step's `queue:` has the run elsewhere.
    # `queue` is always where the run is claimed now.
    field(:home_queue, :string)

    has_many(:step_executions, Durable.Storage.Schemas.StepExecution, foreign_key: :workflow_id)
    has_many(:pending_inputs, Durable.Storage.Schemas.PendingInput, foreign_key: :workflow_id)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:workflow_module, :workflow_name]
  @optional_fields [
    :status,
    :queue,
    :priority,
    :input,
    :context,
    :current_step,
    :error,
    :parent_workflow_id,
    :scheduled_at,
    :started_at,
    :completed_at,
    :locked_by,
    :locked_at,
    :compensation_results,
    :compensated_at,
    :trigger,
    :trigger_ref,
    :deadline_at,
    :key,
    :tags
  ]

  @open_statuses [:pending, :running, :waiting, :compensating]
  @closed_statuses [:completed, :failed, :cancelled, :compensated, :compensation_failed]

  # Which closed holders a new start may take a key from, per `reuse:` policy.
  # Open holders always keep their key.
  @reusable %{
    after_close: @closed_statuses,
    after_failure: @closed_statuses -- [:completed],
    never: []
  }

  @doc """
  Creates a changeset for inserting a new workflow execution.
  """
  def changeset(execution, attrs) do
    execution
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_key(attrs)
  end

  # `cast/3` turns "" into nil, which would silently start an unkeyed run.
  defp validate_key(changeset, %{key: ""}), do: add_error(changeset, :key, "can't be blank")

  defp validate_key(changeset, _attrs) do
    changeset
    |> validate_length(:key, min: 1, max: 255, count: :bytes)
    |> unique_constraint(:key, name: :workflow_executions_key_holder_index)
  end

  @doc "Statuses of a run that's still going: it always keeps its key."
  @spec open_statuses() :: [status()]
  def open_statuses, do: @open_statuses

  @doc "Statuses of a finished run."
  @spec closed_statuses() :: [status()]
  def closed_statuses, do: @closed_statuses

  @doc "The `reuse:` policies a workflow can declare."
  @spec reuse_policies() :: [atom()]
  def reuse_policies, do: Map.keys(@reusable)

  @doc """
  The statuses a key's holder can be in for a new start to take the key under
  `policy`. Open holders never give it up.
  """
  @spec reusable_statuses(atom()) :: [status()]
  def reusable_statuses(policy), do: Map.fetch!(@reusable, policy)

  @doc """
  Creates a changeset for updating workflow status.
  """
  def status_changeset(execution, status, attrs \\ %{}) do
    execution
    |> cast(Map.put(attrs, :status, status), [
      :status,
      :current_step,
      :error,
      :started_at,
      :completed_at,
      :context
    ])
  end

  @doc """
  Creates a changeset for locking a workflow for execution.
  """
  def lock_changeset(execution, locked_by) do
    execution
    |> cast(%{locked_by: locked_by, locked_at: DateTime.utc_now()}, [:locked_by, :locked_at])
  end

  @doc """
  Creates a changeset for unlocking a workflow.
  """
  def unlock_changeset(execution) do
    execution
    |> cast(%{locked_by: nil, locked_at: nil}, [:locked_by, :locked_at])
  end

  @doc """
  Creates a changeset for marking workflow as compensating.
  """
  def compensating_changeset(execution) do
    execution
    |> cast(%{status: :compensating}, [:status])
  end

  @doc """
  Creates a changeset for marking workflow as compensated (all compensations succeeded).
  """
  def compensated_changeset(execution, results) do
    now = DateTime.utc_now()

    # A rolled-back run is finished too: completed_at marks the end of every
    # terminal run, so durations and retention treat them alike.
    execution
    |> cast(
      %{
        status: :compensated,
        compensation_results: results,
        compensated_at: now,
        completed_at: now
      },
      [:status, :compensation_results, :compensated_at, :completed_at]
    )
  end

  @doc """
  Creates a changeset for marking workflow compensation as failed.
  """
  def compensation_failed_changeset(execution, results, error) do
    execution
    |> cast(
      %{
        status: :compensation_failed,
        compensation_results: results,
        error: error,
        compensated_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      },
      [:status, :compensation_results, :error, :compensated_at, :completed_at]
    )
  end
end
