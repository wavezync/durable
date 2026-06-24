defmodule Durable.Storage.Schemas.WaitGroup do
  @moduledoc """
  Ecto schema for wait group records.

  Wait groups track multiple events for wait_for_any and wait_for_all patterns.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @type wait_type :: :any | :all

  @type status :: :pending | :completed | :timeout | :cancelled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          step_name: String.t(),
          wait_type: wait_type(),
          event_names: [String.t()],
          received_events: map(),
          status: status(),
          timeout_at: DateTime.t() | nil,
          timeout_value: term() | nil,
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
  schema "wait_groups" do
    field(:step_name, :string)

    field(:wait_type, Ecto.Enum,
      values: [:any, :all],
      default: :any
    )

    field(:event_names, {:array, :string})
    field(:received_events, :map, default: %{})

    field(:status, Ecto.Enum,
      values: [:pending, :completed, :timeout, :cancelled],
      default: :pending
    )

    field(:timeout_at, :utc_datetime_usec)
    field(:timeout_value, :map)

    # For parallel/foreach context
    field(:parallel_id, :integer)
    field(:foreach_id, :integer)
    field(:foreach_index, :integer)

    field(:completed_at, :utc_datetime_usec)

    belongs_to(:workflow, Durable.Storage.Schemas.WorkflowExecution, foreign_key: :workflow_id)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:workflow_id, :step_name, :wait_type, :event_names]
  @optional_fields [
    :received_events,
    :status,
    :timeout_at,
    :timeout_value,
    :parallel_id,
    :foreach_id,
    :foreach_index,
    :completed_at
  ]

  @doc """
  Creates a changeset for inserting a new wait group.
  """
  def changeset(wait_group, attrs) do
    wait_group
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:event_names, min: 1)
    |> foreign_key_constraint(:workflow_id)
  end

  @doc """
  Creates a changeset for adding a received event to the group.
  """
  def add_event_changeset(wait_group, event_name, payload) do
    updated_events = Map.put(wait_group.received_events || %{}, event_name, payload)

    # Check if completed based on wait_type
    all_received = MapSet.new(Map.keys(updated_events))
    required = MapSet.new(wait_group.event_names)

    is_complete =
      case wait_group.wait_type do
        :any -> MapSet.size(all_received) >= 1
        :all -> MapSet.subset?(required, all_received)
      end

    changes =
      if is_complete do
        %{
          received_events: updated_events,
          status: :completed,
          completed_at: DateTime.utc_now()
        }
      else
        %{received_events: updated_events}
      end

    wait_group
    |> cast(changes, [:received_events, :status, :completed_at])
  end

  @doc """
  Locks the wait group row `FOR UPDATE`, merges the event into
  `received_events`, and (when the wait condition is satisfied) flips
  `status` to `:completed`. Must be called inside a transaction.

  Returns `{:ok, %{wait_group: updated, just_completed: boolean}}` on
  success — `just_completed` is true iff this call transitioned the
  group from `:pending` to `:completed`. Already-completed/timed-out
  groups are treated as a no-op (`just_completed: false`) so late
  arrivals don't double-resume the parent.

  Without the row lock, two concurrent callers can read the same
  `received_events`, each merge in only their own event, and have the
  later UPDATE silently overwrite the earlier one — leaving the group
  permanently short an entry and the parent stuck in `:waiting`.
  """
  def add_event_locked(repo, wait_group_id, event_name, payload) do
    query =
      from(w in __MODULE__,
        where: w.id == ^wait_group_id,
        lock: "FOR UPDATE"
      )

    case repo.one(query) do
      nil ->
        {:error, :not_found}

      %__MODULE__{status: :pending} = wait_group ->
        with {:ok, updated} <-
               wait_group
               |> add_event_changeset(event_name, payload)
               |> repo.update() do
          {:ok, %{wait_group: updated, just_completed: updated.status == :completed}}
        end

      %__MODULE__{} = wait_group ->
        {:ok, %{wait_group: wait_group, just_completed: false}}
    end
  end

  @doc """
  Creates a changeset for timing out a wait group.
  """
  def timeout_changeset(wait_group) do
    wait_group
    |> cast(%{status: :timeout, completed_at: DateTime.utc_now()}, [:status, :completed_at])
  end

  @doc """
  Creates a changeset for cancelling a wait group.
  """
  def cancel_changeset(wait_group) do
    wait_group
    |> cast(%{status: :cancelled, completed_at: DateTime.utc_now()}, [:status, :completed_at])
  end
end
