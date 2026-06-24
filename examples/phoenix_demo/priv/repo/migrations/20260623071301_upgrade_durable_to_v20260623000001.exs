defmodule PhoenixDemo.Repo.Migrations.UpgradeDurableToV20260623000001 do
  use Ecto.Migration

  def up do
    Durable.Migration.up(to: 20260623000001, prefix: "durable")
  end

  def down do
    Durable.Migration.down(to: 20260623000000, prefix: "durable")
  end
end
