defmodule Durable.Storage.Schemas.StepExecution do
  @moduledoc """
  Ecto schema for step execution records.

  Each step execution represents a single execution attempt of a workflow step,
  tracking its status, timing, and captured logs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :pending | :running | :completed | :failed | :waiting

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          step_name: String.t(),
          step_type: String.t(),
          attempt: integer(),
          status: status(),
          input: map() | nil,
          output: map() | nil,
          error: map() | nil,
          logs: list(map()),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          duration_ms: integer() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "step_executions" do
    field :step_name, :string
    field :step_type, :string, default: "step"
    field :attempt, :integer, default: 1
    field :status, Ecto.Enum, values: [:pending, :running, :completed, :failed, :waiting], default: :pending
    field :input, :map
    field :output, :map
    field :error, :map
    field :logs, {:array, :map}, default: []
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer

    belongs_to :workflow, Durable.Storage.Schemas.WorkflowExecution, foreign_key: :workflow_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:workflow_id, :step_name]
  @optional_fields [
    :step_type,
    :attempt,
    :status,
    :input,
    :output,
    :error,
    :logs,
    :started_at,
    :completed_at,
    :duration_ms
  ]

  @doc """
  Creates a changeset for inserting a new step execution.
  """
  def changeset(step_execution, attrs) do
    step_execution
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:workflow_id)
  end

  @doc """
  Creates a changeset for starting step execution.
  """
  def start_changeset(step_execution) do
    step_execution
    |> cast(%{status: :running, started_at: DateTime.utc_now()}, [:status, :started_at])
  end

  @doc """
  Creates a changeset for completing step execution.
  """
  def complete_changeset(step_execution, output, logs, duration_ms) do
    step_execution
    |> cast(%{
      status: :completed,
      output: output,
      logs: logs,
      completed_at: DateTime.utc_now(),
      duration_ms: duration_ms
    }, [:status, :output, :logs, :completed_at, :duration_ms])
  end

  @doc """
  Creates a changeset for failing step execution.
  """
  def fail_changeset(step_execution, error, logs, duration_ms) do
    step_execution
    |> cast(%{
      status: :failed,
      error: error,
      logs: logs,
      completed_at: DateTime.utc_now(),
      duration_ms: duration_ms
    }, [:status, :error, :logs, :completed_at, :duration_ms])
  end

  @doc """
  Appends logs to an existing step execution.
  """
  def append_logs_changeset(step_execution, new_logs) do
    current_logs = step_execution.logs || []
    step_execution
    |> cast(%{logs: current_logs ++ new_logs}, [:logs])
  end
end
