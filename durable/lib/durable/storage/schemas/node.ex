defmodule Durable.Storage.Schemas.Node do
  @moduledoc """
  One row per running Durable instance, refreshed by `Durable.NodeRegistry`.
  The id is the instance's node id, which pollers also stamp into
  `workflow_executions.locked_by`.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{
          id: String.t(),
          queues: [String.t()],
          version: String.t() | nil,
          started_at: DateTime.t(),
          heartbeat_at: DateTime.t(),
          clock_skew_ms: integer() | nil
        }

  @primary_key {:id, :string, autogenerate: false}
  @schema_prefix "durable"
  schema "nodes" do
    field(:queues, {:array, :string}, default: [])
    field(:version, :string)
    field(:started_at, :utc_datetime_usec)
    field(:heartbeat_at, :utc_datetime_usec)
    # How far the node's own clock is ahead of the database's (behind if
    # negative), as it last measured. Durable itself reads the database's.
    field(:clock_skew_ms, :integer)
  end
end
