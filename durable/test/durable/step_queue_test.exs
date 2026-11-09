defmodule Durable.StepQueueTest do
  @moduledoc """
  A step's `queue:` moves the run there for that step, so it takes a slot from
  that queue.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Queue.Manager
  alias Durable.Storage.Schemas.{Node, StepExecution, WorkflowExecution}
  alias Durable.Wait.TimeoutWorker

  defmodule Import do
    use Durable
    use Durable.Helpers

    workflow "import_document", queue: :documents do
      step(:download, [queue: :downloads], fn data ->
        {:ok, assign(data, :file, data["url"] <> ".pdf")}
      end)

      step(:ocr, [queue: "ocr"], fn data ->
        {:ok, assign(data, :text, "#{data.file} from #{data["url"]}")}
      end)

      step(:save, fn data -> {:ok, assign(data, :saved, true)} end)
    end
  end

  defmodule FlakyOcr do
    use Durable
    use Durable.Helpers
    use Durable.Context

    workflow "flaky_ocr" do
      step(:ocr, [queue: :ocr, retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
        if attempt() == 1, do: {:error, :down}, else: {:ok, assign(data, :text, "ok")}
      end)
    end
  end

  defmodule InBranch do
    use Durable
    use Durable.Helpers

    workflow "queue_in_branch" do
      branch on: fn _data -> "a" end do
        "a" ->
          step(:a1, [queue: :ocr], fn data -> {:ok, assign(data, :a1, true)} end)
          step(:a2, fn data -> {:ok, assign(data, :a2, true)} end)

        "b" ->
          step(:b1, fn data -> {:ok, assign(data, :b1, true)} end)
      end

      step(:done, fn data -> {:ok, assign(data, :done, true)} end)
    end
  end

  defmodule ThenParallel do
    use Durable
    use Durable.Helpers

    workflow "queue_then_parallel" do
      step(:prepare, [queue: :ocr], fn data -> {:ok, data} end)

      parallel do
        step(:plain, fn data -> {:ok, assign(data, :plain, true)} end)
        step(:llm, [queue: :llm], fn data -> {:ok, assign(data, :llm, true)} end)
      end
    end
  end

  defmodule OneOcrAtATime do
    use Durable

    workflow "one_ocr_at_a_time" do
      step(:ocr, [queue: :ocr], fn data ->
        running = :ets.update_counter(:step_queue_test, :running, 1)
        :ets.insert(:step_queue_test, {{:seen, running}})
        Process.sleep(150)
        :ets.update_counter(:step_queue_test, :running, -1)
        {:ok, data}
      end)
    end
  end

  defmodule BranchStaysPut do
    use Durable
    use Durable.Helpers

    workflow "branch_stays_put" do
      step(:prepare, [queue: :ocr], fn data -> {:ok, data} end)

      branch on: fn _data -> "a" end do
        "a" ->
          step(:a1, [queue: :ocr], fn data -> {:ok, assign(data, :a1, true)} end)

        "b" ->
          step(:b1, fn data -> {:ok, assign(data, :b1, true)} end)
      end
    end
  end

  defmodule AlreadyThere do
    use Durable

    workflow "already_there", queue: :ocr do
      step(:one, [queue: "ocr"], fn data -> {:ok, data} end)
      step(:two, [queue: :ocr], fn data -> {:ok, data} end)
    end
  end

  defmodule QuickMoves do
    use Durable

    workflow "quick_moves" do
      step(:ocr, [queue: :ocr], fn data -> {:ok, data} end)
      step(:save, fn data -> {:ok, data} end)
    end
  end

  defmodule EndsOnLlm do
    use Durable

    workflow "ends_on_llm", queue: :documents do
      step(:summarize, [queue: :llm], fn data -> {:ok, data} end)
    end
  end

  defmodule SnoozesOnOcr do
    use Durable

    workflow "snoozes_on_ocr" do
      step(:ocr, [queue: :ocr], fn data ->
        if Process.put(:snoozed, true), do: {:ok, data}, else: {:snooze, 1}
      end)

      step(:save, fn data -> {:ok, data} end)
    end
  end

  defmodule WaitsOnOcr do
    use Durable
    use Durable.Wait

    workflow "waits_on_ocr" do
      step(:ocr, [queue: :ocr], fn data ->
        wait_for_event("go")
        {:ok, data}
      end)

      step(:save, fn data -> {:ok, data} end)
    end
  end

  defmodule SleepsOnOcr do
    use Durable
    use Durable.Wait

    workflow "sleeps_on_ocr" do
      step(:ocr, [queue: :ocr], fn data ->
        sleep(1)
        {:ok, data}
      end)

      step(:save, fn data -> {:ok, data} end)
    end
  end

  defmodule SagaAcrossQueues do
    use Durable
    use Durable.Helpers

    workflow "saga_across_queues" do
      step(:charge, [queue: :ocr, compensate: :refund], fn data ->
        {:ok, assign(data, :charged, true)}
      end)

      step(:ship, [queue: :llm], fn _data -> {:error, :down} end)

      compensate(:refund, fn data -> {:ok, assign(data, :refunded, true)} end)
    end
  end

  defmodule FailsUntilAllowed do
    use Durable

    workflow "fails_until_allowed" do
      step(:ocr, [queue: :ocr], fn data ->
        if Process.get(:allow_ocr), do: {:ok, data}, else: {:error, :down}
      end)

      step(:save, fn data -> {:ok, data} end)
    end
  end

  defmodule DecidesOnOcr do
    use Durable
    use Durable.Helpers

    workflow "decides_on_ocr" do
      decision(:route, [queue: :ocr], fn data -> {:goto, :finish, data} end)
      step(:skipped, [queue: :llm], fn data -> {:ok, assign(data, :skipped, true)} end)
      step(:finish, fn data -> {:ok, assign(data, :finished, true)} end)
    end
  end

  defmodule DebouncedOnOcr do
    use Durable

    workflow "debounced_on_ocr", debounce: [period: 50] do
      step(:ocr, [queue: :ocr], fn data -> {:ok, data} end)
    end
  end

  defmodule RunAgainOnOcr do
    use Durable

    workflow "run_again_on_ocr", on_duplicate: :run_again do
      step(:ocr, [queue: :ocr], fn data -> {:ok, data} end)
      step(:save, fn data -> {:ok, data} end)
    end
  end

  defmodule TimesOutOnOcr do
    use Durable

    workflow "times_out_on_ocr", timeout: hours(1) do
      step(:ocr, [queue: :ocr], fn data -> {:ok, data} end)
    end
  end

  defmodule ContextMoved do
    use Durable
    use Durable.Context
    use Durable.Helpers

    workflow "context_moved" do
      step(:first, [queue: :ocr], fn data ->
        put_context(:written, "by first")
        {:ok, assign(data, :returned, "by first")}
      end)

      step(:second, [queue: :llm], fn data ->
        {:ok, assign(data, :seen, [get_context(:written), data[:returned], input()])}
      end)
    end
  end

  defmodule ContextUnmoved do
    use Durable
    use Durable.Context
    use Durable.Helpers

    workflow "context_unmoved" do
      step(:first, fn data ->
        put_context(:written, "by first")
        {:ok, assign(data, :returned, "by first")}
      end)

      step(:second, fn data ->
        {:ok, assign(data, :seen, [get_context(:written), data[:returned], input()])}
      end)
    end
  end

  defp get(id), do: TestRepo.get!(WorkflowExecution, id)

  defp claim(queue), do: Postgres.fetch_jobs(Config.get(Durable), queue, 10, "test-node")

  # One claim on `queue`, and whatever that claim runs. Returns the reloaded run.
  defp advance(id, queue) do
    assert [%{id: ^id}] = claim(queue)
    Executor.execute_workflow(id, Config.get(Durable))
    get(id)
  end

  defp expire(id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    TestRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
      set: [deadline_at: past]
    )
  end

  defp live_node(queues) do
    now = DateTime.utc_now()
    %Node{id: "polling-node", queues: queues, version: "1", started_at: now, heartbeat_at: now}
  end

  defp ran(id) do
    TestRepo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^id and s.status == :completed,
        order_by: [asc: s.inserted_at],
        select: s.step_name
      )
    )
  end

  test "each step runs on its own queue, and a step without one goes back" do
    {:ok, id} = Durable.start(Import, %{"url" => "u"})
    assert get(id).queue == "documents"

    # The start's queue only hands it on: nothing has run yet.
    run = advance(id, "documents")
    assert {run.status, run.queue, run.home_queue} == {:pending, "downloads", "documents"}
    assert {:ok, %{home_queue: "documents"}} = Durable.Query.get_execution(id)
    assert ran(id) == []
    assert claim("documents") == []

    run = advance(id, "downloads")
    assert {run.status, run.queue, run.home_queue} == {:pending, "ocr", "documents"}
    assert ran(id) == ["download"]

    run = advance(id, "ocr")
    assert {run.status, run.queue, run.home_queue} == {:pending, "documents", nil}
    assert ran(id) == ["download", "ocr"]

    run = advance(id, "documents")
    assert run.status == :completed
    assert ran(id) == ["download", "ocr", "save"]
  end

  test "the steps see the data they would without the moves" do
    run = run_workflow(Import, %{"url" => "u"})

    assert run.status == :completed
    assert run.context["text"] == "u.pdf from u"
    assert run.context["saved"] == true
    refute Map.has_key?(run.context, "__atom_keys__")
  end

  test "it goes back to the queue the start named, not the workflow's" do
    {:ok, id} = Durable.start(Import, %{"url" => "u"}, queue: :urgent)

    assert advance(id, "urgent").home_queue == "urgent"
    advance(id, "downloads")
    assert advance(id, "ocr").queue == "urgent"
    assert advance(id, "urgent").status == :completed
  end

  test "a retry stays on the step's queue" do
    {:ok, id} = Durable.start(FlakyOcr, %{})
    assert advance(id, "default").queue == "ocr"

    run = advance(id, "ocr")
    assert {run.status, run.queue, run.home_queue} == {:pending, "ocr", "default"}

    assert drain(id).status == :completed
  end

  test "a step inside a branch moves, and the run keeps to its clause" do
    {:ok, id} = Durable.start(InBranch, %{})

    assert advance(id, "default").queue == "ocr"
    assert advance(id, "ocr").queue == "default"

    run = advance(id, "default")
    assert run.status == :completed
    assert %{"a1" => true, "a2" => true, "done" => true} = run.context
    refute Map.has_key?(run.context, "b1")
  end

  test "a parallel block after a moved step goes back first, so its branches do too" do
    {:ok, id} = Durable.start(ThenParallel, %{})

    advance(id, "default")
    advance(id, "ocr")
    assert get(id).queue == "default"
    advance(id, "default")

    queues =
      TestRepo.all(
        from(w in WorkflowExecution, where: w.parent_workflow_id == ^id, select: w.queue)
      )

    assert Enum.sort(queues) == ["default", "llm"]
    assert drain(id).status == :completed
  end

  describe "a retry, snooze or wait keeps the run on the step's queue" do
    test "a snooze" do
      {:ok, id} = Durable.start(SnoozesOnOcr, %{})
      advance(id, "default")

      run = advance(id, "ocr")
      assert {run.status, run.queue, run.home_queue} == {:pending, "ocr", "default"}
      assert ran(id) == []

      # The snooze's time hasn't come for the claim query in a sandbox
      # transaction, where NOW() stands still.
      Executor.execute_workflow(id, Config.get(Durable))
      run = get(id)
      assert {run.status, run.queue} == {:pending, "default"}
      assert ran(id) == ["ocr"]
    end

    test "a wait for an event, resumed on the step's queue" do
      {:ok, id} = Durable.start(WaitsOnOcr, %{})
      advance(id, "default")

      run = advance(id, "ocr")
      assert {run.status, run.queue, run.home_queue} == {:waiting, "ocr", "default"}

      :ok = Durable.send_event(id, "go", %{})
      assert claim("default") == []

      assert advance(id, "ocr").queue == "default"
      assert ran(id) == ["ocr"]
      assert advance(id, "default").status == :completed
    end

    test "a sleep" do
      {:ok, id} = Durable.start(SleepsOnOcr, %{})
      advance(id, "default")

      run = advance(id, "ocr")
      assert {run.status, run.queue, run.home_queue} == {:waiting, "ocr", "default"}
      assert drain(id).status == :completed
      assert ran(id) == ["ocr", "save"]
    end
  end

  test "compensations run where the run failed, in the same claim" do
    {:ok, id} = Durable.start(SagaAcrossQueues, %{})
    advance(id, "default")
    advance(id, "ocr")

    run = advance(id, "llm")
    assert {run.status, run.queue} == {:compensated, "llm"}
    assert "compensate_refund" in ran(id)
  end

  test "Durable.retry/2 resumes on the step's queue and still knows the way back" do
    {:ok, id} = Durable.start(FailsUntilAllowed, %{})
    advance(id, "default")

    run = advance(id, "ocr")
    assert {run.status, run.queue, run.home_queue} == {:failed, "ocr", "default"}

    Process.put(:allow_ocr, true)
    assert {:ok, ^id} = Durable.retry(id)
    assert claim("default") == []

    assert advance(id, "ocr").queue == "default"
    assert advance(id, "default").status == :completed
  end

  test "a decision moves like a step, and so does the step it jumps to" do
    {:ok, id} = Durable.start(DecidesOnOcr, %{})

    assert advance(id, "default").queue == "ocr"
    assert advance(id, "ocr").queue == "default"
    assert advance(id, "default").status == :completed
    assert ran(id) == ["route", "finish"]
  end

  test "a branch picks its clause where the run is, so it costs no move" do
    {:ok, id} = Durable.start(BranchStaysPut, %{})
    advance(id, "default")

    run = advance(id, "ocr")
    assert {run.status, run.queue} == {:completed, "ocr"}
    assert run.context["a1"] == true
  end

  test "a step on the queue the run is already on doesn't move it" do
    {:ok, id} = Durable.start(AlreadyThere, %{})

    run = advance(id, "ocr")
    assert {run.status, run.queue, run.home_queue} == {:completed, "ocr", nil}
  end

  test "the steps see the same data and context as a run that never moves" do
    moved = run_workflow(ContextMoved, %{"url" => "u"})
    unmoved = run_workflow(ContextUnmoved, %{"url" => "u"})

    assert moved.status == :completed
    assert moved.context["seen"] == unmoved.context["seen"]
    assert Enum.take(moved.context["seen"], 2) == ["by first", "by first"]
  end

  describe "a finished run" do
    test "keeps the last queue it was on, and queue filters see that" do
      run = run_workflow(EndsOnLlm, %{})
      assert {run.status, run.queue} == {:completed, "llm"}

      ids = fn queue -> Enum.map(Durable.list_executions(queue: queue), & &1.id) end
      assert run.id in ids.(:llm)
      refute run.id in ids.(:documents)
    end

    test "reruns on the queue it started on, not the last one" do
      run = run_workflow(EndsOnLlm, %{})
      assert {:ok, again} = Durable.rerun(run.id)

      new = get(again)
      assert {new.queue, new.home_queue} == {"documents", nil}
    end

    test "reruns on the queue its start named" do
      run = run_workflow(EndsOnLlm, %{}, queue: :urgent)
      assert run.queue == "llm"
      assert {:ok, again} = Durable.rerun(run.id)
      assert get(again).queue == "urgent"
    end
  end

  describe "keys" do
    test "a run on another queue still holds its key, with its input untouched" do
      {:ok, id} = Durable.start(Import, %{"url" => "u"}, key: "doc:1")
      advance(id, "documents")

      assert {:ok, ^id} = Durable.start(Import, %{"url" => "other"}, key: "doc:1")

      run = get(id)
      assert run.holds_key
      assert run.input == %{"url" => "u"}
      assert TestRepo.aggregate(WorkflowExecution, :count) == 1
    end

    test "a debounced start leaves a run that has moved queues alone" do
      {:ok, id} = Durable.start(DebouncedOnOcr, %{"v" => 1}, key: "k")
      Executor.execute_workflow(id, Config.get(Durable))
      assert get(id).queue == "ocr"

      assert {:ok, ^id} = Durable.start(DebouncedOnOcr, %{"v" => 2}, key: "k")

      run = get(id)
      assert {run.input, run.scheduled_at} == {%{"v" => 1}, nil}
    end

    test "run_again waits behind a holder that is between queues" do
      {:ok, holder} = Durable.start(RunAgainOnOcr, %{"v" => 1}, key: "k")
      advance(holder, "default")

      {:ok, waiting} = Durable.start(RunAgainOnOcr, %{"v" => 2}, key: "k")
      assert waiting != holder
      assert get(waiting).runs_after_id == holder
      assert get(holder).input == %{"v" => 1}
      assert claim("default") == []

      advance(holder, "ocr")
      assert advance(holder, "default").status == :completed

      assert advance(waiting, "default").queue == "ocr"
    end
  end

  test "a paused step queue holds the run until it's resumed" do
    {:ok, id} = Durable.start(QuickMoves, %{})
    Durable.pause_queue(:ocr)
    advance(id, "default")

    assert claim("ocr") == []

    Durable.resume_queue(:ocr)
    assert advance(id, "ocr").queue == "default"
  end

  test "a run on another queue can be cancelled" do
    {:ok, id} = Durable.start(QuickMoves, %{})
    advance(id, "default")

    assert :ok = Durable.cancel(id, "changed my mind")
    assert get(id).status == :cancelled
    assert claim("ocr") == []
  end

  test "a run coming back goes ahead of newer runs on that queue" do
    {:ok, older} = Durable.start(QuickMoves, %{})
    advance(older, "default")
    advance(older, "ocr")
    {:ok, _newer} = Durable.start(QuickMoves, %{})

    assert [%{id: ^older}] = Postgres.fetch_jobs(Config.get(Durable), "default", 1, "test-node")
  end

  test "inline: stops at the first move and leaves the rest to the queue" do
    {:ok, id} = Durable.start(Import, %{"url" => "u"}, inline: true)

    run = get(id)
    assert {run.status, run.queue} == {:pending, "downloads"}
    assert ran(id) == []
  end

  test "past its timeout, a run on a queue a live node polls waits for a claim to fail it" do
    worker = start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
    TestRepo.insert!(live_node(["default", "ocr"]))

    {:ok, id} = Durable.start(TimesOutOnOcr, %{})
    advance(id, "default")
    expire(id)

    send(worker, :check_timeouts)
    :sys.get_state(worker)
    assert get(id).status == :pending

    run = advance(id, "ocr")
    assert {run.status, run.error["type"]} == {:failed, "timeout"}
    assert ran(id) == []
  end

  test "past its timeout, a run on a queue nobody polls goes home and fails there" do
    worker = start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
    TestRepo.insert!(live_node(["default"]))

    {:ok, id} = Durable.start(TimesOutOnOcr, %{})
    advance(id, "default")
    expire(id)

    send(worker, :check_timeouts)
    :sys.get_state(worker)
    assert %{status: :pending, queue: "default", home_queue: nil} = get(id)

    run = advance(id, "default")
    assert {run.status, run.error["type"]} == {:failed, "timeout"}
    assert ran(id) == []
  end

  describe "with pollers" do
    @describetag :supervised

    test "every configured queue gets its own poller" do
      start_supervised_durable!(
        queues: %{
          default: [concurrency: 2, poll_interval: 50],
          ocr: [concurrency: 3, poll_interval: 50]
        }
      )

      assert Manager.status(Durable, "default").concurrency == 2
      assert Manager.status(Durable, "ocr").concurrency == 3
    end

    test "a queue no node polls holds the run: the queue it starts on" do
      start_supervised_durable!(queues: %{ocr: [concurrency: 1, poll_interval: 20]})

      {:ok, id} = Durable.start(QuickMoves, %{})
      Process.sleep(200)

      run = get(id)
      assert {run.status, run.queue} == {:pending, "default"}
      assert ran(id) == []
    end

    test "a queue no node polls holds the run: a step's queue" do
      start_supervised_durable!(queues: %{default: [concurrency: 1, poll_interval: 20]})

      {:ok, id} = Durable.start(QuickMoves, %{})
      assert_eventually(fn -> get(id).queue == "ocr" end)
      Process.sleep(200)

      run = get(id)
      assert {run.status, run.queue, run.home_queue} == {:pending, "ocr", "default"}
      assert ran(id) == []
    end

    test "with pubsub a move wakes the next queue, with no poll to wait for" do
      start_supervised_durable!(
        queues: %{
          default: [concurrency: 2, poll_interval: :timer.hours(1)],
          ocr: [concurrency: 2, poll_interval: :timer.hours(1)]
        }
      )

      # Let the first poll, at start, go by.
      Process.sleep(100)

      {:ok, id} = Durable.start(QuickMoves, %{})
      assert_eventually(fn -> get(id).status == :completed end)
    end

    test "without pubsub the next queue's poll finds it" do
      start_supervised_durable!(
        pubsub: nil,
        queues: %{
          default: [concurrency: 2, poll_interval: 20],
          ocr: [concurrency: 2, poll_interval: 20]
        }
      )

      {:ok, id} = Durable.start(QuickMoves, %{})
      assert_eventually(fn -> get(id).status == :completed end)
    end

    defp track_running do
      :ets.new(:step_queue_test, [:named_table, :public])
      :ets.insert(:step_queue_test, {:running, 0})
    end

    defp peak_running do
      :step_queue_test |> :ets.match({{:seen, :"$1"}}) |> List.flatten() |> Enum.max()
    end

    defp start_runs_and_finish(count) do
      ids =
        for _ <- 1..count do
          {:ok, id} = Durable.start(OneOcrAtATime, %{})
          id
        end

      assert_eventually(fn -> Enum.all?(ids, &(get(&1).status == :completed)) end, 15_000)
    end

    test "a step takes a slot from its own queue's concurrency" do
      track_running()

      start_supervised_durable!(
        queues: %{
          default: [concurrency: 5, poll_interval: 20],
          ocr: [concurrency: 1, poll_interval: 20]
        }
      )

      start_runs_and_finish(3)
      assert peak_running() == 1
    end

    test "concurrency is per node: each node's slots add up" do
      track_running()

      queues = %{
        default: [concurrency: 5, poll_interval: 20],
        ocr: [concurrency: 1, poll_interval: 20]
      }

      start_supervised_durable!(queues: queues)
      start_supervised_durable!(name: Durable.StepQueueTest.SecondNode, queues: queues)

      start_runs_and_finish(4)
      assert peak_running() == 2
    end

    test "a queue polled on one node only keeps its limit as a total" do
      track_running()

      start_supervised_durable!(
        queues: %{
          default: [concurrency: 5, poll_interval: 20],
          ocr: [concurrency: 1, poll_interval: 20]
        }
      )

      start_supervised_durable!(
        name: Durable.StepQueueTest.SecondNode,
        queues: %{default: [concurrency: 5, poll_interval: 20]}
      )

      start_runs_and_finish(3)
      assert peak_running() == 1
    end
  end
end
