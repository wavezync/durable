defmodule PhoenixDemo.Repo.Migrations.UpgradeDurable do
  @moduledoc """
  Pulls in any new Durable library migrations.

  `Durable.Migration.up/1` tracks its own applied-versions table inside the
  `durable` schema, so calling it again is idempotent — only migrations that
  haven't been applied yet will run.

  As of 2026-04-13 this picks up `V20260413000000AddSchedulerResilience`,
  which adds the `last_error`, `last_error_at`, `consecutive_failures`, and
  `auto_disabled_at` columns on `scheduled_workflows` (audit fix L-1).
  """
  use Ecto.Migration

  def up, do: Durable.Migration.up()
  def down, do: Durable.Migration.down()
end
