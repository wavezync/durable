defmodule PhoenixDemo.Repo.Migrations.UpgradeDurableToV20261106000000 do
  use Ecto.Migration

  def up do
    Durable.Migration.up(to: 20261106000000, prefix: "durable")
  end

  def down do
    Durable.Migration.down(to: 20261016000001, prefix: "durable")
  end
end
