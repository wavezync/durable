defmodule Durable.ParkTest do
  @moduledoc """
  A retry or a snooze parks the run, freeing the worker, until its time comes.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  defmodule FailsOnce do
    use Durable
    use Durable.Helpers
    use Durable.Context

    workflow "fails_once", timeout: minutes(10) do
      step(
        :call,
        [retry: [max_attempts: 3, backoff: :constant, base: :timer.hours(1)]],
        fn data ->
          if attempt() == 1, do: {:error, :down}, else: {:ok, assign(data, :called, true)}
        end
      )
    end
  end

  defmodule FailsInBranch do
    use Durable
    use Durable.Helpers
    use Durable.Context

    workflow "fails_in_branch" do
      parallel do
        step(:flaky, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
          if attempt() == 1, do: {:error, :down}, else: {:ok, assign(data, :flaky, true)}
        end)

        step(:steady, fn data -> {:ok, assign(data, :steady, true)} end)
      end
    end
  end

  defmodule RetriesInBranch do
    use Durable
    use Durable.Helpers
    use Durable.Context

    workflow "retries_in_branch" do
      step(:start, fn data -> {:ok, assign(data, :path, "a")} end)

      branch on: fn data -> data[:path] || data["path"] end do
        "a" ->
          step(:a1, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
            if attempt() == 1, do: {:error, :down}, else: {:ok, assign(data, :a1, true)}
          end)

          step(:a2, fn data -> {:ok, assign(data, :a2, true)} end)

        "b" ->
          step(:b1, fn data -> {:ok, assign(data, :b1, true)} end)
      end

      step(:after_branch, fn data -> {:ok, assign(data, :after_branch, true)} end)
    end
  end

  defmodule SleepsInBranch do
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "sleeps_in_branch" do
      branch on: fn _data -> "a" end do
        "a" ->
          step(:a1, fn data ->
            sleep(1)
            {:ok, assign(data, :a1, true)}
          end)

          step(:a2, fn data -> {:ok, assign(data, :a2, true)} end)

        "b" ->
          step(:b1, fn data -> {:ok, assign(data, :b1, true)} end)
      end
    end
  end

  defmodule Snoozes do
    use Durable
    use Durable.Helpers

    workflow "snoozes" do
      step(:export, fn data ->
        case Process.get(:snoozes_left, 2) do
          0 ->
            {:ok, assign(data, :exported, true)}

          1 ->
            Process.put(:snoozes_left, 0)
            {:snooze, 50}

          n ->
            Process.put(:snoozes_left, n - 1)
            {:snooze, seconds(60), "another export is running"}
        end
      end)
    end
  end

  defp rows(id) do
    TestRepo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^id,
        order_by: [asc: s.inserted_at],
        select: {s.step_name, s.attempt, s.status}
      )
    )
  end

  test "a retry parks the run until its backoff has passed, no later than its deadline" do
    {:ok, id} = Durable.start(FailsOnce, %{})
    Executor.execute_workflow(id, Config.get(Durable))

    run = TestRepo.get!(WorkflowExecution, id)
    assert run.status == :pending
    assert run.locked_by == nil
    # The 1 hour backoff is cut to the run's 10 minute timeout.
    assert run.scheduled_at == run.deadline_at
    assert rows(id) == [{"call", 1, :failed}]

    run = drain(id)
    assert run.status == :completed
    assert rows(id) == [{"call", 1, :failed}, {"call", 2, :completed}]
  end

  test "a retry in a parallel step parks only that branch, which resumes as a branch" do
    run = run_workflow(FailsInBranch)

    assert run.status == :completed
    assert %{"flaky" => ["ok", _], "steady" => ["ok", _]} = run.context["__results__"]
  end

  test "a retry inside a branch goes on with its own clause, then past the block" do
    run = run_workflow(RetriesInBranch)

    assert run.status == :completed
    assert %{"a1" => true, "a2" => true, "after_branch" => true} = run.context
    refute Map.has_key?(run.context, "b1")
  end

  test "a sleep inside a branch goes on with its own clause" do
    run = run_workflow(SleepsInBranch)

    assert run.status == :completed
    assert %{"a1" => true, "a2" => true} = run.context
    refute Map.has_key?(run.context, "b1")
  end

  test "a snooze runs the step again later, without using an attempt" do
    :telemetry.attach(
      "park-test-snooze",
      [:durable, :step, :snooze],
      fn _event, measurements, meta, pid -> send(pid, {:snooze, measurements, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach("park-test-snooze") end)

    run = run_workflow(Snoozes)

    assert run.status == :completed

    assert rows(run.id) == [
             {"export", 1, :snoozed},
             {"export", 1, :snoozed},
             {"export", 1, :completed}
           ]

    [first, second, _] = steps(run)

    assert first.error == %{
             "type" => "snoozed",
             "message" => "another export is running",
             "snooze_ms" => 60_000
           }

    assert second.error == %{"type" => "snoozed", "snooze_ms" => 50}

    assert_received {:snooze, %{snooze_ms: 60_000},
                     %{reason: "another export is running", step: :export}}

    assert_received {:snooze, %{snooze_ms: 50}, %{reason: nil}}
  end
end
