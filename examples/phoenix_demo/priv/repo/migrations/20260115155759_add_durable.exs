defmodule PhoenixDemo.Repo.Migrations.AddDurable do
  use Ecto.Migration

  def up, do: Durable.Migration.up()
  def down, do: Durable.Migration.down()
end
