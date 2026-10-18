defmodule Durable.WorkflowTimeoutTest do
  @moduledoc """
  A workflow's `timeout:` is a deadline for the whole run, waits included.
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{PendingInput, WorkflowExecution}
  alias Durable.Wait.TimeoutWorker

  defmodule SlowSaga do
    use Durable
    use Durable.Helpers

    workflow "slow_saga", timeout: 50, queue: :sagas do
      step(:reserve, [compensate: :release], fn data ->
        Process.sleep(80)
        {:ok, assign(data, :reserved, true)}
      end)

      step(:charge, fn data -> {:ok, assign(data, :charged, true)} end)

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

  test "a run past its deadline fails before the next step and compensates" do
    {:ok, id} = Executor.start_workflow(SlowSaga, %{}, inline: true)
    run = run(id)

    assert run.queue == "sagas"
    assert run.status == :compensated
    assert %{"type" => "timeout", "message" => message} = run.error
    assert message =~ "50ms timeout before charge"
    refute run.context["charged"]
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
