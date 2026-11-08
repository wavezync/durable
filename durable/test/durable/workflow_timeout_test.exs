defmodule Durable.WorkflowTimeoutTest do
  @moduledoc """
  A workflow's `timeout:` is a deadline for the whole run, waits included.
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Storage.Schemas.{Node, PendingInput, StepExecution, WorkflowExecution}
  alias Durable.Wait.TimeoutWorker

  defmodule SlowSaga do
    use Durable
    use Durable.Helpers

    workflow "slow_saga", timeout: 50, queue: :sagas do
      step(:reserve, [compensate: :release], fn data -> {:ok, assign(data, :reserved, true)} end)

      step(:charge, fn data ->
        Process.sleep(1_000)
        {:ok, assign(data, :charged, true)}
      end)

      compensate(:release, fn data -> {:ok, assign(data, :released, true)} end)
    end
  end

  defmodule Approval do
    use Durable
    use Durable.Context
    use Durable.Wait

    workflow "timed_approval", timeout: minutes(30) do
      step(:ask, fn data ->
        wait_for_approval("manager")
        {:ok, data}
      end)
    end
  end

  defmodule Timed do
    use Durable
    use Durable.Context
    use Durable.Helpers

    require Logger

    workflow "timed", timeout: minutes(1) do
      step(:remember, fn data ->
        put_context(:note, "kept")
        Logger.info("remembering")
        {:ok, data}
      end)

      step(:fetch, [timeout: 20, retry: [max_attempts: 2, base: 1]], fn data ->
        calls = Process.get(:fetch_calls, 0) + 1
        Process.put(:fetch_calls, calls)
        if calls == 1, do: Process.sleep(1_000)
        {:ok, assign(data, :note, get_context(:note))}
      end)
    end
  end

  defmodule Ask do
    use Durable
    use Durable.Wait

    workflow "ask" do
      step(:ask, fn data ->
        wait_for_input("ok", timeout: hours(1), on_timeout: :fail)
        {:ok, data}
      end)
    end
  end

  defmodule StuckSaga do
    use Durable
    use Durable.Helpers

    workflow "stuck_saga", timeout: hours(1) do
      step(:reserve, [compensate: :release], fn data -> {:ok, assign(data, :reserved, true)} end)
      step(:charge, [queue: :nobody], fn data -> {:ok, assign(data, :charged, true)} end)
      compensate(:release, fn data -> {:ok, assign(data, :released, true)} end)
    end
  end

  defmodule StuckRaisingSaga do
    use Durable

    workflow "stuck_raising_saga", timeout: hours(1) do
      step(:reserve, [compensate: :release], fn data -> {:ok, data} end)
      step(:charge, [queue: :nobody], fn data -> {:ok, data} end)
      compensate(:release, fn _data -> raise "boom" end)
    end
  end

  defmodule StuckBranch do
    use Durable
    use Durable.Helpers

    workflow "stuck_branch", timeout: hours(1) do
      parallel do
        step(:stuck, [queue: :nobody], fn data -> {:ok, assign(data, :stuck, true)} end)
      end
    end
  end

  defp repo, do: Config.get(Durable).repo
  defp run(id), do: repo().get!(WorkflowExecution, id)

  test "options are evaluated: timeout: minutes(30) is a number of milliseconds" do
    {:ok, definition} = Approval.__workflow_definition__("timed_approval")
    assert definition.opts.timeout == 30 * 60_000
  end

  test "an unknown workflow option fails the compile" do
    assert_raise ArgumentError, ~r/unknown option\(s\) \[:max_retries\]/, fn ->
      Code.compile_string("""
      defmodule Durable.WorkflowTimeoutTest.Bad do
        use Durable
        workflow "bad", max_retries: 3 do
          step(:a, fn data -> {:ok, data} end)
        end
      end
      """)
    end
  end

  test "step options are evaluated too: timeout: seconds(1) is a number" do
    defmodule Opts do
      use Durable

      workflow "opts" do
        step(:a, [timeout: seconds(1), retry: [base: seconds(2)]], fn data -> {:ok, data} end)
      end
    end

    {:ok, %{steps: [step]}} = Opts.__workflow_definition__("opts")
    assert step.opts == %{timeout: 1_000, retry: %{base: 2_000}}
  end

  test "the deadline stops a step that is still running, then compensates" do
    {micros, {:ok, id}} =
      :timer.tc(fn -> Executor.start_workflow(SlowSaga, %{}, inline: true) end)

    run = run(id)

    assert micros < 500_000
    assert run.queue == "sagas"
    assert run.status == :compensated

    assert run.error == %{
             "type" => "timeout",
             "message" => "the run passed its timeout during charge"
           }

    refute run.context["charged"]
  end

  test "a step past its own timeout is stopped and retried" do
    {:ok, id} = Executor.start_workflow(Timed, %{}, inline: true)
    # The first attempt runs inline; the retry was parked for the queue.
    assert run(id).status == :pending
    run = Durable.DataCase.execute_while_pending(id)

    assert run.status == :completed
    # put_context and logs inside a time-limited step reach the run
    assert run.context["note"] == "kept"

    [remember, first, second] =
      repo().all(from(s in StepExecution, where: s.workflow_id == ^id, order_by: s.inserted_at))

    assert [%{"message" => "remembering"}] = remember.logs
    assert first.error["message"] == "fetch took longer than its 20ms timeout"
    assert {first.attempt, second.attempt, second.status} == {1, 2, :completed}
  end

  test "an input wait with on_timeout: :fail fails the run, and a retry waits again" do
    {:ok, id} = Executor.start_workflow(Ask, %{}, inline: true)
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    repo().update_all(from(p in PendingInput, where: p.workflow_id == ^id),
      set: [timeout_at: past]
    )

    start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
    TimeoutWorker.check_timeouts(Durable)
    :sys.get_state(TimeoutWorker.worker_name(Durable))
    Executor.execute_workflow(id, Config.get(Durable))

    assert %{status: :failed, error: %{"message" => "Timeout waiting for input: ok"}} = run(id)

    {:ok, ^id} = Durable.retry(id)
    Executor.execute_workflow(id, Config.get(Durable))
    assert %{status: :waiting} = run(id)
  end

  test "a waiting run past its deadline is woken and failed" do
    {:ok, id} = Executor.start_workflow(Approval, %{}, inline: true)
    assert %{status: :waiting, deadline_at: %DateTime{}} = run(id)

    past = DateTime.add(DateTime.utc_now(), -1, :second)
    repo().update_all(from(w in WorkflowExecution, where: w.id == ^id), set: [deadline_at: past])
    repo().insert!(polling_node(["default"]))

    start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
    TimeoutWorker.check_timeouts(Durable)
    :sys.get_state(TimeoutWorker.worker_name(Durable))

    assert %{status: :pending} = run(id)

    assert [%{status: :timeout}] =
             repo().all(from(p in PendingInput, where: p.workflow_id == ^id))

    Executor.execute_workflow(id, Config.get(Durable))
    assert %{status: :failed, error: %{"type" => "timeout"}} = run(id)
  end

  describe "a pending run past its deadline" do
    setup do
      start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
      :ok
    end

    defp polling_node(queues, seen_ago_s \\ 0) do
      seen = DateTime.add(DateTime.utc_now(), -seen_ago_s, :second)
      %Node{id: "other-node", queues: queues, version: "1", started_at: seen, heartbeat_at: seen}
    end

    defp sweep do
      TimeoutWorker.check_timeouts(Durable)
      :sys.get_state(TimeoutWorker.worker_name(Durable))
    end

    defp expire(id, ago_s \\ 1) do
      past = DateTime.add(DateTime.utc_now(), -ago_s, :second)

      repo().update_all(from(w in WorkflowExecution, where: w.id == ^id),
        set: [deadline_at: past]
      )
    end

    defp stuck_on_nobody(workflow \\ StuckSaga) do
      {:ok, id} = Durable.start(workflow, %{})
      Executor.execute_workflow(id, Config.get(Durable))
      assert %{status: :pending, queue: "nobody"} = run(id)
      id
    end

    defp steps_of(id) do
      repo().all(
        from(s in StepExecution,
          where: s.workflow_id == ^id,
          order_by: [asc: s.inserted_at],
          select: {s.step_name, s.status}
        )
      )
    end

    defp claim(id), do: Executor.execute_workflow(id, Config.get(Durable))

    test "on a queue no node polls, goes back to its own and compensates there" do
      id = stuck_on_nobody()
      repo().insert!(polling_node(["default"]))
      expire(id)
      sweep()

      assert %{status: :pending, queue: "default", home_queue: nil} = run(id)

      claim(id)
      assert %{status: :compensated, error: %{"type" => "timeout"}} = run(id)

      assert steps_of(id) == [
               {"reserve", :completed},
               {"compensate_release", :completed}
             ]
    end

    test "on a queue a live node polls, waits for the claim" do
      id = stuck_on_nobody()
      repo().insert!(polling_node(["nobody"]))
      expire(id)
      sweep()

      assert %{status: :pending, queue: "nobody"} = run(id)
    end

    test "on a queue only a missing node polled, moves" do
      id = stuck_on_nobody()
      repo().insert!(%{polling_node(["nobody"], 60) | id: "missing-node"})
      repo().insert!(polling_node(["default"]))
      expire(id)
      sweep()

      assert %{status: :pending, queue: "default"} = run(id)
    end

    test "with no live poller anywhere, stays until one shows up" do
      id = stuck_on_nobody()
      expire(id)
      sweep()

      assert %{status: :pending, queue: "nobody"} = run(id)
    end

    test "when its own queue isn't polled either, goes to \"default\" before any other" do
      {:ok, id} = Durable.start(StuckSaga, %{}, queue: "gone")
      repo().insert!(polling_node(["other", "default"]))
      expire(id)
      sweep()

      assert %{status: :pending, queue: "default", home_queue: "gone"} = run(id)
    end

    test "with neither its own queue nor \"default\" polled, goes to one that is" do
      {:ok, id} = Durable.start(StuckSaga, %{}, queue: "gone")
      repo().insert!(polling_node(["other"]))
      expire(id)
      sweep()

      assert %{status: :pending, queue: "other", home_queue: "gone"} = run(id)
    end

    test "parked for a retry or snooze far off, is claimable right away" do
      id = stuck_on_nobody()
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      repo().update_all(from(w in WorkflowExecution, where: w.id == ^id),
        set: [scheduled_at: later]
      )

      repo().insert!(polling_node(["default"]))
      expire(id)
      sweep()

      assert %{status: :pending, queue: "default", scheduled_at: nil} = run(id)
    end

    test "before its deadline, stays on the queue" do
      id = stuck_on_nobody()
      sweep()

      assert %{status: :pending, queue: "nobody"} = run(id)
    end

    test "that never started fails before its first step" do
      {:ok, id} = Durable.start(StuckSaga, %{})
      repo().insert!(polling_node(["other"]))
      expire(id)
      sweep()
      claim(id)

      assert %{status: :failed, error: %{"type" => "timeout"}} = run(id)
      assert steps_of(id) == []
    end

    test "a compensation that raises ends the run :compensation_failed" do
      id = stuck_on_nobody(StuckRaisingSaga)
      repo().insert!(polling_node(["default"]))
      expire(id)
      sweep()
      claim(id)

      assert %{status: :compensation_failed} = run(id)
    end

    for module <- ["Elixir.Enum", "Elixir.NoSuchWorkflowAnywhere"] do
      test "whose code this node doesn't have (#{module}) stays, and the sweep goes on" do
        unknown =
          repo().insert!(%WorkflowExecution{
            workflow_module: unquote(module),
            workflow_name: "gone",
            status: :pending,
            queue: "nobody",
            input: %{},
            context: %{},
            deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)
          })

        id = stuck_on_nobody()
        repo().insert!(polling_node(["default"]))
        expire(id)
        sweep()

        assert %{status: :pending, queue: "nobody"} = run(unknown.id)
        assert %{status: :pending, queue: "default"} = run(id)
      end
    end

    test "that a worker has claimed in the meantime is left to it" do
      id = stuck_on_nobody()
      config = Config.get(Durable)
      [%{lock_token: token}] = Postgres.fetch_jobs(config, "nobody", 1, "worker-node")
      expire(id)

      Executor.expire_unclaimed(id, ["default"], config)

      assert %{status: :running, queue: "nobody", locked_by: "worker-node", lock_token: ^token} =
               run(id)
    end

    test "a parallel branch is not run or failed by itself" do
      {:ok, parent} = Durable.start(StuckBranch, %{})
      Executor.execute_workflow(parent, Config.get(Durable))
      assert %{status: :waiting} = run(parent)

      [child] =
        repo().all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^parent))

      repo().insert!(polling_node(["default"]))
      expire(child.id)
      sweep()

      assert %{status: :pending, queue: "nobody"} = run(child.id)
      assert steps_of(child.id) == []
    end

    test "a parent past its deadline fails and cancels a branch stuck on a queue" do
      {:ok, parent} = Durable.start(StuckBranch, %{})
      Executor.execute_workflow(parent, Config.get(Durable))

      [child] =
        repo().all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^parent))

      repo().insert!(polling_node(["default"]))
      expire(parent)
      expire(child.id)
      sweep()
      claim(parent)

      assert %{status: :failed, error: %{"type" => "timeout"}} = run(parent)
      assert %{status: :cancelled} = run(child.id)
      assert steps_of(child.id) == []
    end
  end

  test "a resumed run keeps its first start time" do
    {:ok, id} = Executor.start_workflow(Approval, %{}, inline: true)
    %{status: :waiting, started_at: %DateTime{} = first} = run(id)

    :ok = Durable.provide_input(id, "manager", %{"approved" => true})
    Executor.execute_workflow(id, Config.get(Durable))

    assert %{status: :completed, started_at: ^first} = run(id)
  end

  test "a retried run gets its full timeout again" do
    {:ok, id} = Executor.start_workflow(SlowSaga, %{}, inline: true)
    repo().update_all(from(w in WorkflowExecution, where: w.id == ^id), set: [status: :failed])

    before = DateTime.utc_now()
    {:ok, ^id} = Durable.retry(id)

    assert DateTime.diff(run(id).deadline_at, before, :millisecond) in 40..60
  end
end
