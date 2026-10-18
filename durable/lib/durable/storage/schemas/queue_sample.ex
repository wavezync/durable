defmodule Durable.Storage.Schemas.QueueSample do
  @moduledoc """
  A queue's depth at one minute, written by `Durable.Queue.Sampler`.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{
          queue: String.t(),
          at: DateTime.t(),
          ready: non_neg_integer(),
          scheduled: non_neg_integer(),
          running: non_neg_integer(),
          waiting: non_neg_integer()
        }

  @primary_key false
  @schema_prefix "durable"
  schema "queue_samples" do
    field(:queue, :string, primary_key: true)
    field(:at, :utc_datetime, primary_key: true)
    field(:ready, :integer, default: 0)
    field(:scheduled, :integer, default: 0)
    field(:running, :integer, default: 0)
    field(:waiting, :integer, default: 0)
  end
end
