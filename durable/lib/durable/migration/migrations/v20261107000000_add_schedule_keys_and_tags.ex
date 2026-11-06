defmodule Durable.Migration.Migrations.V20261107000000AddScheduleKeysAndTags do
  @moduledoc false
  # * `scheduled_workflows.key` — the workflow key a schedule's runs start
  #   with, so a fire while the last run is still going follows the
  #   workflow's `on_duplicate:` instead of starting a second copy.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_261_107_000_000

  @impl true
  def up(prefix) do
    alter table(:scheduled_workflows, prefix: prefix) do
      add_if_not_exists(:key, :text)
    end

    :ok
  end

  @impl true
  def down(prefix) do
    alter table(:scheduled_workflows, prefix: prefix) do
      remove_if_exists(:key, :text)
    end

    :ok
  end
end
