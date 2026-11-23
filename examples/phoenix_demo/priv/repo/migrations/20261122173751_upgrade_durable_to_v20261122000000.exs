defmodule PhoenixDemo.Repo.Migrations.UpgradeDurableToV20261122000000 do
  use Ecto.Migration

  def up do
    Durable.Migration.up(to: 20_261_122_000_000, prefix: "durable")
  end

  def down do
    Durable.Migration.down(to: 20_261_111_000_000, prefix: "durable")
  end
end
