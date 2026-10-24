defmodule Durable.WorkflowTimeoutTest do
  @moduledoc """
  A workflow's `timeout:` is a deadline for the whole run, waits included.
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{PendingInput, StepExecution, WorkflowExecution}
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
    run = run(id)

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

    start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
    TimeoutWorker.check_timeouts(Durable)
    :sys.get_state(TimeoutWorker.worker_name(Durable))

    assert %{status: :pending} = run(id)

    assert [%{status: :timeout}] =
             repo().all(from(p in PendingInput, where: p.workflow_id == ^id))

    Executor.execute_workflow(id, Config.get(Durable))
    assert %{status: :failed, error: %{"type" => "timeout"}} = run(id)
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
