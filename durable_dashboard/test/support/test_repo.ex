defmodule DurableDashboard.TestRepo do
  @moduledoc "The Ecto repo the page tests run Durable on. Test-only."
  use Ecto.Repo, otp_app: :durable_dashboard, adapter: Ecto.Adapters.Postgres

  @doc """
  Creates the database if needed and brings Durable's schema up to date.
  The Ecto migration is keyed on Durable's latest version, so a new core
  migration runs on the next test run.
  """
  def setup! do
    _ = Ecto.Adapters.Postgres.storage_up(config())
    {:ok, _} = start_link()

    Ecto.Migrator.run(
      __MODULE__,
      [{Durable.Migration.Migrator.current_version(), DurableDashboard.TestRepo.Migration}],
      :up,
      all: true,
      log: false
    )

    :ok
  end

  defmodule Migration do
    @moduledoc false
    use Ecto.Migration
    def up, do: Durable.Migration.up()
    def down, do: Durable.Migration.down()
  end
end
