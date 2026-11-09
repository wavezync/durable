defmodule Durable.Fuzz.ChaosTest do
  @moduledoc """
  Operators and recovery sweeps act at random moments while runs execute. A run
  nobody touched must still do exactly what its script says.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  import Durable.FuzzScripts

  alias Durable.Config
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Queue.Manager
  alias Durable.Wait.{SleepWaker, TimeoutWorker}

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "30"))
  @limits %{default: 8, q_a: 2, q_b: 3}
  @queues Map.keys(@limits)
  @batch 10

  setup do
    start_durable!(@limits, heartbeat_interval: 100)
    :ok
  end

  defp op do
    index = integer(0..(@batch - 1))

    one_of([
      tuple({constant(:cancel), index}),
      tuple({constant(:cancel), index}),
      tuple({constant(:retry), index}),
      tuple({constant(:early_event), index, member_of(steps())}),
      constant(:cancel_tag),
      constant(:sweep),
      constant(:recover),
      constant(:wake_sleepers),
      tuple({constant(:pause), member_of(@queues)}),
      tuple({constant(:resume), member_of(@queues)}),
      tuple({constant(:wait), integer(0..30)})
    ])
  end

  # Returns the indexes of the runs this op may have changed.
  defp apply_op({:cancel, i}, runs, seen) do
    %{id: id, case_id: case_id} = Enum.at(runs, i)
    entered = entered(case_id)

    if Durable.cancel(id, "chaos") == :ok, do: Agent.update(seen, &Map.put(&1, i, entered))
    [i]
  end

  defp apply_op({:retry, i}, runs, _seen) do
    Durable.retry(Enum.at(runs, i).id)
    [i]
  end

  defp apply_op({:early_event, i, step}, runs, _seen) do
    Durable.send_event(Enum.at(runs, i).id, "e_#{step}", %{}, buffer: true)
    [i]
  end

  defp apply_op(:cancel_tag, runs, seen) do
    # Only the first three carry this tag.
    for {run, i} <- runs |> Enum.take(3) |> Enum.with_index() do
      Agent.update(seen, &Map.put_new(&1, i, entered(run.case_id)))
    end

    Durable.cancel_all([tag: "chaos"], "chaos")
    [0, 1, 2]
  end

  defp apply_op(:sweep, _runs, _seen) do
    TimeoutWorker.check_timeouts(Durable)
    []
  end

  defp apply_op(:recover, _runs, _seen) do
    config = Config.get(Durable)
    Postgres.recover_stale_locks(config, 1)
    Postgres.recover_zombie_workflows(config, 1)
    []
  end

  defp apply_op(:wake_sleepers, _runs, _seen) do
    SleepWaker.wake_now(Durable)
    []
  end

  defp apply_op({:pause, queue}, _runs, _seen) do
    Durable.pause_queue(queue)
    []
  end

  defp apply_op({:resume, queue}, _runs, _seen) do
    Durable.resume_queue(queue)
    []
  end

  defp apply_op({:wait, ms}, _runs, _seen) do
    Process.sleep(ms)
    []
  end

  defp entered(case_id) do
    Enum.sum(for step <- steps(), do: Probe.hits({case_id, step, :enter}))
  end

  defp quiesce do
    assert_eventually(
      fn -> Enum.all?(@queues, &(Manager.status(Durable, &1).active_jobs == 0)) end,
      10_000,
      10
    )
  end

  defp check_touched(%{id: id, case_id: case_id}, cancelled_at) do
    run = get(id)
    label = "#{inspect(describe(run))} #{inspect(Probe.fetch(case_id))}"

    assert run.status in terminal(), "not finished: #{label}"
    assert run.locked_by == nil, "left locked: #{label}"
    assert Probe.peak({:run, case_id}) <= 1, "steps overlapped: #{label}"

    refute match?(%{"type" => "zombie_detected"}, run.error), "declared dead: #{label}"

    for step <- steps() do
      assert Probe.hits({case_id, step, :done}) <= 1, "#{step} completed twice: #{label}"
    end

    undone = for {{^case_id, :undo, step}, _queue, _node} <- Probe.log(), do: step
    assert undone == Enum.uniq(undone), "undone twice #{inspect(undone)}: #{label}"

    for step <- undone do
      assert Probe.hits({case_id, step, :done}) == 1, "#{step} undone but never done: #{label}"
    end

    rows = IntegrationRepo.all(from(s in StepExecution, where: s.workflow_id == ^id))
    assert Enum.all?(rows, &(&1.status != :running)), "a step row left running: #{label}"

    # A step already under way may finish; nothing new starts.
    if cancelled_at && run.status == :cancelled do
      assert entered(case_id) <= cancelled_at + 1, "a step started after the cancel: #{label}"
    end
  end

  property "operators and sweeps never hang a run, repeat a step or disturb the others" do
    check all(
            scripts <- list_of(script(), length: @batch),
            ops <- list_of(op(), min_length: 5, max_length: 25),
            max_runs: @runs,
            max_shrinking_steps: 20
          ) do
      runs =
        scripts
        |> Enum.with_index()
        |> Enum.map(fn {script, i} ->
          start_run(script, if(i < 3, do: [tags: ["chaos"]], else: []))
        end)

      {:ok, seen} = Agent.start_link(fn -> %{} end)

      touched =
        ops
        |> Task.async_stream(&apply_op(&1, runs, seen), max_concurrency: 4, timeout: 30_000)
        |> Enum.flat_map(fn {:ok, indexes} -> indexes end)
        |> MapSet.new()

      for queue <- @queues, do: Durable.resume_queue(queue)
      drive(runs)
      quiesce()

      cancelled_at = Agent.get(seen, & &1)
      Agent.stop(seen)

      for {run, i} <- Enum.with_index(runs) do
        if i in touched,
          do: check_touched(run, cancelled_at[i]),
          else: check_run(run)
      end
    end
  end
end
