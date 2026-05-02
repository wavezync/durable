defmodule Durable.TestRepo.Migrations.CreateDurableTables do
  use Ecto.Migration

  def up do
    Durable.Migration.up()
  end

  def down do
    Durable.Migration.down()
  end
end
