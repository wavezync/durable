defmodule Durable.Integration.Audit6KeysTest do
  @moduledoc """
  Audit 6: workflow keys and run control under concurrency, with live pollers
  on real Postgres.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Keys
  alias Durable.KeyWorkflows, as: K

  @moduletag :capture_log

  setup do
    start_supervised!(K.Ledger)
    start_durable!(%{default: 4})
    :ok
  end

  defp start!(key, input) do
    {:ok, id} = Durable.start(K.Again, Map.put(input, "key", key), key: key)
    id
  end

  # A holder (v1) ends and its waiting run (v2) is claimed, but before that run
  # takes the key, `fun` runs: in a transaction that already holds the key's
  # lock (another start in it, say), so the claimed run waits for the lock
  # until `fun` returns.
  defp with_claimed_waiter(key, fun) do
    holder = start!(key, %{"v" => 1, "hold" => true})
    assert_eventually(fn -> K.ran(key) == [1] end)
    waiting = start!(key, %{"v" => 2})
    assert get(waiting).runs_after_id == holder

    {:ok, result} =
      IntegrationRepo.transaction(fn ->
        IntegrationRepo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          Keys.lock_name(K.Again, "kw_again", key)
        ])

        Probe.set({:go, 1})
        await_status(holder, :completed)
        assert_eventually(fn -> get(waiting).locked_by != nil end)
        fun.(waiting)
      end)

    {waiting, result}
  end

  # The guide's "one run waits, with the newest input": the newest input runs
  # last, so a start must not jump ahead of the run claimed to take the key.
  test "a run_again start while the waiting run is claimed runs after it, not before" do
    key = "account:7"
    {waiting, last} = with_claimed_waiter(key, fn _waiting -> start!(key, %{"v" => 3}) end)

    for id <- Enum.uniq([waiting, last]), do: await_status(id, :completed)

    assert K.ran(key) == [1, 2, 3]
    assert K.overlaps(key) == []
  end

  # The claimed run's task dies while it waits for the key's lock. Its worker
  # puts it back on its queue, where a newer start already waits behind it.
  test "a claimed waiting run that loses its task makes way for the newer start" do
    key = "account:8"

    {waiting, newer} =
      with_claimed_waiter(key, fn waiting ->
        newer = start!(key, %{"v" => 3})
        %{task_pid: task} = :sys.get_state(Durable.DataCase.get_worker_pid(waiting))
        Process.exit(task, :kill)
        newer
      end)

    # Well inside the 300 s before a stale lock is taken back.
    await_status(newer, :completed)
    assert K.ran(key) == [1, 3]
    assert %{status: :cancelled, locked_by: nil} = get(waiting)
  end
end
