defmodule Durable.Migration.Migrations.V20260623000000AddLockFencing do
  @moduledoc false
  # Adds a per-claim fencing token to workflow_executions.
  #
  # Without it, a worker whose heartbeat stalls past `stale_lock_timeout` can be
  # fenced out by stale-lock recovery: recovery releases the row, another worker
  # re-claims it, and BOTH run the same workflow. `locked_by` is the node id
  # (not unique per claim), so the original worker couldn't tell its claim had
  # been superseded. `lock_token` is a fresh UUID stamped on every claim, so a
  # worker can detect (via its heartbeat) that the row now carries a different
  # token and abort, and a late ack/nack from a fenced worker becomes a no-op.
  use Durable.Migration.Base

  @impl true
  def version, do: 20_260_623_000_000

  @impl true
  def up(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      add_if_not_exists(:lock_token, :binary_id)
    end

    :ok
  end

  @impl true
  def down(prefix) do
    alter table(:workflow_executions, prefix: prefix) do
      remove_if_exists(:lock_token, :binary_id)
    end

    :ok
  end
end
