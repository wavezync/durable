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
      step(:work, fn data ->
        case wait_for_event("go") do
          %{"fail" => true} -> {:fail, "broken"}
          _ -> {:ok, data}
        end
      end)
    end
  end

  defmodule RebuildAfterFailure do
    use Durable
    use Durable.Wait

    workflow "rebuild_after_failure", on_duplicate: :run_again, reuse: :after_failure do
      step(:work, fn data ->
        wait_for_event("go")
        {:ok, data}
      end)
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

    # The claim query leaves it alone while the holder is open...
    assert claim() == []

    assert finish(holder).status == :completed

    # ...and claims it once the holder has ended. It takes the key.
    assert [%{id: ^waiting}] = claim()
    Executor.execute_workflow(waiting, Config.get(Durable))

    run = get(waiting)
    assert {run.status, run.holds_key, run.runs_after_id} == {:waiting, true, nil}
    refute get(holder.id).holds_key
  end

  test "a failed holder still lets the waiting run go, as reuse: :after_close does" do
    holder = run_workflow(Rebuild, %{"v" => 1}, key: "k")
    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "k")

    assert finish(holder, %{"fail" => true}).status == :failed
    assert drain(waiting).holds_key
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

  test "if another run took the key meanwhile, the waiting run waits behind that one" do
    first = run_workflow(Rebuild, %{}, key: "k")
    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "k")
    finish(first)

    {:ok, second} = Durable.start(Rebuild, %{"v" => 3}, key: "k", on_duplicate: :use_existing)
    refute second in [first.id, waiting]

    Executor.execute_workflow(waiting, Config.get(Durable))
    run = get(waiting)
    assert {run.status, run.runs_after_id, run.holds_key} == {:pending, second, false}
  end

  test "run_again with reuse: :never fails the compile" do
    assert_raise ArgumentError, ~r/reuse: :never/, fn ->
      defmodule NeverAgain do
        use Durable

        workflow "never_again", on_duplicate: :run_again, reuse: :never do
          step(:a, fn data -> {:ok, data} end)
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
