defmodule Durable.OperatorControlsTest do
  @moduledoc """
  The 1.0 operator controls: retry a failed run from its failed step, rerun a
  finished run, pause a queue across the cluster, and record what started
  each run.
  """
  use Durable.DataCase, async: false
  use ExUnitProperties

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  import Durable.DataCase,
    only: [create_and_execute_workflow: 2, execute_children: 3, get_child_executions: 2]

  # Steps run inline in the test process, so the process dictionary is the
  # "outside world": `broken` makes a step raise, `ran` records each step that
  # actually ran its side effect.
  defmodule Flaky do
    @moduledoc false
    use Durable

    def act(i, data) do
      if Process.get({__MODULE__, :broken}) == i, do: raise("step #{i} is broken")
      Process.put({__MODULE__, :ran}, Process.get({__MODULE__, :ran}, []) ++ [i])
      {:ok, data}
    end

    workflow "flaky" do
      step(:s1, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
        __MODULE__.act(1, data)
      end)

      step(:s2, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
        __MODULE__.act(2, data)
      end)

      step(:s3, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
        __MODULE__.act(3, data)
      end)

      step(:s4, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
        __MODULE__.act(4, data)
      end)

      step(:s5, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
        __MODULE__.act(5, data)
      end)
    end
  end

  defmodule FlakyParallel do
    @moduledoc false
    use Durable

    workflow "flaky_parallel" do
      step(:setup, fn data -> Flaky.act(1, data) end)

      parallel do
        step(:left, fn data -> Flaky.act(2, data) end)
        step(:right, fn data -> Flaky.act(3, data) end)
      end

      step(:finish, fn data -> Flaky.act(4, data) end)
    end
  end

  defmodule Compensated do
    @moduledoc false
    use Durable

    workflow "compensated" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
      step(:fail, fn _data -> raise "nope" end)
      compensate(:unbook, fn data -> {:ok, data} end)
    end
  end

  setup do
    Process.delete({Flaky, :broken})
    Process.delete({Flaky, :ran})
    %{config: Config.get(Durable)}
  end

  defp reload(id), do: Config.get(Durable).repo.get!(WorkflowExecution, id)
  defp ran, do: Process.get({Flaky, :ran}, [])

  defp failed_attempts(id, step) do
    Config.get(Durable).repo.aggregate(
      from(s in StepExecution,
        where: s.workflow_id == ^id and s.step_name == ^step and s.status == :failed
      ),
      :count
    )
  end

  describe "retry/2" do
    test "resumes at the failed step without re-running completed steps", %{config: config} do
      Process.put({Flaky, :broken}, 3)
      {:ok, run} = create_and_execute_workflow(Flaky, %{})
      assert run.status == :failed
      assert ran() == [1, 2]
      assert failed_attempts(run.id, "s3") == 2

      Process.delete({Flaky, :broken})
      assert {:ok, _} = Durable.retry(run.id)
      assert reload(run.id).status == :pending

      Executor.execute_workflow(run.id, config)

      assert reload(run.id).status == :completed
      assert ran() == [1, 2, 3, 4, 5]
    end

    test "gives the failed step a fresh attempt budget", %{config: config} do
      Process.put({Flaky, :broken}, 2)
      {:ok, run} = create_and_execute_workflow(Flaky, %{})
      assert failed_attempts(run.id, "s2") == 2

      # Still broken: the retried step must get 2 more attempts, not 0.
      {:ok, _} = Durable.retry(run.id)
      Executor.execute_workflow(run.id, config)

      assert reload(run.id).status == :failed
      assert failed_attempts(run.id, "s2") == 4
    end

    test "in a parallel block re-queues only the children that failed", %{config: config} do
      repo = config.repo
      Process.put({Flaky, :broken}, 3)

      {:ok, parent} = create_and_execute_workflow(FlakyParallel, %{})
      execute_children(repo, parent.id, config)
      Executor.execute_workflow(parent.id, config)
      assert reload(parent.id).status == :failed
      assert ran() == [1, 2]

      Process.delete({Flaky, :broken})
      {:ok, _} = Durable.retry(parent.id)

      assert reload(parent.id).status == :waiting

      statuses = repo |> get_child_executions(parent.id) |> Enum.map(& &1.status) |> Enum.sort()
      assert statuses == [:completed, :pending]

      execute_children(repo, parent.id, config)
      assert reload(parent.id).status == :pending

      Executor.execute_workflow(parent.id, config)

      assert reload(parent.id).status == :completed
      # setup and the left branch ran once; only the failed right branch re-ran.
      assert ran() == [1, 2, 3, 4]
    end

    test "refuses rolled-back, unfinished and unknown runs" do
      {:ok, rolled_back} = create_and_execute_workflow(Compensated, %{})
      assert rolled_back.status == :compensated
      assert Durable.retry(rolled_back.id) == {:error, :rolled_back}

      {:ok, pending} = Durable.start(Flaky, %{})
      assert Durable.retry(pending) == {:error, :not_failed}

      assert Durable.retry(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  property "retrying a run that failed at any step never re-runs a completed step" do
    config = Config.get(Durable)

    check all(broken_at <- integer(1..5), max_runs: 25) do
      Process.put({Flaky, :ran}, [])
      Process.put({Flaky, :broken}, broken_at)

      {:ok, run} = create_and_execute_workflow(Flaky, %{})
      assert run.status == :failed
      assert ran() == Enum.to_list(1..(broken_at - 1)//1)

      Process.delete({Flaky, :broken})
      {:ok, _} = Durable.retry(run.id)
      Executor.execute_workflow(run.id, config)

      assert reload(run.id).status == :completed
      assert ran() == [1, 2, 3, 4, 5]
    end
  end

  describe "rerun/2" do
    test "starts a fresh run linked to the original, with its input or a new one" do
      {:ok, original} = create_and_execute_workflow(Flaky, %{"order" => 1})

      {:ok, same_input} = Durable.rerun(original.id)
      {:ok, new_input} = Durable.rerun(original.id, input: %{"order" => 2})

      for {id, input} <- [{same_input, %{"order" => 1}}, {new_input, %{"order" => 2}}] do
        run = reload(id)
        assert run.status == :pending
        assert run.input == input
        assert run.trigger == :rerun
        assert run.trigger_ref == original.id
      end
    end

    test "refuses runs that haven't finished" do
      {:ok, pending} = Durable.start(Flaky, %{})
      assert Durable.rerun(pending) == {:error, :not_finished}
    end
  end

  describe "pause_queue/2" do
    test "stops every node claiming from the queue until resumed", %{config: config} do
      {:ok, id} = Durable.start(Flaky, %{}, queue: "billing")

      :ok = Durable.pause_queue(:billing)
      assert Durable.paused_queues() == ["billing"]
      assert Postgres.fetch_jobs(config, "billing", 10, "node-a") == []

      :ok = Durable.resume_queue("billing")
      assert Durable.paused_queues() == []
      assert [%{id: ^id}] = Postgres.fetch_jobs(config, "billing", 10, "node-a")
    end

    test "leaves other queues alone", %{config: config} do
      {:ok, id} = Durable.start(Flaky, %{}, queue: "default")
      :ok = Durable.pause_queue("billing")

      assert [%{id: ^id}] = Postgres.fetch_jobs(config, "default", 10, "node-a")
    end
  end

  test "records what started each run" do
    {:ok, api} = Durable.start(Flaky, %{})
    assert %{trigger: :api, trigger_ref: nil} = reload(api)

    {:ok, _} = Durable.schedule(Flaky, "0 9 * * *", name: "nightly_flaky")
    {:ok, scheduled} = Durable.trigger_schedule("nightly_flaky")
    assert %{trigger: :schedule, trigger_ref: "nightly_flaky"} = reload(scheduled)
  end
end
