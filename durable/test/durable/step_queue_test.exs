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
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

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
        if :ets.update_counter(:step_queue_test, :running, 1) > 1,
          do: :ets.insert(:step_queue_test, {:overlap, true})

        Process.sleep(40)
        :ets.update_counter(:step_queue_test, :running, -1)
        {:ok, data}
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

  describe "with pollers" do
    @describetag :supervised

    test "a step takes a slot from its own queue's concurrency" do
      :ets.new(:step_queue_test, [:named_table, :public])
      :ets.insert(:step_queue_test, {:running, 0})

      start_supervised_durable!(
        queues: %{
          default: [concurrency: 5, poll_interval: 50],
          ocr: [concurrency: 1, poll_interval: 50]
        }
      )

      ids =
        for _ <- 1..3 do
          {:ok, id} = Durable.start(OneOcrAtATime, %{})
          id
        end

      assert_eventually(fn -> Enum.all?(ids, &(get(&1).status == :completed)) end)
      assert :ets.lookup(:step_queue_test, :overlap) == []
    end
  end
end
