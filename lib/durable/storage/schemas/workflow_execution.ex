defmodule Durable.Storage.Schemas.WorkflowExecution do
  @moduledoc """
  Ecto schema for workflow execution records.

  Each workflow execution represents a single run of a workflow, tracking its
  status, context, and progress through steps.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :pending | :running | :completed | :failed | :waiting | :cancelled

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
      values: [:pending, :running, :completed, :failed, :waiting, :cancelled],
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
    :locked_at
  ]

  @doc """
  Creates a changeset for inserting a new workflow execution.
  """
  def changeset(execution, attrs) do
    execution
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end

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
end
