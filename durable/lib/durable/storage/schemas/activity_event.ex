defmodule Durable.Storage.Schemas.ActivityEvent do
  @moduledoc """
  An operational event, recorded by `Durable.Activity`.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          at: DateTime.t(),
          kind: String.t(),
          node_id: String.t() | nil,
          queue: String.t() | nil,
          workflow_id: Ecto.UUID.t() | nil,
          count: pos_integer(),
          details: map()
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @schema_prefix "durable"
  schema "activity" do
    field(:at, :utc_datetime_usec)
    field(:kind, :string)
    field(:node_id, :string)
    field(:queue, :string)
    field(:workflow_id, :binary_id)
    field(:count, :integer, default: 1)
    field(:details, :map, default: %{})
  end
end
