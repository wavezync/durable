defmodule Durable.Storage.Schemas.Queue do
  @moduledoc """
  Cluster-wide queue state. A row exists only once a queue has been paused or
  resumed; a queue with no row is active. Every node's claim query checks
  `paused_at`, so pausing here stops the queue on all nodes at once.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{
          name: String.t(),
          paused_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:name, :string, autogenerate: false}
  @schema_prefix "durable"
  schema "queues" do
    field(:paused_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
