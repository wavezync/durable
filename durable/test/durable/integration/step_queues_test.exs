defmodule Durable.Integration.StepQueuesTest do
  @moduledoc """
  A step's `queue:` with real pollers, workers, commits and the real clock.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Wait.TimeoutWorker

  @all_queues %{default: 5, documents: 5, downloads: 2, ocr: 1, llm: 2}

  defp steps_of(id) do
    IntegrationRepo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^id,
        order_by: [asc: s.inserted_at],
        select: {s.step_name, s.attempt, s.status}
      )
    )
  end

  defp start!(workflow, input \\ %{}, opts \\ []) do
    {:ok, id} = Durable.start(workflow, input, opts)
    id
  end

  defp await_hit(label, count \\ 1) do
    assert_eventually(fn -> Probe.hits(label) >= count end)
  end

  describe "a run across queues" do
    setup do
      start_durable!(@all_queues)
      :ok
    end

    test "runs each step on its own queue, then finishes back where it started" do
      id = start!(W.Pipeline, %{"url" => "u"})

      run = await_status(id, :completed)

      assert Probe.trail() == [
               {:download, "downloads"},
               {:ocr, "ocr"},
               {:summarize, "llm"},
               {:save, "documents"}
             ]

      assert {run.queue, run.home_queue} == {"documents", nil}
      assert run.context["summary"] == "summary of text of u.pdf"
    end

    test "a run scheduled for later waits, then crosses its queues" do
      at = DateTime.add(DateTime.utc_now(), 500, :millisecond)
      id = start!(W.Pipeline, %{"url" => "u"}, scheduled_at: at)

      Process.sleep(200)
      assert get(id).status == :pending
      assert Probe.trail() == []

      await_status(id, :completed)
      assert length(Probe.trail()) == 4
    end

    test "a parallel block goes back first, and each branch runs on its own queue" do
      id = start!(W.Parallel)

      run = await_status(id, :completed)
      trail = Probe.trail()

      assert List.first(trail) == {:prepare, "ocr"}
      assert List.last(trail) == {:finish, "documents"}
      assert {:on_llm, "llm"} in trail
      assert {:on_downloads, "downloads"} in trail
      assert {:plain, "documents"} in trail
      assert run.queue == "documents"
    end

    test "a real retry inside a branch stays on the clause and on the step's queue" do
      id = start!(W.BranchRetry)

      await_status(id, :completed)

      assert Probe.trail() == [
               {:start, "default"},
               {:a1, "ocr"},
               {:a1, "ocr"},
               {:a2, "default"},
               {:done, "llm"}
             ]
    end

    test "a decision and the step it jumps to each run on their queue" do
      id = start!(W.Decides)

      await_status(id, :completed)
      assert Probe.trail() == [{:route, "ocr"}, {:finish, "default"}]
    end

    test "a child workflow crosses its own queues while its parent waits on the step's queue" do
      id = start!(W.Parent)

      run = await_status(id, :completed)

      assert Probe.trail() == [
               {:delegate, "ocr"},
               {:child_work, "llm"},
               {:delegate, "ocr"},
               {:finish, "documents"}
             ]

      assert run.context["delegated"] == true
    end

    test "a step's own timeout stops it and retries it on that queue" do
      id = start!(W.StepTimeoutOnOcr)

      await_status(id, :completed)
      assert Probe.trail() == [{:timed, "ocr"}, {:timed, "ocr"}, {:save, "default"}]
    end
  end

  describe "the step's queue slot" do
    setup do
      start_durable!(@all_queues)
      :ok
    end

    test "is free during a real retry backoff, so another run gets it" do
      flaky = start!(W.FlakyOnOcr)
      await_hit(:flaky)
      quick = start!(W.QuickOnOcr)

      await_status(quick, :completed)
      assert get(flaky).status == :pending
      assert Probe.hits(:flaky) == 1

      await_status(flaky, :completed)

      assert Probe.trail() == [
               {:flaky, "ocr"},
               {:quick, "ocr"},
               {:flaky, "ocr"},
               {:save, "default"}
             ]

      assert steps_of(flaky) == [
               {"ocr", 1, :failed},
               {"ocr", 2, :completed},
               {"save", 1, :completed}
             ]
    end

    test "is free during a real snooze, so another run gets it" do
      snoozy = start!(W.SnoozesOnOcr)
      await_hit(:snoozy)
      quick = start!(W.QuickOnOcr)

      await_status(quick, :completed)
      assert Probe.hits(:snoozy) == 1

      await_status(snoozy, :completed)

      assert Probe.trail() == [
               {:snoozy, "ocr"},
               {:quick, "ocr"},
               {:snoozy, "ocr"},
               {:save, "default"}
             ]
    end

    test "is free during a sleep, which the waker ends on the step's queue" do
      id = start!(W.SleepsOnOcr)
      await_hit(:before_sleep)
      quick = start!(W.QuickOnOcr)

      await_status(quick, :completed)
      await_status(id, :completed)

      assert Enum.reject(Probe.trail(), &(&1 == {:quick, "ocr"})) == [
               {:before_sleep, "ocr"},
               {:before_sleep, "ocr"},
               {:after_sleep, "ocr"},
               {:save, "default"}
             ]
    end

    test "is free during an event wait, and the event resumes the step there" do
      id = start!(W.WaitsOnOcr)
      assert_eventually(fn -> get(id).status == :waiting end)
      assert {get(id).queue, get(id).home_queue} == {"ocr", "default"}

      quick = start!(W.QuickOnOcr)
      await_status(quick, :completed)

      :ok = Durable.send_event(id, "go", %{"ok" => true})

      run = await_status(id, :completed)
      assert run.queue == "default"
      assert {:save, "default"} == List.last(Probe.trail())
      assert run.context["event"] == %{"ok" => true}
    end

    test "is free during an input wait, and the answer resumes the step there" do
      id = start!(W.AsksOnOcr)
      assert_eventually(fn -> get(id).status == :waiting end)
      assert get(id).queue == "ocr"

      :ok = Durable.provide_input(id, "approve", %{"yes" => true})

      run = await_status(id, :completed)
      assert run.context["answer"] == %{"yes" => true}
      assert Probe.trail() |> Enum.take(-2) == [{:asking, "ocr"}, {:save, "default"}]
    end

    test "goes back when a waiting run is cancelled" do
      id = start!(W.WaitsOnOcr)
      assert_eventually(fn -> get(id).status == :waiting end)

      assert :ok = Durable.cancel(id, "changed my mind")
      assert get(id).status == :cancelled

      quick = start!(W.QuickOnOcr)
      await_status(quick, :completed)
      assert Probe.hits(:save) == 0
    end
  end

  describe "when a step fails" do
    setup do
      start_durable!(@all_queues)
      :ok
    end

    test "compensations run where it failed" do
      id = start!(W.Saga)

      run = await_status(id, :compensated)

      assert run.queue == "llm"
      assert Probe.trail() == [{:charge, "ocr"}, {:ship, "llm"}, {:refund, "llm"}]
    end

    test "Durable.retry/2 resumes on the step's queue and finishes back home" do
      id = start!(W.FailsUntilAllowed)
      run = await_status(id, :failed)
      assert {run.queue, run.home_queue} == {"ocr", "documents"}

      :ok = Probe.set(:allow)
      assert {:ok, ^id} = Durable.retry(id)

      run = await_status(id, :completed)
      assert {run.queue, run.home_queue} == {"documents", nil}
      assert Probe.trail() == [{:ocr, "ocr"}, {:ocr, "ocr"}, {:save, "documents"}]
    end

    test "Durable.rerun/2 starts from the start queue and crosses them again" do
      first = start!(W.EndsOnLlm)
      assert await_status(first, :completed).queue == "llm"

      assert {:ok, second} = Durable.rerun(first)
      assert await_status(second, :completed).home_queue == "documents"
      assert Probe.trail() == [{:summarize, "llm"}, {:summarize, "llm"}]
    end
  end

  describe "keys" do
    setup do
      start_durable!(@all_queues)
      :ok
    end

    test "run_again leaves one run behind a holder on a step's queue, with the newest input" do
      holder = start!(W.RunAgain, %{"v" => 1}, key: "k")
      await_hit({:work, 1})

      waiting = start!(W.RunAgain, %{"v" => 2}, key: "k")
      assert ^waiting = start!(W.RunAgain, %{"v" => 3}, key: "k")

      Process.sleep(150)
      assert get(waiting).status == :pending
      assert Probe.hits({:work, 3}) == 0

      :ok = Probe.set({:go, 1})
      await_status(holder, :completed)

      await_hit({:work, 3})
      assert get(waiting).holds_key
      :ok = Probe.set({:go, 3})
      await_status(waiting, :completed)

      assert Probe.hits({:work, 2}) == 0
      assert Probe.hits({:save, 3}) == 1
    end

    test "a debounced run takes the newest input once, then crosses its queue" do
      id = start!(W.Debounced, %{"v" => 1}, key: "k")
      Process.sleep(100)
      assert ^id = start!(W.Debounced, %{"v" => 2}, key: "k")

      await_status(id, :completed)
      assert Probe.trail() == [{{:debounced, 2}, "ocr"}]
    end
  end

  describe "pausing a step's queue" do
    setup do
      start_durable!(@all_queues)
      :ok
    end

    test "holds runs there until it's resumed" do
      Durable.pause_queue(:ocr)
      id = start!(W.Pipeline, %{"url" => "u"})

      await_hit(:download)
      assert_eventually(fn -> get(id).queue == "ocr" end)
      Process.sleep(200)
      assert get(id).status == :pending
      assert Probe.hits(:ocr) == 0

      Durable.resume_queue(:ocr)
      await_status(id, :completed)
    end

    test "keeps a run past its timeout until it's resumed, and the claim fails it" do
      Durable.pause_queue(:ocr)
      id = start!(W.TimesOutOnOcr)

      assert_eventually(fn -> get(id).queue == "ocr" end)
      Process.sleep(350)
      sweep()
      assert get(id).status == :pending

      Durable.resume_queue(:ocr)

      run = await_status(id, :failed)
      assert run.error["type"] == "timeout"
      assert Probe.hits(:timed_ocr) == 0
    end
  end

  describe "timeouts" do
    setup do
      start_durable!(@all_queues)
      :ok
    end

    test "a run stuck on a queue nobody polls fails from the sweep, and compensates" do
      id = start!(W.StuckSaga)
      assert_eventually(fn -> get(id).queue == "nobody" end)
      assert get(id).status == :pending

      Process.sleep(350)
      sweep()

      run = await_status(id, :compensated)
      assert run.error["type"] == "timeout"
      assert Probe.trail() == [{:reserve, "default"}, {:release, "nobody"}]
    end

    test "a run that runs out of time on one queue never reaches the next" do
      id = start!(W.OutOfTime)

      run = await_status(id, :failed)
      assert run.error["type"] == "timeout"
      assert Probe.hits(:never) == 0
    end
  end

  test "a burst keeps every queue under its limit, and each step runs exactly once" do
    limits = %{documents: 10, downloads: 4, ocr: 2, llm: 3}
    start_durable!(limits)

    ids = for n <- 1..30, do: start!(W.Burst, %{"n" => n})

    assert_eventually(
      fn -> Enum.all?(ids, &(get(&1).status == :completed)) end,
      30_000,
      50
    )

    assert Probe.peak(:a) in 2..4
    assert Probe.peak(:b) == 2
    assert Probe.peak(:c) in 2..3

    for n <- 1..30, step <- [:a, :b, :c, :d] do
      assert Probe.hits({step, n}) == 1, "#{step} of run #{n} ran #{Probe.hits({step, n})} times"
    end
  end

  defp sweep do
    TimeoutWorker.check_timeouts(Durable)
    :sys.get_state(TimeoutWorker.worker_name(Durable))
  end
end
