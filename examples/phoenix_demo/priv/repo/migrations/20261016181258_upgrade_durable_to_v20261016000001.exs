defmodule PhoenixDemo.Repo.Migrations.UpgradeDurableToV20261016000001 do
  use Ecto.Migration

  def up do
    Durable.Migration.up(to: 20_261_016_000_001, prefix: "durable")
  end

  def down do
    Durable.Migration.down(to: 20_261_016_000_000, prefix: "durable")
  end
end
