defmodule Durable.Fuzz.Audit4QueueKillTest do
  @moduledoc """
  Audit 4: the queue's own processes are killed at random moments while runs
  execute: a step's task, its worker, a queue's poller. Whatever recovery does
  with what they held, no run may hang, be left locked, skip a step or run
  two of its steps at once, and no attempt may end twice. A run nothing was
  killed under must still do exactly what its script says.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  import Durable.FuzzScripts

  alias Durable.Config
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Wait.SleepWaker

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "30"))
  @limits %{default: 8, q_a: 2, q_b: 3}
  @queues Map.keys(@limits)
  @batch 8

  setup do
    # No grace period, so no Drainer: a manager that restarts after enough
    # poller kills must not leave the node believing it is stopping.
    start_durable!(@limits, heartbeat_interval: 100)
    :ok
  end

  defp op do
    frequency([
      {3, tuple({constant(:kill_task), integer(0..20)})},
      {3, tuple({constant(:kill_worker), integer(0..20)})},
      {1, tuple({constant(:kill_poller), member_of(@queues)})},
      {5, tuple({constant(:wait), integer(0..30)})}
    ])
  end

  # One poller kill a case: more would restart the manager, then the instance.
  defp one_poller_kill(ops) do
    {kept, _seen} =
      Enum.flat_map_reduce(ops, false, fn
        {:kill_poller, _queue}, true -> {[], true}
        {:kill_poller, _queue} = op, false -> {[op], true}
        op, seen -> {[op], seen}
      end)

    kept
  end

  defp camelize(queue),
    do: queue |> to_string() |> String.split("_") |> Enum.map_join(&String.capitalize/1)

  defp worker_supervisor(queue),
    do: Module.concat([Durable, Queue, WorkerSupervisor, camelize(queue)])

  defp poller(queue), do: Module.concat([Durable, Queue, :Poller, camelize(queue)])

  # Each live worker with its state. One that stops while it's asked isn't one.
  defp workers do
    for queue <- @queues, pid <- children(worker_supervisor(queue)), state = state_of(pid) do
      {pid, state}
    end
  end

  defp children(supervisor) do
    for {_id, pid, _type, _modules} when is_pid(pid) <-
          DynamicSupervisor.which_children(supervisor),
        do: pid
  catch
    :exit, _reason -> []
  end

  defp state_of(pid) do
    :sys.get_state(pid, 1_000)
  catch
    :exit, _reason -> nil
  end

  defp nth_worker(index) do
    case workers() do
      [] -> nil
      live -> Enum.at(live, rem(index, length(live)))
    end
  end

  # Returns the ids of the runs this op killed something under, or :all.
  defp apply_op({:kill_task, index}) do
    case nth_worker(index) do
      {_worker, %{task_pid: task} = state} when is_pid(task) ->
        Process.exit(task, :kill)
        [state.job.id]

      _nothing_running ->
        []
    end
  end

  defp apply_op({:kill_worker, index}) do
    case nth_worker(index) do
      {worker, state} ->
        Process.exit(worker, :kill)
        [state.job.id]

      nil ->
        []
    end
  end

  defp apply_op({:kill_poller, queue}) do
    with pid when is_pid(pid) <- Process.whereis(poller(queue)), do: Process.exit(pid, :kill)
    :all
  end

  defp apply_op({:wait, ms}) do
    Process.sleep(ms)
    []
  end

  # Drives every run to its end. A run whose worker was killed keeps its lock
  # until it goes stale, so the sweeps run here with a one-second timeout: ten
  # heartbeats, which no live worker misses.
  defp settle(runs, tries \\ 800)

  defp settle(runs, 0) do
    stuck = for %{id: id, script: script} <- runs, do: {describe(get(id)), script}
    flunk("never finished: #{inspect(stuck, pretty: true)}")
  end

  defp settle(runs, tries) do
    open = Enum.reject(runs, &(get(&1.id).status in terminal()))

    if open != [] do
      for %{id: id} <- open, get(id).status == :waiting, do: answer_waits(id)
      SleepWaker.wake_now(Durable)

      config = Config.get(Durable)
      {:ok, _} = Postgres.recover_stale_locks(config, 1)
      {:ok, _} = Postgres.recover_zombie_workflows(config, 1)

      Process.sleep(25)
      settle(open, tries - 1)
    end
  end

  defp quiesce, do: assert_eventually(fn -> workers() == [] end, 10_000, 10)

  defp check_survivor(%{id: id, case_id: case_id, script: script}) do
    run = get(id)
    label = "#{inspect(describe(run))} #{inspect(script)}"

    assert run.status in terminal(), "not finished: #{label}"
    assert run.locked_by == nil, "left locked: #{label}"
    assert Probe.peak({:run, case_id}) <= 1, "steps overlapped: #{label}"

    # Not checked here: a task killed as its attempt begins can leave that
    # attempt's row open for good. See "a task killed as its attempt begins"
    # in integration/audit4_queue_recovery_test.exs.
    rows = IntegrationRepo.all(from(s in StepExecution, where: s.workflow_id == ^id))

    # A step killed after its row was written and before the run saved its
    # result runs again, so a step can have more than one completed row.
    if run.status == :completed do
      done = for %{status: :completed, is_compensation: false} = row <- rows, do: row.step_name

      assert steps() -- Enum.map(done, &String.to_existing_atom/1) == [],
             "a step skipped: #{label}"
    end

    undone = for {{^case_id, :undo, step}, _queue, _node} <- Probe.log(), do: step
    assert undone == Enum.uniq(undone), "undone twice #{inspect(undone)}: #{label}"
  end

  # Starts and ends come from different processes when an attempt dies, so
  # only the row's id can say which attempt an event was for. No attempt ends
  # twice or without starting. One can go without its end: a step that closes
  # its own row and is killed before it leaves its span has nobody left to
  # send it. That is only allowed where something was killed.
  defp assert_attempts_ended(killed_under) do
    Process.sleep(100)
    events = drain_attempt_events()
    starts = for {:start, id} <- events, do: id
    ends = for {:end, id} <- events, do: id

    assert starts == Enum.uniq(starts)
    assert ends == Enum.uniq(ends), "ended twice: #{inspect(attempts(ends -- Enum.uniq(ends)))}"
    assert ends -- starts == [], "ended, never started: #{inspect(attempts(ends -- starts))}"

    for attempt <- attempts(starts -- ends) do
      assert killed_under == :all or attempt.workflow_id in killed_under,
             "never ended, with nothing killed: #{inspect(attempt)}"
    end
  end

  defp attempts(ids) do
    IntegrationRepo.all(
      from(s in StepExecution,
        where: s.id in ^ids,
        select: map(s, [:workflow_id, :step_name, :status, :attempt, :is_compensation])
      )
    )
  end

  defp drain_attempt_events do
    receive do
      {:attempt_event, event} -> [event | drain_attempt_events()]
    after
      0 -> []
    end
  end

  defp capture_attempt_events do
    test = self()
    handler = "audit4-attempt-events-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:durable, :step, :start], [:durable, :step, :stop], [:durable, :step, :exception]],
      fn [:durable, :step, phase], _, meta, _ ->
        kind = if phase == :start, do: :start, else: :end
        send(test, {:attempt_event, {kind, meta.step_execution_id}})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  property "killed tasks, workers and pollers never hang a run or disturb the others" do
    capture_attempt_events()

    check all(
            scripts <- list_of(script(), length: @batch),
            ops <- list_of(op(), min_length: 4, max_length: 20),
            max_runs: @runs,
            max_shrinking_steps: 10
          ) do
      runs = Enum.map(scripts, &start_run/1)

      killed = ops |> one_poller_kill() |> Enum.map(&apply_op/1)

      settle(runs)
      quiesce()

      everything? = :all in killed
      under = killed |> Enum.reject(&(&1 == :all)) |> List.flatten() |> MapSet.new()
      assert_attempts_ended(if everything?, do: :all, else: under)

      for run <- runs do
        if everything? or run.id in under, do: check_survivor(run), else: check_run(run)
      end
    end
  end
end
