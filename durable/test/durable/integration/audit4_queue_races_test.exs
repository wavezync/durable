defmodule Audit4QueueRaceOnce do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit4_queue_race_once" do
    step :work, fn data ->
      Probe.note(:once)
      {:ok, data}
    end
  end
end

defmodule Durable.Integration.Audit4QueueRacesTest do
  @moduledoc """
  Audit 4: two parties after one run at the same moment, on real connections:
  a heartbeat and the stale sweep, two sweeps, a claim and a cancel. And wakes
  that never arrive.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.Config
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Queue.CommitWaker
  alias Durable.Queue.Worker
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.ScheduledWorkflow

  @rounds 30

  defp start_idle!(opts \\ []) do
    Durable.DataCase.start_supervised_durable!(
      [repo: IntegrationRepo, queue_enabled: false] ++ opts
    )

    Config.get(Durable)
  end

  # A run claimed on a queue of its own, with a lock an hour old.
  defp stale_claim!(config, round) do
    queue = "race_#{round}"
    {:ok, id} = Durable.start(Audit4QueueRaceOnce, %{}, queue: queue)
    [job] = Postgres.fetch_jobs(config, queue, 1, "node-a")

    {1, _} =
      IntegrationRepo.update_all(
        from(w in WorkflowExecution, where: w.id == ^id),
        set: [locked_at: DateTime.add(DateTime.utc_now(), -3_600, :second)]
      )

    job
  end

  defp claim_all(config, claimed \\ []) do
    case Postgres.fetch_jobs(config, "default", 3, "node-a") do
      [] -> claimed
      jobs -> claim_all(config, jobs ++ claimed)
    end
  end

  def forward_stop(_event, _measurements, meta, pid),
    do: send(pid, {:attempt_ended, meta.step_execution_id})

  test "the stale sweep racing a live worker's heartbeat: one of them gets the run, never both" do
    config = start_idle!()

    for round <- 1..@rounds do
      job = stale_claim!(config, round)

      heartbeat = Task.async(fn -> Postgres.heartbeat(config, job.id, job.lock_token) end)
      sweep = Task.async(fn -> Postgres.recover_stale_locks(config, 300) end)
      run = fn -> Map.take(get(job.id), [:status, :lock_token, :locked_by]) end

      case {Task.await(heartbeat), Task.await(sweep)} do
        {:ok, {:ok, 0}} ->
          assert run.() == %{status: :running, lock_token: job.lock_token, locked_by: "node-a"}

        {{:error, :not_found}, {:ok, 1}} ->
          assert run.() == %{status: :pending, lock_token: nil, locked_by: nil}

        both ->
          flunk("the heartbeat and the sweep both won, or neither: #{inspect(both)}")
      end
    end
  end

  test "two nodes' stale sweeps racing: one takes the run, and its attempt ends once" do
    config = start_idle!()
    handler = "audit4-queue-races-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:durable, :step, :stop], &__MODULE__.forward_stop/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    for round <- 1..@rounds do
      job = stale_claim!(config, round)

      attempt =
        IntegrationRepo.insert!(%StepExecution{
          workflow_id: job.id,
          step_name: "work",
          step_type: "step",
          attempt: 1,
          status: :running,
          started_at: DateTime.utc_now()
        })

      sweeps = for _ <- 1..2, do: Task.async(fn -> Postgres.recover_stale_locks(config, 300) end)

      assert Enum.sort(Task.await_many(sweeps)) == [{:ok, 0}, {:ok, 1}]
      assert %{status: :pending, locked_by: nil, lock_token: nil} = get(job.id)

      assert %{status: :failed, error: %{"type" => "worker_lost"}} =
               IntegrationRepo.get!(StepExecution, attempt.id)

      # Sent by the sweep that closed the row, before it returned.
      id = attempt.id
      assert_received {:attempt_ended, ^id}
      refute_received {:attempt_ended, ^id}
    end
  end

  test "a claim racing a cancel: the run ends cancelled, and the claim is worth nothing" do
    config = start_idle!()
    ids = for _ <- 1..@rounds, do: Durable.start(Audit4QueueRaceOnce, %{}) |> elem(1)

    claims = Task.async(fn -> claim_all(config) end)
    cancels = Task.async(fn -> Enum.map(ids, &Durable.cancel(&1, "race")) end)
    jobs = Task.await(claims)

    assert Enum.all?(Task.await(cancels), &(&1 == :ok))

    for id <- ids do
      assert %{status: :cancelled, locked_by: nil, lock_token: nil} = get(id)
    end

    for job <- jobs do
      id = job.id
      {:ok, worker} = Worker.start_link(job: job, config: config, poller_pid: self())
      assert_receive {:job_complete, ^worker, ^id, :fenced, _ms}, 5_000
      assert get(id).status == :cancelled
    end

    assert Probe.hits(:once) == 0
  end

  describe "a schedule" do
    defp overdue!(name, seconds) do
      {1, _} =
        IntegrationRepo.update_all(
          from(s in ScheduledWorkflow, where: s.name == ^name),
          set: [next_run_at: DateTime.add(DateTime.utc_now(), -seconds, :second)]
        )

      IntegrationRepo.get_by!(ScheduledWorkflow, name: name)
    end

    defp scheduled_runs do
      IntegrationRepo.all(from(w in WorkflowExecution, where: w.trigger == :schedule))
    end

    test "whose node was away for three days of ticks fires once, then keeps to its times" do
      start_durable!(%{default: 1})
      {:ok, _} = Durable.schedule(Audit4QueueRaceOnce, "* * * * *", name: "every_minute")
      overdue!("every_minute", 3 * 86_400)

      for _ <- 1..3 do
        Durable.Scheduler.check_schedules()
        Durable.Scheduler.status()
      end

      assert [run] = scheduled_runs()
      await_status(run.id, :completed)

      next = IntegrationRepo.get_by!(ScheduledWorkflow, name: "every_minute").next_run_at
      assert DateTime.diff(next, DateTime.utc_now(), :millisecond) in 1..60_000
    end

    test "seen due by twenty checks at once is taken by exactly one" do
      config = start_idle!()
      {:ok, _} = Durable.schedule(Audit4QueueRaceOnce, "* * * * *", name: "contended")

      for _round <- 1..10 do
        due = overdue!("contended", 60)

        won =
          1..20
          |> Enum.map(fn _ -> Task.async(fn -> API.claim_fire(due, config) end) end)
          |> Task.await_many()

        assert Enum.count(won, & &1) == 1
      end
    end
  end

  describe "a wake is only a hint" do
    test "a commit waker killed with a start's transaction still open costs only the next poll" do
      start_durable!(%{default: 1}, poll_interval: 300)

      {:ok, id} =
        IntegrationRepo.transaction(fn ->
          {:ok, id} = Durable.start(Audit4QueueRaceOnce, %{})
          Process.exit(Process.whereis(CommitWaker.name(Config.get(Durable))), :kill)
          id
        end)

      await_status(id, :completed, 5_000)
      assert Probe.hits(:once) == 1
    end

    defp start_pubsub! do
      pubsub = Supervisor.child_spec({Phoenix.PubSub, name: Audit4QueuePubSub}, id: :pubsub)
      start_supervised!(pubsub)
    end

    test "a start with the PubSub down still returns its run" do
      start_pubsub!()
      start_idle!(pubsub: Audit4QueuePubSub)
      stop_supervised!(:pubsub)

      assert {:ok, id} = Durable.start(Audit4QueueRaceOnce, %{})
      assert get(id).status == :pending
    end

    test "with the PubSub down a poller still starts, and a run's steps still end" do
      start_pubsub!()
      start_durable!(%{default: 1}, pubsub: Audit4QueuePubSub)
      poller = Process.whereis(Durable.Queue.Poller.Default)

      # A PubSub that stops takes its subscribers with it: the poller restarts,
      # with nothing to subscribe to.
      stop_supervised!(:pubsub)

      assert_eventually(fn ->
        Process.whereis(Durable.Queue.Poller.Default) not in [nil, poller]
      end)

      {:ok, id} = Durable.start(Audit4QueueRaceOnce, %{})
      await_status(id, :completed, 5_000)
      assert Probe.hits(:once) == 1
      assert [%{status: :completed}] = IntegrationRepo.all(StepExecution)
    end
  end
end
