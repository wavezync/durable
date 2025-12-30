defmodule Durable.Storage.Schemas.PendingInput do
  @moduledoc """
  Ecto schema for pending input records.

  Pending inputs represent human-in-the-loop interactions where a workflow
  is waiting for user input before continuing.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type input_type :: :form | :single_choice | :multi_choice | :free_text | :approval

  @type status :: :pending | :completed | :timeout | :cancelled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          input_name: String.t(),
          step_name: String.t(),
          input_type: input_type(),
          prompt: String.t() | nil,
          schema: map() | nil,
          fields: list(map()) | nil,
          status: status(),
          response: map() | nil,
          timeout_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "pending_inputs" do
    field :input_name, :string
    field :step_name, :string
    field :input_type, Ecto.Enum, values: [:form, :single_choice, :multi_choice, :free_text, :approval], default: :free_text
    field :prompt, :string
    field :schema, :map
    field :fields, {:array, :map}
    field :status, Ecto.Enum, values: [:pending, :completed, :timeout, :cancelled], default: :pending
    field :response, :map
    field :timeout_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :workflow, Durable.Storage.Schemas.WorkflowExecution, foreign_key: :workflow_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:workflow_id, :input_name, :step_name]
  @optional_fields [
    :input_type,
    :prompt,
    :schema,
    :fields,
    :status,
    :response,
    :timeout_at,
    :completed_at
  ]

  @doc """
  Creates a changeset for inserting a new pending input.
  """
  def changeset(pending_input, attrs) do
    pending_input
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:workflow_id)
  end

  @doc """
  Creates a changeset for completing a pending input with response.
  """
  def complete_changeset(pending_input, response) do
    pending_input
    |> cast(%{
      status: :completed,
      response: response,
      completed_at: DateTime.utc_now()
    }, [:status, :response, :completed_at])
  end

  @doc """
  Creates a changeset for timing out a pending input.
  """
  def timeout_changeset(pending_input) do
    pending_input
    |> cast(%{status: :timeout, completed_at: DateTime.utc_now()}, [:status, :completed_at])
  end

  @doc """
  Creates a changeset for cancelling a pending input.
  """
  def cancel_changeset(pending_input) do
    pending_input
    |> cast(%{status: :cancelled, completed_at: DateTime.utc_now()}, [:status, :completed_at])
  end
end
