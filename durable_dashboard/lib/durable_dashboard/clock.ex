defmodule DurableDashboard.Clock do
  @moduledoc false
  # The time by Durable's clock, the database's, which wrote the times the
  # dashboard shows: "2m ago" and "overdue" then mean the same on every node.
  # A Durable without `Durable.Clock` (before this one) has only this node's.
  #
  # ponytail: drop the fallback once the dashboard requires a Durable with
  # `Durable.Clock`. The capture keeps a build against an older one quiet.

  @spec utc_now() :: DateTime.t()
  def utc_now do
    if Code.ensure_loaded?(Durable.Clock),
      do: Function.capture(Durable.Clock, :utc_now, 0).(),
      else: DateTime.utc_now()
  end
end
