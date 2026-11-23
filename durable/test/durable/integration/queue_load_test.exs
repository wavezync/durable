defmodule Durable.Integration.QueueLoadTest do
  @moduledoc """
  Several real nodes on one database work through a few thousand short runs
  while workers, their tasks and whole nodes are killed or stopped at random.
  Afterwards every run has ended, nothing is left locked or open, no step of
  a run ran beside another, and a run nothing was done to ran each step once.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Queue.StaleJobRecovery

  @moduletag :capture_log
  @moduletag timeout: 600_000

  @queues %{default: 6, ocr: 3}
  @node_opts [stale_lock_timeout: 2]
  @runs String.to_integer(System.get_env("LOAD_RUNS", "1500"))

  setup do
    seed = :rand.uniform(1_000_000)
    :rand.seed(:exsss, {seed, seed, seed})
    IO.puts("queue load seed: #{seed}")
    %{seed: seed}
  end

  # Some nodes wait a moment for their steps when stopped, some hand back at once.
  defp boot(i),
    do:
      start_node!(
        :"load_#{i}",
        @queues,
        [shutdown_grace_period: Enum.random([0, 300])] ++ @node_opts
      )

  test "a few thousand runs on several nodes, with workers, tasks and nodes killed" do
    nodes = for i <- 1..3, do: boot(i)
    connect_nodes!(nodes)

    ids = start_all(hd(nodes))
    {nodes, _next} = chaos(nodes, 4, String.to_integer(System.get_env("LOAD_OPS", "200")))
    settle(ids, nodes)
    check(ids)
  end

  defp start_all(node) do
    1..@runs
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      items = for n <- chunk, do: {W.Load, %{"n" => n, "ms" => :rand.uniform(15)}}

      for {:ok, id} <- :erpc.call(node, Durable, :start_many, [items], 60_000), do: id
    end)
  end

  defp chaos(nodes, next, 0), do: {nodes, next}

  defp chaos(nodes, next, ops_left) do
    Process.sleep(:rand.uniform(40))
    node = Enum.random(nodes)

    {nodes, next} =
      case :rand.uniform(40) do
        n when n <= 18 ->
          _ = :erpc.call(node, Durable.IntegrationCase, :kill_one, [:task, Map.keys(@queues)])
          {nodes, next}

        n when n <= 34 ->
          _ = :erpc.call(node, Durable.IntegrationCase, :kill_one, [:worker, Map.keys(@queues)])
          {nodes, next}

        35 ->
          crash_node!(node)
          replace(nodes, node, next)

        36 ->
          stop_durable!(node)
          crash_node!(node)
          replace(nodes, node, next)

        _ ->
          _ = :erpc.call(node, StaleJobRecovery, :recover_now, [Durable])
          {nodes, next}
      end

    chaos(nodes, next, ops_left - 1)
  end

  defp replace(nodes, gone, next) do
    fresh = boot(next)
    nodes = [fresh | List.delete(nodes, gone)]
    connect_nodes!(nodes)
    {nodes, next + 1}
  end

  defp settle(ids, nodes, tries \\ 240)

  defp settle(ids, _nodes, 0) do
    open = Enum.reject(ids, &(get(&1).status in [:completed, :failed]))

    flunk(
      "#{length(open)} runs never ended, e.g. #{inspect(Enum.map(Enum.take(open, 3), &get/1))}"
    )
  end

  defp settle(ids, nodes, tries) do
    open =
      IntegrationRepo.all(
        from(w in WorkflowExecution,
          where: w.id in ^ids and w.status not in [:completed, :failed],
          select: count(w.id)
        )
      )

    if open != [0] do
      _ = :erpc.call(Enum.random(nodes), StaleJobRecovery, :recover_now, [Durable])
      Process.sleep(500)
      settle(ids, nodes, tries - 1)
    end
  end

  defp check(ids) do
    runs = IntegrationRepo.all(from(w in WorkflowExecution, where: w.id in ^ids))
    rows = IntegrationRepo.all(from(s in StepExecution, where: s.workflow_id in ^ids))
    rows_of = Enum.group_by(rows, & &1.workflow_id)

    for run <- runs do
      n = run.input["n"]
      mine = Map.get(rows_of, run.id, [])
      label = "run #{n} #{run.id} #{run.status} #{inspect(run.error)}"

      assert run.locked_by == nil, "left locked: #{label}"
      assert Probe.peak({:run, n}) <= 1, "two of its steps at once: #{label}"

      open = for %{status: s} = row <- mine, s in [:pending, :running], do: row.step_name
      assert open == [], "attempts left open #{inspect(open)}: #{label}"

      # A body runs only after its attempt's row is written.
      for step <- ["a", "b", "c"] do
        attempts = Enum.count(mine, &(&1.step_name == step))
        ran = Probe.hits({String.to_atom(step), n})
        assert ran <= attempts, "#{step} ran #{ran} times with #{attempts} attempts: #{label}"
      end

      if run.status == :completed do
        done = for %{status: :completed} = row <- mine, do: row.step_name
        assert Enum.sort(done) == ["a", "b", "c"], "a step skipped or done twice: #{label}"
      else
        # Only losing its worker three times fails a run here.
        assert run.error["type"] in ["worker_lost", "task_crash"], "failed: #{label}"
      end

      # Nothing was done to it: each step ran once.
      if Enum.all?(mine, &(&1.status == :completed)) do
        for step <- [:a, :b, :c] do
          assert Probe.hits({step, n}) == 1,
                 "#{step} ran #{Probe.hits({step, n})} times, untouched: #{label}"
        end
      end
    end

    for %{status: :failed} = run <- runs do
      trail =
        for row <- Enum.sort_by(Map.get(rows_of, run.id, []), & &1.inserted_at),
            do: {row.step_name, row.attempt, row.status, row.error && row.error["type"]}

      IO.puts("failed #{run.input["n"]}: #{inspect(run.error["type"])} #{inspect(trail)}")
    end

    failed = Enum.count(runs, &(&1.status == :failed))
    lost = ["worker_lost", "task_crash", "node_stopped"]

    touched =
      rows
      |> Enum.filter(&(&1.error && &1.error["type"] in lost))
      |> Enum.uniq_by(& &1.workflow_id)

    IO.puts(
      "queue load: #{length(runs)} runs, #{length(touched)} lost an attempt, " <>
        "#{failed} failed after losing workers"
    )
  end
end
