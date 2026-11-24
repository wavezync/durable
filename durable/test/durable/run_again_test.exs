defmodule Durable.RunAgainTest do
  @moduledoc """
  `on_duplicate: :run_again`: a start while the key's holder is going leaves
  one run waiting behind it, with the newest input.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Storage.Schemas.WorkflowExecution

  defmodule Rebuild do
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "rebuild_index", on_duplicate: :run_again do
      step :work, fn data ->
        case wait_for_event("go") do
          %{"fail" => true} -> {:fail, "broken"}
          _ -> {:ok, data}
        end
      end
    end
  end

  defmodule RebuildAfterFailure do
    use Durable
    use Durable.Wait

    workflow "rebuild_after_failure", on_duplicate: :run_again, reuse: :after_failure do
      step :work, fn data ->
        wait_for_event("go")
        {:ok, data}
      end
    end
  end

  defmodule DebouncedFlaky do
    use Durable
    use Durable.Context

    workflow "debounced_flaky", debounce: [period: 50] do
      step(
        :call,
        [retry: [max_attempts: 3, backoff: :constant, base: :timer.hours(1)]],
        fn data ->
          if attempt() == 1, do: {:error, :down}, else: {:ok, data}
        end
      )
    end
  end

  defmodule DebouncedAgain do
    use Durable
    use Durable.Wait

    workflow "debounced_again", on_duplicate: :run_again, debounce: [period: 50] do
      step :work, fn data ->
        wait_for_event("go")
        {:ok, data}
      end
    end
  end

  defp get(id), do: TestRepo.get!(WorkflowExecution, id)
  defp claim, do: Postgres.fetch_jobs(Config.get(Durable), "default", 10, "test-node")

  defp finish(run, payload \\ %{}) do
    :ok = Durable.send_event(run.id, "go", payload)
    drain(run)
  end

  test "starts while the holder is going leave one run waiting, with the newest input" do
    holder = run_workflow(Rebuild, %{"v" => 1}, key: "account:7")
    assert holder.status == :waiting

    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "account:7")
    assert {:ok, ^waiting} = Durable.start(Rebuild, %{"v" => 3}, key: "account:7")

    run = get(waiting)
    assert {run.status, run.runs_after_id, run.holds_key} == {:pending, holder.id, false}
    assert run.input == %{"v" => 3}
    assert {:ok, %{runs_after_id: after_id}} = Durable.Query.get_execution(waiting)
    assert after_id == holder.id

    # The claim query leaves it alone while the holder is open...
    assert claim() == []

    assert finish(holder).status == :completed

    # ...and claims it once the holder has ended. It takes the key.
    assert [%{id: ^waiting, lock_token: token}] = claim()
    Executor.execute_workflow(waiting, Config.get(Durable), token)

    run = get(waiting)
    assert {run.status, run.holds_key, run.runs_after_id} == {:waiting, true, nil}
    refute get(holder.id).holds_key
  end

  test "a failed holder still lets the waiting run go, as reuse: :after_close does" do
    Durable.TelemetryHandler.attach_events([[:durable, :key, :handoff]])
    holder = run_workflow(Rebuild, %{"v" => 1}, key: "k")
    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "k")

    assert finish(holder, %{"fail" => true}).status == :failed
    assert drain(waiting).holds_key

    # Handed off as a start's is.
    holder_id = holder.id
    assert_receive {:event, :handoff, %{count: 1}, %{from: ^holder_id, to: ^waiting}}

    assert [%{details: %{"from_status" => "failed", "reuse" => "after_close"}}] =
             Durable.Activity.list!(workflow_id: waiting, kinds: ["key_handed_off"])
  end

  test "the waiting run is cancelled when reuse: keeps the key" do
    holder = run_workflow(RebuildAfterFailure, %{}, key: "k")
    {:ok, waiting} = Durable.start(RebuildAfterFailure, %{"v" => 2}, key: "k")

    assert finish(holder).status == :completed

    run = drain(waiting)
    assert run.status == :cancelled
    assert run.error["message"] =~ "reuse: after_failure"
  end

  test "a holder that hasn't started takes the newer input instead" do
    {:ok, holder} = Durable.start(Rebuild, %{"v" => 1}, key: "k")
    assert {:ok, ^holder} = Durable.start(Rebuild, %{"v" => 2}, key: "k")

    assert get(holder).input == %{"v" => 2}
    assert TestRepo.aggregate(WorkflowExecution, :count) == 1
  end

  test "if a retry took the key back meanwhile, the waiting run waits behind it" do
    failed = run_workflow(Rebuild, %{"v" => 1}, key: "k")
    assert finish(failed, %{"fail" => true}).status == :failed

    # The failed run lets the key go to a newer one, then a run waits behind that.
    {:ok, second} = Durable.start(Rebuild, %{"v" => 2}, key: "k")
    drain(second)
    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 3}, key: "k")
    assert finish(get(second)).status == :completed

    assert {:ok, _} = Durable.retry(failed.id)
    assert get(failed.id).holds_key

    Executor.execute_workflow(waiting, Config.get(Durable))
    run = get(waiting)
    assert {run.status, run.runs_after_id, run.holds_key} == {:pending, failed.id, false}
  end

  # Issue #50: a start in another mode took the free key ahead of the waiting
  # run, and the waiting run's older input ran last.
  describe "a start in any mode, with the holder ended and a run waiting" do
    setup do
      holder = run_workflow(Rebuild, %{"v" => 1}, key: "k")
      {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "k")
      assert finish(holder).status == :completed
      %{holder: holder, waiting: waiting}
    end

    test ":use_existing gets the waiting run back", %{waiting: waiting} do
      assert {:ok, ^waiting} =
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :use_existing)

      assert get(waiting).input == %{"v" => 2}
      assert TestRepo.aggregate(WorkflowExecution, :count) == 2

      assert [%{details: %{"outcome" => "use_existing"}}] =
               Durable.Activity.list!(workflow_id: waiting, kinds: ["key_duplicate"])
    end

    test ":error is refused with the waiting run", %{waiting: waiting} do
      assert {:error, {:key_taken, ^waiting}} =
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :error)

      assert TestRepo.aggregate(WorkflowExecution, :count) == 2
    end

    test "{:send_event, name} sends the input to the waiting run", %{waiting: waiting} do
      assert {:ok, ^waiting} =
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: {:send_event, "go"})

      # The event is buffered, so the run's wait gets it at once.
      run = drain(waiting)
      assert {run.status, run.holds_key} == {:completed, true}
      assert TestRepo.aggregate(WorkflowExecution, :count) == 2
    end

    test ":cancel_existing replaces the waiting run", %{waiting: waiting} do
      assert {:ok, new} =
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :cancel_existing)

      assert get(waiting).status == :cancelled
      assert get(waiting).error["replaced_by"] == new
      assert get(new).holds_key
    end

    test "a released key still goes to the waiting run first", %{holder: holder, waiting: waiting} do
      :ok = Durable.release_key(holder.id)

      assert {:ok, ^waiting} =
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :use_existing)

      assert {:error, {:key_taken, ^waiting}} =
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :error)

      assert TestRepo.aggregate(WorkflowExecution, :count) == 2
    end

    test "one a worker has claimed counts too", %{waiting: waiting} do
      assert [%{id: ^waiting, lock_token: token}] = claim()

      assert {:ok, ^waiting} =
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :use_existing)

      assert {:error, {:key_taken, ^waiting}} =
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :error)

      Executor.execute_workflow(waiting, Config.get(Durable), token)
      run = get(waiting)
      assert {run.status, run.holds_key, run.input} == {:waiting, true, %{"v" => 2}}
    end

    # The sequence the keys fuzz found (seed 629735): the newest input runs last.
    test "then a run_again start's input is the one that runs last", %{waiting: waiting} do
      assert {:error, {:key_taken, ^waiting}} =
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :error)

      assert {:ok, ^waiting} = Durable.start(Rebuild, %{"v" => 4}, key: "k")

      run = finish(drain(waiting))
      assert {run.status, run.holds_key, run.input} == {:completed, true, %{"v" => 4}}
      assert TestRepo.aggregate(WorkflowExecution, :count) == 2
    end
  end

  # A start is several statements under the key's lock, but a release, a
  # rollback, pruning and a worker moving a waiting run don't take that lock.
  # Each test runs such a write right after one of the start's statements, in
  # the start's own transaction, which is what the start sees when another
  # connection commits it there. (The independent review of the #50 fix.)
  describe "a start racing a write that doesn't take the key's lock" do
    setup do
      holder = run_workflow(Rebuild, %{"v" => 1}, key: "k")
      {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "k")
      assert finish(holder).status == :completed
      %{holder: holder, waiting: waiting}
    end

    test "the holder released after the start's insert met it", ctx do
      after_query(&holder_insert_missed?/1, fn -> :ok = Durable.release_key(ctx.holder.id) end)

      assert {:ok, ctx.waiting} ==
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :use_existing)

      assert Process.get(:fired)
      assert TestRepo.aggregate(WorkflowExecution, :count) == 2
    end

    test "the holder released after the start's insert met it, run_again", ctx do
      after_query(&holder_insert_missed?/1, fn -> :ok = Durable.release_key(ctx.holder.id) end)

      assert {:ok, ctx.waiting} == Durable.start(Rebuild, %{"v" => 3}, key: "k")
      assert get(ctx.waiting).input == %{"v" => 3}
      assert TestRepo.aggregate(WorkflowExecution, :count) == 2
    end

    test "the holder released after the start read it", ctx do
      after_query(&holder_read?/1, fn -> :ok = Durable.release_key(ctx.holder.id) end)

      assert {:ok, ctx.waiting} ==
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :use_existing)

      assert Process.get(:fired)
      assert TestRepo.aggregate(WorkflowExecution, :count) == 2
    end

    test "the claimed waiting run put back by the stale sweep after the start read it" do
      assert [%{id: waiting}] = claim()
      age_lock(waiting)
      config = Config.get(Durable)
      after_query(&waiter_read?/1, fn -> {:ok, 1} = Postgres.recover_stale_locks(config, 60) end)

      assert {:ok, ^waiting} =
               Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :use_existing)

      assert Process.get(:fired)
      assert get(waiting).status == :pending
    end

    # Seen claimed, it gets a run behind it; that meets the run put back, and
    # gives it the newer input instead.
    test "the claimed waiting run put back after the start read it, run_again" do
      assert [%{id: waiting}] = claim()
      age_lock(waiting)
      config = Config.get(Durable)
      after_query(&waiter_read?/1, fn -> {:ok, 1} = Postgres.recover_stale_locks(config, 60) end)

      assert {:ok, ^waiting} = Durable.start(Rebuild, %{"v" => 3}, key: "k")
      assert Process.get(:fired)
      assert {get(waiting).status, get(waiting).input} == {:pending, %{"v" => 3}}
      assert TestRepo.aggregate(WorkflowExecution, :count) == 2
      assert get(finish(drain(waiting)).id).holds_key
    end

    # Seen unclaimed, a worker claims it before its input is refreshed: the
    # newer input waits behind it.
    test "the waiting run claimed after the start read it, run_again", ctx do
      after_query(&waiter_read?/1, fn -> assert [%{id: _}] = claim() end)

      assert {:ok, behind} = Durable.start(Rebuild, %{"v" => 3}, key: "k")
      assert Process.get(:fired)
      run = get(behind)
      assert {run.runs_after_id, run.input, run.holds_key} == {ctx.waiting, %{"v" => 3}, false}
      assert get(ctx.waiting).input == %{"v" => 2}
    end
  end

  # A run ends without the key's lock: after a run_again start read the holder
  # as going, it ends, and a worker claims the run waiting behind it. The new
  # run goes behind that claimed run, not the ended holder, where it would be
  # claimable beside it and could take the key first. (Round 2 of the review.)
  test "a holder that ended after a run_again start read it as going" do
    holder = run_workflow(Rebuild, %{"v" => 1}, key: "k")
    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "k")

    after_query(&going_holder_read?/1, fn ->
      TestRepo.update_all(from(w in WorkflowExecution, where: w.id == ^holder.id),
        set: [status: :completed, completed_at: Durable.Clock.utc_now()]
      )

      assert [%{id: ^waiting}] = claim()
    end)

    assert {:ok, behind} = Durable.start(Rebuild, %{"v" => 3}, key: "k")
    assert Process.get(:fired)
    assert get(behind).runs_after_id == waiting
    assert claim() == []
  end

  # A run that failed before it began (its code missing past its deadline,
  # say), retried while a run waits: it holds the key, hasn't started, and has
  # a run waiting behind it. The newer input goes to the waiting run, which
  # runs last. (Round 3 of the review.)
  test "a retried holder that never started, with a run waiting behind it" do
    holder = run_workflow(Rebuild, %{"v" => 1}, key: "k")
    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "k")

    never =
      TestRepo.insert!(%WorkflowExecution{
        workflow_module: Atom.to_string(Rebuild),
        workflow_name: "rebuild_index",
        status: :failed,
        queue: "default",
        input: %{"v" => 0},
        context: %{},
        key: "k",
        holds_key: false,
        error: %{"type" => "timeout"}
      })

    assert finish(holder).status == :completed
    assert {:ok, _} = Durable.retry(never.id)
    assert get(never.id).holds_key

    assert {:ok, ^waiting} = Durable.start(Rebuild, %{"v" => 3}, key: "k")
    assert {get(never.id).input, get(waiting).input} == {%{"v" => 0}, %{"v" => 3}}
  end

  # As if it held the key: a debounced workflow's unstarted holder takes a
  # duplicate's input whatever on_duplicate: says, so the waiting run does too.
  test "on a debounced workflow the waiting run takes a duplicate start's input" do
    {:ok, holder} = Durable.start(DebouncedAgain, %{"v" => 1}, key: "k")
    assert drain(holder).status == :waiting
    {:ok, waiting} = Durable.start(DebouncedAgain, %{"v" => 2}, key: "k")
    assert finish(get(holder)).status == :completed

    for mode <- [:use_existing, :error] do
      assert {:ok, ^waiting} =
               Durable.start(DebouncedAgain, %{"v" => 3}, key: "k", on_duplicate: mode)
    end

    assert get(waiting).input == %{"v" => 3}
    assert TestRepo.aggregate(WorkflowExecution, :count) == 2
  end

  # Runs `fun` once, right after the first query of this process that `match?`.
  defp after_query(match?, fun) do
    me = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:durable, :test_repo, :query],
      fn _event, _measure, meta, _ ->
        if self() == me and not Process.get(:fired, false) and match?.(meta) do
          Process.put(:fired, true)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp sql(meta), do: IO.iodata_to_binary(meta.query)
  defp rows?(meta, n), do: match?({:ok, %{num_rows: ^n}}, meta.result)

  # The start's insert, meeting a holder.
  defp holder_insert_missed?(meta),
    do: sql(meta) =~ ~r/^INSERT INTO "durable"\."workflow_executions"/ and rows?(meta, 0)

  # `Keys.holder/2` finding one.
  defp holder_read?(meta),
    do: sql(meta) =~ ~r/^SELECT w0\."id", w0\."status", w0\."input"/ and rows?(meta, 1)

  defp going_holder_read?(meta),
    do: holder_read?(meta) and match?({:ok, %{rows: [[_, "waiting" | _]]}}, meta.result)

  # `Keys.waiter/1` finding one.
  defp waiter_read?(meta),
    do: sql(meta) =~ ~r/^SELECT/ and sql(meta) =~ ~s("runs_after_id" IS NULL) and rows?(meta, 1)

  # Its worker is gone: the stale sweep puts it back.
  defp age_lock(id) do
    TestRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
      set: [locked_at: DateTime.add(Durable.Clock.utc_now(), -600, :second)]
    )
  end

  test "a cancelled holder's waiting run goes first too" do
    holder = run_workflow(Rebuild, %{"v" => 1}, key: "k")
    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "k")
    :ok = Durable.cancel(holder.id, "done with it")

    for mode <- [:use_existing, {:send_event, "go"}],
        do: assert({:ok, ^waiting} = Durable.start(Rebuild, %{}, key: "k", on_duplicate: mode))

    assert {:error, {:key_taken, ^waiting}} =
             Durable.start(Rebuild, %{}, key: "k", on_duplicate: :error)

    assert TestRepo.aggregate(WorkflowExecution, :count) == 2
  end

  test "run_again with reuse: :never fails the compile" do
    assert_raise ArgumentError, ~r/reuse: :never/, fn ->
      defmodule NeverAgain do
        use Durable

        workflow "never_again", on_duplicate: :run_again, reuse: :never do
          step :a, fn data -> {:ok, data} end
        end
      end
    end
  end

  test "a debounced start leaves a run that is parked for a retry alone" do
    {:ok, id} = Durable.start(DebouncedFlaky, %{"v" => 1}, key: "k")
    Executor.execute_workflow(id, Config.get(Durable))
    parked = get(id)
    assert parked.status == :pending

    assert {:ok, ^id} = Durable.start(DebouncedFlaky, %{"v" => 2}, key: "k")

    run = get(id)
    assert run.input == %{"v" => 1}
    assert run.scheduled_at == parked.scheduled_at
  end
end
