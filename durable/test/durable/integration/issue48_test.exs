defmodule Issue48AccountSync do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # One sync of an account at a time. An edit while one runs syncs again after
  # it, with the newest edit.
  workflow "i48_account_sync", on_duplicate: :run_again do
    step :sync, fn account ->
      Probe.note({:synced, account["rev"]})

      Probe.inside([:sync], fn ->
        if account["hold"],
          do: Probe.wait_for({:release, account["rev"]}),
          else: Process.sleep(50)
      end)

      {:ok, account}
    end
  end
end

defmodule Issue48CloseAccount do
  @moduledoc false
  use Durable

  # A closed account has nothing to sync: the step cancels its own run.
  workflow "i48_close_account", on_duplicate: :run_again do
    step :sync, fn account ->
      if account["closed"], do: {:cancel, "account closed"}, else: {:ok, account}
    end
  end
end

defmodule Issue48MonthlyReport do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "i48_monthly_report" do
    step :render, fn report ->
      Probe.note(:rendering)
      Probe.wait_for(:report_data_ready)
      {:ok, report}
    end
  end
end

defmodule Issue48Thumbnail do
  @moduledoc false
  use Durable

  workflow "i48_thumbnail" do
    step :resize, fn image -> {:ok, Map.put(image, "width", 320)} end
  end
end

defmodule Issue48ShippingLabel do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "i48_shipping_label" do
    step :fetch_order, fn order -> {:ok, order} end

    step :print_label, fn order ->
      Probe.note(:printed)
      {:ok, order}
    end
  end
end

defmodule Issue48TrackParcel do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # Asks the carrier every so often until the parcel is delivered. Its worker
  # is lost on the 1st, 3rd and 5th ask; the others snooze.
  workflow "i48_track_parcel" do
    step :poll_carrier, fn parcel ->
      case Probe.note(:polled) do
        n when n in [1, 3, 5] ->
          Probe.note(:lost_here)
          Probe.wait_for(:never)

        n when n < 6 ->
          {:snooze, 10}

        _ ->
          {:ok, Map.put(parcel, "delivered", true)}
      end
    end
  end
end

defmodule Issue48Charge do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "i48_charge" do
    step :charge, fn order ->
      Probe.note(:charging)
      Probe.wait_for(:card_answered)
      {:ok, Map.put(order, "gateway_reply", "approved")}
    end

    step :email_receipt, fn order ->
      Probe.note(:receipt)
      {:ok, order}
    end
  end
end

defmodule Durable.Integration.Issue48Test do
  @moduledoc """
  Issue #48: bugs on main after 2.0.2, each made to happen for real with live
  pollers on Postgres.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Keys
  alias Durable.Queue.Poller
  alias Durable.Queue.StaleJobRecovery

  @moduletag :capture_log

  @sync "i48_account_sync"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Holds a key's advisory lock from another connection until told to let go,
  # as a start in a long transaction does.
  defp hold_key_lock(module, name, key) do
    test = self()

    holder =
      Task.async(fn ->
        IntegrationRepo.transaction(
          fn ->
            IntegrationRepo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
              Keys.lock_name(module, name, key)
            ])

            send(test, :key_locked)

            receive do
              :let_go -> :ok
            end
          end,
          timeout: :infinity
        )
      end)

    assert_receive :key_locked, 2_000
    holder
  end

  defp let_go(holder) do
    send(holder.pid, :let_go)
    Task.await(holder)
  end

  # The backend waiting for an advisory lock.
  defp await_advisory_waiter do
    find_backend("""
    SELECT a.pid FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
    WHERE l.locktype = 'advisory' AND NOT l.granted AND a.datname = current_database()
    """)
  end

  defp find_backend(sql) do
    pid =
      Enum.find_value(1..300, fn _ ->
        case IntegrationRepo.query!(sql).rows do
          [[pid] | _] ->
            pid

          [] ->
            Process.sleep(20)
            nil
        end
      end)

    assert is_integer(pid), "nothing blocked"
    pid
  end

  # Kills the worker running `id`, and its step with it: what a node dying
  # does, seen from the database. Nothing records how the attempt ended.
  defp kill_worker_of(id) do
    assert_eventually(fn -> worker_of(id) end)
    pid = worker_of(id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  defp worker_of(id) do
    Enum.find_value(:sys.get_state(Poller.Default).workers, fn {pid, w} ->
      w.job_id == id && pid
    end)
  end

  # A dead worker's lock is as old as it would be after `stale_lock_timeout`.
  defp age_locks!(ids) do
    IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id in ^ids),
      set: [locked_at: DateTime.add(DateTime.utc_now(), -3_600, :second)]
    )
  end

  defp step_rows(id) do
    IntegrationRepo.all(
      from(s in StepExecution, where: s.workflow_id == ^id, order_by: [asc: s.inserted_at])
    )
  end

  defp sync(rev, opts \\ []) do
    input = %{"rev" => rev, "hold" => Keyword.get(opts, :hold, false)}

    {:ok, id} =
      Durable.start(Issue48AccountSync, input, [key: "acct:7"] ++ Keyword.delete(opts, :hold))

    id
  end

  # ---------------------------------------------------------------------------
  # 1. A waiter that couldn't take its key
  # ---------------------------------------------------------------------------

  describe "a run_again waiter whose key's lock can't be had" do
    test "waits again, and runs once the lock is free" do
      start_durable!(%{default: 2})

      holder = sync(1, hold: true)
      assert_eventually(fn -> Probe.hits({:synced, 1}) == 1 end)
      waiter = sync(2)
      assert waiter != holder

      lock = hold_key_lock(Issue48AccountSync, @sync, "acct:7")
      :ok = Probe.set({:release, 1})

      # The waiter is claimed and waits for the key's lock, and the database
      # gives up on it: a lock timeout, a deadlock or a cancel all look so.
      pid = await_advisory_waiter()
      IntegrationRepo.query!("SELECT pg_cancel_backend($1)", [pid])
      Process.sleep(200)
      refute get(waiter).status == :failed
      let_go(lock)

      assert %{holds_key: true, runs_after_id: nil} = await_status(waiter, :completed)
      assert Probe.hits({:synced, 2}) == 1

      # The key isn't stuck: the next edit syncs.
      next = sync(3)
      assert next not in [holder, waiter]
      await_status(next, :completed)
    end
  end

  describe "a run_again waiter that failed before it took its key, retried" do
    # 2.0.2 failed a waiter whose key's lock timed out, and left it so. Its
    # retry took the key back with `runs_after_id` still set, and the next
    # claim made it wait behind itself, holding the key for good.
    test "runs, and the key moves on" do
      start_durable!(%{default: 2})

      holder = sync(1, hold: true)
      assert_eventually(fn -> Probe.hits({:synced, 1}) == 1 end)
      waiter = sync(2)

      # As 2.0.2's nack left it.
      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^waiter),
          set: [status: :failed, error: %{"type" => "x"}, completed_at: DateTime.utc_now()]
        )

      :ok = Probe.set({:release, 1})
      await_status(holder, :completed)

      assert {:ok, ^waiter} = Durable.retry(waiter)
      assert %{holds_key: true, runs_after_id: nil} = await_status(waiter, :completed)
      assert Probe.hits({:synced, 2}) == 1

      next = sync(3)
      assert next not in [holder, waiter]
      await_status(next, :completed)
    end
  end

  describe "a run left waiting behind itself by 2.0.2" do
    test "is claimed and runs" do
      start_durable!(%{default: 1})

      id = sync(1, scheduled_at: DateTime.add(DateTime.utc_now(), 3_600, :second))

      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [runs_after_id: id, scheduled_at: nil]
        )

      assert %{holds_key: true, runs_after_id: nil} = await_status(id, :completed)
    end
  end

  # ---------------------------------------------------------------------------
  # 2. A waiter that stale recovery can't put back
  # ---------------------------------------------------------------------------

  describe "stale recovery, with a waiter lost before it took its key" do
    test "puts every lost run back, and cancels the waiter a newer one replaced" do
      start_durable!(%{default: 3}, heartbeat_interval: 60_000)

      holder = sync(1, hold: true)
      assert_eventually(fn -> Probe.hits({:synced, 1}) == 1 end)
      waiter = sync(2)

      # Lost with the waiter: an unrelated run on the same node.
      {:ok, report} = Durable.start(Issue48MonthlyReport, %{"month" => "2026-10"})
      assert_eventually(fn -> Probe.hits(:rendering) == 1 end)

      # The waiter is claimed, and its node dies before it takes the key.
      lock = hold_key_lock(Issue48AccountSync, @sync, "acct:7")
      :ok = Probe.set({:release, 1})
      await_advisory_waiter()
      assert %{status: :running} = get(waiter)
      kill_worker_of(waiter)
      kill_worker_of(report)
      let_go(lock)
      await_status(holder, :completed)

      # The key has moved on meanwhile: a new holder runs, and a newer edit
      # waits behind it.
      newer_holder = sync(3, hold: true)
      assert_eventually(fn -> Probe.hits({:synced, 3}) == 1 end)
      newer_waiter = sync(4)
      assert %{status: :pending, runs_after_id: ^newer_holder} = get(newer_waiter)

      age_locks!([waiter, report])
      assert {:ok, _} = StaleJobRecovery.recover_now(Durable)

      assert %{status: :cancelled} = get(waiter)
      :ok = Probe.set(:report_data_ready)
      await_status(report, :completed)

      :ok = Probe.set({:release, 3})
      await_status(newer_waiter, :completed)
      assert Probe.hits({:synced, 2}) == 0
      assert Probe.hits({:synced, 4}) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # 3. A holder cancelled mid-step
  # ---------------------------------------------------------------------------

  describe "a key's holder cancelled while its step runs" do
    test "keeps the run waiting behind it until its step has stopped" do
      start_durable!(%{default: 2}, heartbeat_interval: 1_000)

      holder = sync(1, hold: true)
      assert_eventually(fn -> Probe.hits({:synced, 1}) == 1 end)
      waiter = sync(2)

      :ok = Durable.cancel(holder, "superseded by an edit")
      await_status(waiter, :completed, 10_000)

      assert Probe.peak(:sync) == 1
    end

    test "starts the next run of the key once its step has stopped" do
      start_durable!(%{default: 2}, heartbeat_interval: 1_000)

      holder = sync(1, hold: true, on_duplicate: :use_existing)
      assert_eventually(fn -> Probe.hits({:synced, 1}) == 1 end)

      :ok = Durable.cancel(holder, "wrong account")
      next = sync(2, on_duplicate: :use_existing)
      assert next != holder
      await_status(next, :completed, 10_000)

      assert Probe.peak(:sync) == 1
    end

    test "doesn't hold up the key when its own step cancelled it" do
      start_durable!(%{default: 1}, heartbeat_interval: 60_000)

      {:ok, closed} = Durable.start(Issue48CloseAccount, %{"closed" => true}, key: "acct:3")
      await_status(closed, :cancelled)

      {:ok, next} = Durable.start(Issue48CloseAccount, %{"closed" => false}, key: "acct:3")
      assert next != closed
      assert %{scheduled_at: nil} = get(next)
      await_status(next, :completed)
    end

    test "doesn't hold up the key when it was cancelled before its step began" do
      start_durable!(%{default: 2}, heartbeat_interval: 60_000)

      {:ok, holder} =
        Durable.start(Issue48AccountSync, %{"rev" => 1},
          key: "acct:9",
          scheduled_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
        )

      :ok = Durable.cancel(holder)
      {:ok, next} = Durable.start(Issue48AccountSync, %{"rev" => 2}, key: "acct:9")
      assert %{scheduled_at: nil} = get(next)
      await_status(next, :completed)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. A backlog on a long poll
  # ---------------------------------------------------------------------------

  describe "a backlog on a queue with a long poll_interval" do
    test "is claimed as workers finish, not a poll at a time" do
      start_durable!(%{default: 4}, poll_interval: 5_000)
      # The first poll has come and gone: only the start's wake polls now.
      Process.sleep(100)

      results =
        Durable.start_many(for n <- 1..200, do: {Issue48Thumbnail, %{"image" => n}})

      ids = for {:ok, id} <- results, do: id
      assert length(ids) == 200

      # 4 a poll would be 250 s.
      assert_eventually(
        fn ->
          IntegrationRepo.aggregate(
            from(w in WorkflowExecution, where: w.id in ^ids and w.status == :completed),
            :count
          ) == 200
        end,
        30_000
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Found by the audit: a keyed schedule whose key is busy
  # ---------------------------------------------------------------------------

  describe "a due schedule whose key a long transaction holds" do
    defp overdue!(name, seconds) do
      {1, _} =
        IntegrationRepo.update_all(
          from(s in Durable.Storage.Schemas.ScheduledWorkflow, where: s.name == ^name),
          set: [next_run_at: DateTime.add(DateTime.utc_now(), -seconds, :second)]
        )
    end

    defp fired(name) do
      IntegrationRepo.all(
        from(w in WorkflowExecution, where: w.trigger == :schedule and w.trigger_ref == ^name)
      )
    end

    test "doesn't hold up the other due schedules, and fires at a later check" do
      start_durable!(%{default: 2})

      {:ok, _} =
        Durable.schedule(Issue48Thumbnail, "* * * * *", name: "i48_keyed", key: "thumbs")

      {:ok, _} = Durable.schedule(Issue48Thumbnail, "* * * * *", name: "i48_plain")
      # The keyed one is checked first.
      overdue!("i48_keyed", 120)
      overdue!("i48_plain", 60)

      lock = hold_key_lock(Issue48Thumbnail, "i48_thumbnail", "thumbs")

      {us, _} =
        :timer.tc(fn ->
          Durable.Scheduler.check_schedules()
          Durable.Scheduler.status()
        end)

      assert us < 2_000_000, "the check took #{div(us, 1000)} ms"
      assert [_] = fired("i48_plain")
      assert [] = fired("i48_keyed")

      keyed =
        IntegrationRepo.get_by!(Durable.Storage.Schemas.ScheduledWorkflow, name: "i48_keyed")

      assert keyed.consecutive_failures == 0
      assert DateTime.before?(keyed.next_run_at, DateTime.utc_now())

      let_go(lock)
      Durable.Scheduler.check_schedules()
      Durable.Scheduler.status()
      assert [_] = fired("i48_keyed")
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Failing a run nothing recorded the end of
  # ---------------------------------------------------------------------------

  describe "a run whose worker crashed outside its step" do
    test "is failed with its open attempt closed, in one write" do
      # The step's own write is refused, so the worker crashes and the run is
      # failed in its place. Closing the step's row is slowed down meanwhile.
      before_update!(
        "i48_refuse_charge",
        "step_executions",
        "NEW.step_name = 'charge' AND NEW.status = 'completed'",
        "RAISE EXCEPTION 'the ledger refused it'"
      )

      before_update!(
        "i48_slow_close",
        "step_executions",
        "NEW.status = 'failed'",
        "PERFORM pg_sleep(0.5)"
      )

      start_durable!(%{default: 1}, heartbeat_interval: 60_000)
      {:ok, id} = Durable.start(Issue48Charge, %{"order" => 1})
      assert_eventually(fn -> Probe.hits(:charging) == 1 end)
      :ok = Probe.set(:card_answered)

      # Read in one statement, so both are seen as of one moment.
      seen =
        for _ <- 1..50 do
          %{rows: [[run, step]]} =
            IntegrationRepo.query!(
              """
              SELECT w.status, s.status FROM durable.workflow_executions w
              JOIN durable.step_executions s ON s.workflow_id = w.id WHERE w.id = $1
              """,
              [Ecto.UUID.dump!(id)]
            )

          Process.sleep(20)
          {run, step}
        end

      refute {"failed", "running"} in seen
      assert {"failed", "failed"} in seen
      assert %{status: :failed} = get(id)
      assert Enum.all?(step_rows(id), &(&1.status != :running))
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Lost between two steps, again and again
  # ---------------------------------------------------------------------------

  describe "a run whose worker is lost between two steps every time" do
    setup do
      # The worker dies just as the second step begins, before its row is
      # written: what a node that runs out of memory saving the first does.
      handler = "i48-lose-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:durable, :step, :start],
        fn _event, _measure, meta, _config ->
          if meta.step == :print_label do
            Probe.note(:lost)
            [worker | _] = Process.get(:"$callers")
            Process.exit(worker, :kill)
            Process.exit(self(), :kill)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "fails at the third loss in a row, instead of going round for ever" do
      start_durable!(%{default: 1}, heartbeat_interval: 60_000)
      {:ok, id} = Durable.start(Issue48ShippingLabel, %{"order" => 1})

      for lost <- 1..3 do
        assert_eventually(fn -> Probe.hits(:lost) == lost end)
        assert_eventually(fn -> :sys.get_state(Poller.Default).workers == %{} end)
        age_locks!([id])
        assert {:ok, 1} = StaleJobRecovery.recover_now(Durable)
        if lost < 3, do: assert(get(id).status in [:pending, :running])
      end

      run = await_status(id, :failed)
      assert run.error["type"] == "worker_lost"
      Process.sleep(300)
      assert Probe.hits(:lost) == 3
      assert Probe.hits(:printed) == 0

      # Retried, it gets three more.
      {:ok, ^id} = Durable.retry(id)
      assert_eventually(fn -> Probe.hits(:lost) == 4 end)
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Losses that aren't in a row
  # ---------------------------------------------------------------------------

  describe "a step that polls, and loses its worker now and then" do
    test "isn't failed by three losses that weren't in a row" do
      start_durable!(%{default: 1}, heartbeat_interval: 60_000)
      {:ok, id} = Durable.start(Issue48TrackParcel, %{"parcel" => "1Z999"})

      for lost <- 1..3 do
        assert_eventually(fn -> Probe.hits(:lost_here) == lost end)
        kill_worker_of(id)
        age_locks!([id])
        assert {:ok, 1} = StaleJobRecovery.recover_now(Durable)
      end

      run = await_status(id, :completed, 10_000)
      assert run.context["delivered"] == true

      lost =
        Enum.filter(step_rows(id), &(&1.status == :failed and &1.error["type"] == "worker_lost"))

      assert length(lost) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # 9. A drain before the stop
  # ---------------------------------------------------------------------------

  describe "Durable.drain/1 before the node stops" do
    test "leaves the stop only what's left of the grace period" do
      start_durable!(%{default: 1}, shutdown_grace_period: 2_000)
      {:ok, id} = Durable.start(Issue48MonthlyReport, %{"month" => "2026-11"})
      assert_eventually(fn -> Probe.hits(:rendering) == 1 end)

      assert {:error, :timeout} = Durable.drain()

      {us, _} = :timer.tc(fn -> stop_supervised!(Durable) end)
      assert us < 1_000_000, "the stop waited #{div(us, 1000)} ms more"
      assert %{status: :pending, locked_by: nil} = get(id)
    end
  end

  # ---------------------------------------------------------------------------
  # 10. A save the database gives up on
  # ---------------------------------------------------------------------------

  describe "a save the database gives up on, after the step finished" do
    test "puts the run back, and the next claim carries on without running the step again" do
      start_durable!(%{default: 1}, heartbeat_interval: 60_000)
      {:ok, id} = Durable.start(Issue48Charge, %{"order" => 2})
      assert_eventually(fn -> Probe.hits(:charging) == 1 end)

      # The run's row is held, so the save after the step waits, and is then
      # cancelled: a statement timeout looks the same.
      test = self()

      holder =
        Task.async(fn ->
          IntegrationRepo.transaction(fn ->
            IntegrationRepo.query!(
              "SELECT 1 FROM durable.workflow_executions WHERE id = $1 FOR UPDATE",
              [Ecto.UUID.dump!(id)]
            )

            send(test, :run_locked)

            receive do
              :let_go -> :ok
            end
          end)
        end)

      assert_receive :run_locked
      :ok = Probe.set(:card_answered)

      pid =
        find_backend("""
        SELECT pid FROM pg_stat_activity WHERE datname = current_database()
        AND wait_event_type = 'Lock' AND query ILIKE 'UPDATE%workflow_executions%'
        """)

      IntegrationRepo.query!("SELECT pg_cancel_backend($1)", [pid])
      send(holder.pid, :let_go)
      Task.await(holder)

      run = await_status(id, :completed)
      assert run.context["gateway_reply"] == "approved"
      assert Probe.hits(:charging) == 1
      assert Probe.hits(:receipt) == 1
    end

    test "fails the run at the third in a row, instead of going round for ever" do
      # Every save of this step's result is refused, as a deadlock would be.
      before_update!(
        "i48_refuse_save",
        "workflow_executions",
        "NEW.context ? 'gateway_reply'",
        "RAISE EXCEPTION 'deadlock detected' USING ERRCODE = 'deadlock_detected'"
      )

      start_durable!(%{default: 1})
      :ok = Probe.set(:card_answered)
      {:ok, id} = Durable.start(Issue48Charge, %{"order" => 3})

      run = await_status(id, :failed)
      assert run.error["type"] == "worker_lost"
      assert Probe.hits(:charging) == 1
      assert Probe.hits(:receipt) == 0

      assert length(Durable.Activity.list!(workflow_id: id, kinds: ["worker_lost"])) == 3
    end
  end
end
