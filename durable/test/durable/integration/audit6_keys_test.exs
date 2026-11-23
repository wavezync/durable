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

  # The workflow says run_again; one producer says cancel_existing, for "the
  # newest input wins, starting over". The run waiting behind the replaced
  # holder has an older input than the replacement.
  test "a cancel_existing start replaces the run waiting behind the holder too" do
    key = "account:10"
    start!(key, %{"v" => 1, "hold" => true})
    assert_eventually(fn -> K.ran(key) == [1] end)
    waiting = start!(key, %{"v" => 2})

    {:ok, newest} =
      Durable.start(K.Again, %{"key" => key, "v" => 3}, key: key, on_duplicate: :cancel_existing)

    assert %{status: :cancelled, error: %{"replaced_by" => ^newest}} = get(waiting)

    Probe.set({:go, 1})
    await_status(newest, :completed)
    assert K.ran(key) == [1, 3]
  end

  # Starts keep coming while the holder finishes. Each either reaches the
  # holder while it's going, or finds the key free and starts a run: the
  # guide's table has no third answer for a key reuse: lets go.
  test "a send_event start never answers key_taken for a holder that just finished" do
    refused =
      for n <- 1..100, reduce: [] do
        refused ->
          key = "doc:#{n}"
          holder = start!(key, %{"v" => 0, "ms" => 20})
          refused ++ send_until_free(key, holder, 1)
      end

    assert refused == []
  end

  defp send_until_free(key, holder, v) do
    case Durable.start(K.Again, %{"key" => key, "v" => v},
           key: key,
           on_duplicate: {:send_event, "upd"}
         ) do
      {:ok, ^holder} -> send_until_free(key, holder, v + 1)
      {:ok, _new_run} -> []
      refused -> [{key, get(holder).status, refused}]
    end
  end

  # Issue #48 item 3 has `Durable.cancel/2` free the key while the cancelled
  # step still runs. With `rollback: true` the key goes another way, which a
  # fix in `Keys` alone won't see: the cancel queues the undo, and a run queued
  # to be undone lets its key go at once (`Executor.without_key/2`), so the next
  # start finds no holder at all. The undo itself waits a heartbeat for the
  # step to stop (`queue_cancelled/2`); the key doesn't.
  @tag skip: "fails until issue #48 item 3 is fixed"
  test "cancel with rollback: true doesn't start the key's next run beside the cancelled step" do
    stop_supervised!(Durable)
    start_durable!(%{default: 4}, heartbeat_interval: 3_000)
    key = "account:9"

    holder = start!(key, %{"v" => 1, "hold" => true})
    assert_eventually(fn -> K.ran(key) == [1] end)
    :ok = Durable.cancel(holder, "customer cancelled", rollback: true)
    next = start!(key, %{"v" => 2})

    # Long enough for a start that went straight ahead; well inside the beat.
    Process.sleep(1_000)
    assert K.overlaps(key) == []

    Probe.set({:go, 1})
    await_status(next, :completed, 15_000)
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
