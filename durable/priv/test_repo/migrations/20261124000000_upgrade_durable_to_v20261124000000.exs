defmodule Durable.TestRepo.Migrations.UpgradeDurableToV20261124000000 do
  # What `mix durable.gen.upgrade` writes, as an app upgrading would have: an
  # existing test database gets Durable's migrations since the first. A fresh
  # one has them all from the first already.
  use Ecto.Migration

  def up do
    Durable.Migration.up(to: 20_261_124_000_000)
  end

  def down do
    Durable.Migration.down(to: 20_261_122_000_000)
  end
end
