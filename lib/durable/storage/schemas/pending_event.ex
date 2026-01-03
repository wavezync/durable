defmodule Durable.Storage.Schemas.PendingEvent do
  @moduledoc """
  Ecto schema for pending event records.

  Pending events represent external events that a workflow
  is waiting for before continuing execution.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type wait_type :: :single | :any | :all

  @type status :: :pending | :received | :timeout | :cancelled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          event_name: String.t(),
          step_name: String.t(),
          status: status(),
          payload: map() | nil,
          timeout_at: DateTime.t() | nil,
          timeout_value: term() | nil,
          wait_group_id: Ecto.UUID.t() | nil,
          wait_type: wait_type(),
          parallel_id: integer() | nil,
          foreach_id: integer() | nil,
          foreach_index: integer() | nil,
          completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @schema_prefix "durable"
  schema "pending_events" do
    field(:event_name, :string)
    field(:step_name, :string)

    field(:status, Ecto.Enum,
      values: [:pending, :received, :timeout, :cancelled],
      default: :pending
    )

    field(:payload, :map)
    field(:timeout_at, :utc_datetime_usec)
    field(:timeout_value, :map)

    # For wait_for_any / wait_for_all patterns
    field(:wait_group_id, :binary_id)

    field(:wait_type, Ecto.Enum,
      values: [:single, :any, :all],
      default: :single
    )

    # For parallel/foreach context
    field(:parallel_id, :integer)
    field(:foreach_id, :integer)
    field(:foreach_index, :integer)

    field(:completed_at, :utc_datetime_usec)

    belongs_to(:workflow, Durable.Storage.Schemas.WorkflowExecution, foreign_key: :workflow_id)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:workflow_id, :event_name, :step_name]
  @optional_fields [
    :status,
    :payload,
    :timeout_at,
    :timeout_value,
    :wait_group_id,
    :wait_type,
    :parallel_id,
    :foreach_id,
    :foreach_index,
    :completed_at
  ]

  @doc """
  Creates a changeset for inserting a new pending event.
  """
  def changeset(pending_event, attrs) do
    pending_event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:workflow_id)
  end

  @doc """
  Creates a changeset for receiving an event with payload.
  """
  def receive_changeset(pending_event, payload) do
    pending_event
    |> cast(
      %{
        status: :received,
        payload: payload,
        completed_at: DateTime.utc_now()
      },
      [:status, :payload, :completed_at]
    )
  end

  @doc """
  Creates a changeset for timing out a pending event.
  """
  def timeout_changeset(pending_event) do
    pending_event
    |> cast(%{status: :timeout, completed_at: DateTime.utc_now()}, [:status, :completed_at])
  end

  @doc """
  Creates a changeset for cancelling a pending event.
  """
  def cancel_changeset(pending_event) do
    pending_event
    |> cast(%{status: :cancelled, completed_at: DateTime.utc_now()}, [:status, :completed_at])
  end
end
