defmodule Durable.Migration.Migrations.V20261124000001AddNodeClockSkew do
  @moduledoc false
  # `nodes.clock_skew_ms` is how far each node's own clock is from the
  # database's, as it last measured (`Durable.Clock.skew_ms/0`): Durable reads
  # the database's, so this is for operators, whose other software on that node
  # may not. NULL until the node first beats on a version that measures it.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_124_000_001

  @impl true
  def up(prefix) do
    alter table(:nodes, prefix: prefix) do
      add_if_not_exists(:clock_skew_ms, :integer)
    end

    :ok
  end

  @impl true
  def down(prefix) do
    alter table(:nodes, prefix: prefix) do
      remove_if_exists(:clock_skew_ms, :integer)
    end

    :ok
  end
end
