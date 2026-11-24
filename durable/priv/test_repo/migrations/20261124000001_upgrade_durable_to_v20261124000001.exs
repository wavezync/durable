defmodule Durable.TestRepo.Migrations.UpgradeDurableToV20261124000001 do
  # What `mix durable.gen.upgrade` writes. See the one before it.
  use Ecto.Migration

  def up do
    Durable.Migration.up(to: 20_261_124_000_001)
  end

  def down do
    Durable.Migration.down(to: 20_261_124_000_000)
  end
end
