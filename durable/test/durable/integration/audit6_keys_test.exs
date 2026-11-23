defmodule Durable.Integration.Audit6KeysTest do
  @moduledoc """
  Audit 6: workflow keys and run control under concurrency, with live pollers
  on real Postgres.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Keys
  alias Durable.KeyWorkflows, as: K

  @moduletag :capture_log

  defp lock_key!(key) do
    IntegrationRepo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      Keys.lock_name(K.Again, "kw_again", key)
    ])
  end

  # The holder ends and its waiting run is claimed, but before that run takes
  # the key, a run_again start comes in: from a transaction that already holds
  # the key's lock (another start in it, say), so the claimed run has to wait
  # for the lock. The start must not jump the queue: the guide's "one run
  # waits, with the newest input" means the newest input runs last.
  setup do
    start_supervised!(K.Ledger)
    :ok
  end

  test "a run_again start while the waiting run is claimed runs after it, not before" do
    start_durable!(%{default: 4})
    key = "account:7"

    {:ok, holder} = Durable.start(K.Again, %{"key" => key, "v" => 1, "hold" => true}, key: key)
    assert_eventually(fn -> K.ran(key) == [1] end)
    {:ok, waiting} = Durable.start(K.Again, %{"key" => key, "v" => 2}, key: key)
    assert get(waiting).runs_after_id == holder

    {:ok, last} =
      IntegrationRepo.transaction(fn ->
        lock_key!(key)
        Probe.set({:go, 1})
        await_status(holder, :completed)
        # Claimed: its worker is now waiting for the key's lock.
        assert_eventually(fn -> get(waiting).locked_by != nil end)

        {:ok, last} = Durable.start(K.Again, %{"key" => key, "v" => 3}, key: key)
        last
      end)

    for id <- Enum.uniq([waiting, last]), do: await_status(id, :completed)

    assert K.ran(key) == [1, 2, 3]
    assert K.overlaps(key) == []
  end
end
