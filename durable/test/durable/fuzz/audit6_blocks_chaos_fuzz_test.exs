defmodule Durable.Fuzz.Audit6BlocksChaosTest do
  @moduledoc """
  Audit 6: an order with lanes, a block inside a lane, a child workflow called
  from a lane, an `into:` block and two compensations, run from a script while
  operators (cancel, cancel and undo, retry, rollback, retry or cancel one
  lane), recovery sweeps and kills (a step's task, its worker) land at random
  moments. A run nothing touched must do exactly what the model says. Any run
  must end with its whole family over, nothing open, no undo of a step that
  never completed, and, if it completed, every lane and child completed and
  handed on.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  import Durable.FuzzScripts, only: [answer_waits: 1, describe: 1, terminal: 0]

  alias Durable.Config
  alias Durable.FuzzBlocks.Order
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Queue.Manager
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput}
  alias Durable.Wait.{SleepWaker, TimeoutWorker}

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "25"))
  @limits %{default: 16, q_a: 3, q_b: 3}
  @queues Map.keys(@limits)
  @batch 6
  @max_attempts 3

  @kid [{:step, :k1}, {:step, :k2}]

  @tree [
    {:step, :first},
    {:parallel, :fan,
     one: [{:step, :o1}, {:branch, :pick, m: [{:step, :m1}], n: [{:step, :n1}]}, {:step, :o2}],
     two: [{:step, :t1}, {:call, :t2, @kid}],
     three: [
       {:parallel, :deep, d1: [{:step, :d1}], db: [{:step, :d2}, {:step, :d3}]},
       {:step, :t3}
     ]},
    {:step, :charge},
    {:into, :checks, x1: [{:step, :x1}], x2: [{:step, :x2}]},
    {:step, :last}
  ]

  @retried [:o1, :d1, :charge]
  @arms %{pick: [:m, :n]}
  @undone [:first, :charge]
  # The root, three lanes, two in the lane's block, the kid, two checks.
  @family_size 9

  setup do
    start_durable!(@limits, heartbeat_interval: 100)
    :ok
  end

  # ===========================================================================
  # Generating
  # ===========================================================================

  defp names(seq) do
    Enum.flat_map(seq, fn
      {:step, name} ->
        [name]

      {:call, name, kid} ->
        names(kid) ++ [name]

      {:branch, name, arms} ->
        [name | Enum.flat_map(arms, fn {_arm, seq} -> names(seq) end)]

      {block, _name, lanes} when block in [:parallel, :into] ->
        Enum.flat_map(lanes, &names(elem(&1, 1)))
    end)
  end

  defp action(name) do
    frequency([
      {40, constant(:ok)},
      {2, constant(:fail)},
      {1, constant(:cancel)},
      {3, constant(:sleep)},
      {3, constant(:event)},
      {1, constant(:input)},
      {if(name in @retried, do: 10, else: 1),
       tuple({member_of([:error, :raise, :killed]), integer(1..4)})},
      {3, tuple({constant(:snooze), integer(1..2)})}
    ])
  end

  defp script do
    all = names(@tree)

    gen all(
          actions <- fixed_list(Enum.map(all, &action/1)),
          arms <- fixed_map(Map.new(@arms, fn {branch, arms} -> {branch, member_of(arms)} end)),
          slow <- map_of(member_of(all), integer(30..250), max_length: 4)
        ) do
      %{steps: all |> Enum.zip(actions) |> Map.new(), arms: arms, slow: slow}
    end
  end

  # ===========================================================================
  # The model
  # ===========================================================================

  defp outcome(:fail, _name), do: :failed
  defp outcome(:cancel, _name), do: :cancelled

  defp outcome({how, times}, name) when how in [:error, :raise, :killed] do
    if name in @retried and times < @max_attempts, do: :done, else: :failed
  end

  defp outcome(_action, _name), do: :done

  defp enters({:snooze, times}), do: times + 1
  defp enters({how, times}) when how in [:error, :raise, :killed], do: times + 1
  defp enters(wait) when wait in [:sleep, :event, :input], do: 2
  defp enters(_ok), do: 1

  # {how a sequence ends, the steps that certainly completed, the steps that
  # certainly never started}. As in the named fuzz: a block that fails fast
  # promises nothing about its lanes' steps but that none starts twice.
  defp walk([], _script), do: {:done, [], []}

  defp walk([item | rest], script) do
    case walk_item(item, script) do
      {:done, done, never} ->
        {how, more, more_never} = walk(rest, script)
        {how, done ++ more, never ++ more_never}

      {how, done, never} ->
        {how, done, never ++ names(rest)}
    end
  end

  defp walk_item({:step, name}, script) do
    case outcome(script.steps[name], name) do
      :done -> {:done, [name], []}
      stopped -> {stopped, [], []}
    end
  end

  # The kid is a run of its own: cancelled or failed, the step that called it fails.
  defp walk_item({:call, name, kid}, script) do
    case walk(kid, script) do
      {:done, done, never} ->
        {how, step_done, step_never} = walk_item({:step, name}, script)
        {how, done ++ step_done, never ++ step_never}

      {_stopped, done, never} ->
        {:failed, done, never}
    end
  end

  defp walk_item({:branch, name, arms}, script) do
    taken = script.arms[name]
    untaken = for {arm, seq} <- arms, arm != taken, step <- names(seq), do: step

    case outcome(script.steps[name], name) do
      :done ->
        {how, done, never} = walk(arms[taken], script)
        {how, [name | done], never ++ untaken}

      stopped ->
        {stopped, [], names(arms[taken]) ++ untaken}
    end
  end

  defp walk_item({:parallel, _name, lanes}, script) do
    walked = for {_lane, seq} <- lanes, do: walk(seq, script)
    never = Enum.flat_map(walked, &elem(&1, 2))

    case walked |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() do
      [:done] -> {:done, Enum.flat_map(walked, &elem(&1, 1)), never}
      [:done, one] -> {one, [], never}
      [one] -> {one, [], never}
      _failed_and_cancelled -> {:either, [], never}
    end
  end

  # Every lane runs to its end. A lane's step that cancels cancels the run.
  defp walk_item({:into, _name, lanes}, script) do
    walked = for {_lane, seq} <- lanes, do: walk(seq, script)
    hows = Enum.map(walked, &elem(&1, 0))
    done = Enum.flat_map(walked, &elem(&1, 1))
    never = Enum.flat_map(walked, &elem(&1, 2))

    cond do
      Enum.all?(hows, &(&1 == :done)) -> {:done, done, never}
      # The cancel stops the other lanes wherever they are.
      :cancelled in hows -> {:cancelled, [], never}
      true -> {:failed, done, never}
    end
  end

  defp statuses(:done, _done, _workflow), do: [:completed]
  defp statuses(:cancelled, _done, _workflow), do: [:cancelled]
  defp statuses(:either, _done, "fuzz_blocks_order_halt"), do: [:failed, :cancelled]
  defp statuses(:failed, _done, "fuzz_blocks_order_halt"), do: [:failed]
  defp statuses(:either, _done, _rollback), do: [:compensated, :cancelled]

  defp statuses(:failed, done, _rollback),
    do: if(:first in done, do: [:compensated], else: [:failed])

  # ===========================================================================
  # Driving
  # ===========================================================================

  defp start_run(script, workflow) do
    case_id = System.unique_integer([:positive])
    :ok = Probe.put(case_id, script)
    {:ok, id} = Durable.start(Order, %{"case" => case_id}, workflow: workflow)
    %{id: id, case_id: case_id, script: script, workflow: workflow}
  end

  defp family(id) do
    IntegrationRepo.all(
      from(w in WorkflowExecution,
        where: w.id == ^id or w.root_workflow_id == ^id,
        order_by: w.inserted_at
      )
    )
  end

  defp open(ids) do
    for id <- ids, member <- family(id), member.status not in terminal(), do: member
  end

  # Answers every wait, wakes the sleepers, and every so often runs the sweeps
  # with a one-second timeout: a worker that was killed holds its run's lock
  # until then.
  defp drive(ids, tries \\ 1_200)

  defp drive(ids, 0) do
    stuck = for member <- open(ids), do: describe(member)
    flunk("never finished: #{inspect(stuck, pretty: true)}")
  end

  defp drive(ids, tries) do
    case open(ids) do
      [] ->
        :ok

      members ->
        for member <- members, member.status == :waiting, do: answer_waits(member.id)
        SleepWaker.wake_now(Durable)
        if rem(tries, 20) == 0, do: sweep_all()
        Process.sleep(25)
        drive(ids, tries - 1)
    end
  end

  defp keep_driving(ids) do
    receive do
      :stop -> :ok
    after
      40 ->
        for member <- open(ids), member.status == :waiting, do: answer_waits(member.id)
        SleepWaker.wake_now(Durable)
        keep_driving(ids)
    end
  end

  defp sweep_all do
    config = Config.get(Durable)
    Postgres.recover_stale_locks(config, 1)
    Postgres.recover_zombie_workflows(config, 1)
    Durable.Executor.redeliver_lost_notices(config, 1)
    Durable.Executor.close_out_lost(config, 1)
    TimeoutWorker.check_timeouts(Durable)
  end

  # ===========================================================================
  # Chaos
  # ===========================================================================

  defp op do
    index = integer(0..(@batch - 1))

    frequency([
      {2, tuple({constant(:cancel), index})},
      {2, tuple({constant(:cancel_rollback), index})},
      {3, tuple({constant(:retry), index})},
      {3, tuple({constant(:rollback), index})},
      {4, tuple({constant(:retry_lane), index, integer(0..8)})},
      {2, tuple({constant(:cancel_lane), index, integer(0..8)})},
      {2, tuple({constant(:kill_task), integer(0..30)})},
      {2, tuple({constant(:kill_worker), integer(0..30)})},
      {2, constant(:recover)},
      {3, constant(:crash_node)},
      {2, tuple({constant(:expire), index, integer(0..8)})},
      {1, constant(:sweep)},
      {6, tuple({constant(:wait), integer(0..150)})}
    ])
  end

  # Each op returns `[{case_index, how}]` for the runs it may have changed.
  defp apply_op({:cancel, i}, runs), do: hit(i, :cancel, Durable.cancel(at(runs, i), "chaos"))

  defp apply_op({:cancel_rollback, i}, runs),
    do: hit(i, :cancel_rollback, Durable.cancel(at(runs, i), "chaos", rollback: true))

  defp apply_op({:retry, i}, runs), do: hit(i, :retry, Durable.retry(at(runs, i)))
  # A rollback lands only on a failed run: it goes for one if the batch has
  # one now, or it would rarely land at all.
  defp apply_op({:rollback, i}, runs) do
    failed =
      for {run, j} <- Enum.with_index(runs), get(run.id).status == :failed, do: j

    j = if failed == [], do: i, else: Enum.at(failed, rem(i, length(failed)))
    hit(j, :rollback, Durable.rollback(at(runs, j)))
  end

  defp apply_op({:retry_lane, i, k}, runs) do
    case runs |> at(i) |> family() |> Enum.filter(&(&1.status == :failed)) |> tl_or_empty() do
      [] -> []
      failed -> hit(i, :retry_lane, Durable.retry(Enum.at(failed, rem(k, length(failed))).id))
    end
  end

  defp apply_op({:cancel_lane, i, k}, runs) do
    case runs |> at(i) |> family() |> tl_or_empty() |> Enum.reject(&(&1.status in terminal())) do
      [] ->
        []

      live ->
        hit(i, :cancel_lane, Durable.cancel(Enum.at(live, rem(k, length(live))).id, "chaos"))
    end
  end

  defp apply_op({kill, k}, runs) when kill in [:kill_task, :kill_worker] do
    with {worker, %{job: job} = state} <- nth_worker(k),
         i when is_integer(i) <- case_of_run(runs, job.id) do
      pid = if kill == :kill_task, do: state.task_pid, else: worker

      if is_pid(pid) do
        Process.exit(pid, :kill)
        Probe.note({:op_hit, kill})
        [{i, kill}]
      else
        []
      end
    else
      _nothing_running -> []
    end
  end

  # The second node, if the case has one, dies the way a crash would: its
  # runs keep their locks until the sweep finds them stale. Any run may have
  # had a step, a notice or an undo there.
  defp apply_op(:crash_node, runs) do
    case Probe.fetch_or(:peer, nil) do
      nil ->
        []

      peer ->
        Probe.put(:peer, nil)
        crash_node!(peer)
        Probe.note({:op_hit, :crash_node})
        for i <- 0..(length(runs) - 1), do: {i, :crash_node}
    end
  end

  # A deadline passes: the run's own, or one of its family's (a lane's own
  # `timeout:`, the kid's). The next step boundary, or the sweep, times it out.
  defp apply_op({:expire, i, k}, runs) do
    family = runs |> at(i) |> family()
    member = Enum.at(family, rem(k, length(family)))

    {count, _} =
      IntegrationRepo.update_all(
        from(w in WorkflowExecution,
          where: w.id == ^member.id and w.status in [:pending, :running, :waiting]
        ),
        set: [deadline_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    if count == 1, do: Probe.note({:op_hit, :expire})
    TimeoutWorker.check_timeouts(Durable)
    [{i, :expire}]
  end

  defp apply_op(:recover, _runs) do
    sweep_all()
    []
  end

  defp apply_op(:sweep, _runs) do
    TimeoutWorker.check_timeouts(Durable)
    []
  end

  defp apply_op({:wait, ms}, _runs) do
    Process.sleep(ms)
    []
  end

  defp at(runs, i), do: Enum.at(runs, i).id

  # The family less the run itself, which is its oldest member.
  defp tl_or_empty([_root | rest]), do: rest
  defp tl_or_empty([]), do: []

  # Counted whether or not the operator was refused: a refusal changes nothing,
  # but the run still isn't one nobody touched.
  defp hit(i, how, result) do
    if match?(:ok, result) or match?({:ok, _}, result), do: Probe.note({:op_hit, how})
    [{i, how}]
  end

  defp case_of_run(runs, run_id) do
    root =
      IntegrationRepo.one(
        from(w in WorkflowExecution,
          where: w.id == ^run_id,
          select: coalesce(w.root_workflow_id, w.id)
        )
      )

    Enum.find_index(runs, &(&1.id == root))
  end

  defp camelize(queue),
    do: queue |> to_string() |> String.split("_") |> Enum.map_join(&String.capitalize/1)

  defp workers do
    for queue <- @queues,
        pid <- children(Module.concat([Durable, Queue, WorkerSupervisor, camelize(queue)])),
        state = state_of(pid),
        do: {pid, state}
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

  defp lost_worker?(hits),
    do: Enum.any?(hits, fn {how, _} -> how in [:kill_task, :kill_worker, :crash_node] end)

  defp quiesce do
    assert_eventually(
      fn -> Enum.all?(@queues, &(Manager.status(Durable, &1).active_jobs == 0)) end,
      15_000,
      10
    )
  end

  # ===========================================================================
  # Checking
  # ===========================================================================

  defp hits(case_id, name, what), do: Probe.hits({case_id, name, what})

  defp label(run, script, touched),
    do: "#{inspect(script)}\ntouched: #{inspect(touched)}\n#{inspect(describe(run))}"

  # What holds whatever was done to the run.
  defp check_always(%{id: id, case_id: case_id, script: script}, touched) do
    run = get(id)
    label = label(run, script, touched)
    members = family(id)

    assert run.status in terminal(), "not finished: #{label}"
    Enum.each(members, &check_member(&1, members, label))
    check_counts(case_id, touched, label)

    if run.status == :compensated,
      do: assert(hits(case_id, :undo, :first) >= 1, "compensated, :first never undone: #{label}")

    # Over, the run went through every lane and its child: none is left
    # stopped, or behind it.
    if run.status == :completed do
      assert length(members) == @family_size,
             "#{length(members)} runs in the family: #{inspect(Enum.map(members, &describe/1))} #{label}"

      for row <- members,
          do:
            assert(row.status == :completed, "completed past #{inspect(describe(row))} #{label}")

      trail = check_data(@tree, script, [], run.context, label)
      assert run.context["trail"] == trail, "the run's trail: #{label}"
    end
  end

  defp check_member(row, members, label) do
    assert row.status in terminal(), "family left open: #{inspect(describe(row))} #{label}"
    assert row.locked_by == nil, "family left locked: #{inspect(describe(row))} #{label}"

    refute match?(%{"type" => "zombie_detected"}, row.error),
           "declared dead: #{inspect(describe(row))} #{label}\n#{inspect(post_mortem(members), pretty: true, limit: :infinity)}"

    # A lane stopped by its block is closed by its own worker at its next
    # heartbeat, which can be after the run has ended.
    running =
      from(s in StepExecution,
        where: s.workflow_id == ^row.id and s.status == :running,
        select: {s.step_name, s.attempt}
      )

    left = still_running(running, 60)
    assert left == [], "a step row left running #{inspect(left)}: #{label}"

    for schema <- [PendingEvent, PendingInput], row.status == :completed do
      waits = from(p in schema, where: p.workflow_id == ^row.id and p.status == :pending)
      assert IntegrationRepo.aggregate(waits, :count) == 0, "wait left open: #{label}"
    end
  end

  # How often each body got to its end, and each undo ran.
  defp check_counts(case_id, touched, label) do
    # A body that got to its end again needs a retry, or a kill, to have
    # caused it.
    reruns =
      Enum.count(touched, fn {how, _} ->
        how in [:retry, :retry_lane, :kill_task, :kill_worker, :crash_node]
      end)

    for name <- names(@tree) do
      done = hits(case_id, name, :done)
      assert done <= 1 + reruns, "#{name} completed #{done} times: #{label}"
    end

    kills =
      Enum.count(touched, fn {how, _} -> how in [:kill_task, :kill_worker, :crash_node] end)

    for step <- @undone do
      undone = hits(case_id, :undo, step)
      assert undone <= 1 + kills, "#{step} undone #{undone} times: #{label}"

      if undone > 0,
        do: assert(hits(case_id, step, :done) > 0, "#{step} undone, never done: #{label}")
    end
  end

  # How deep a case got: the far ends of the tree have to be reached.
  defp note_reach(case_id) do
    for {what, reached?} <- [
          kid: hits(case_id, :k2, :done) > 0,
          deep: hits(case_id, :d3, :done) > 0,
          into: Probe.hits({case_id, :into}) > 0,
          undo_charge: hits(case_id, :undo, :charge) > 0
        ],
        reached?,
        do: Probe.note({:reached, what})
  end

  defp assert_reached do
    for what <- [:kid, :deep, :into, :undo_charge],
        do: assert(Probe.hits({:reached, what}) > 0, "never reached #{what}")
  end

  # Everything the family's rows say, for a failure that needs explaining.
  defp post_mortem(members) do
    ids = Enum.map(members, & &1.id)

    %{
      runs:
        Enum.map(
          members,
          &Map.take(&1, [
            :id,
            :status,
            :current_step,
            :parent_workflow_id,
            :error,
            :engine_state,
            :updated_at,
            :completed_at,
            :retried_at
          ])
        ),
      events:
        IntegrationRepo.all(
          from(e in PendingEvent,
            where: e.workflow_id in ^ids,
            select: {e.workflow_id, e.event_name, e.status, e.updated_at}
          )
        ),
      groups:
        IntegrationRepo.all(
          from(g in Durable.Storage.Schemas.WaitGroup,
            where: g.workflow_id in ^ids,
            select: {g.workflow_id, g.status, g.received_events, g.updated_at}
          )
        ),
      steps:
        IntegrationRepo.all(
          from(s in StepExecution,
            where: s.workflow_id in ^ids,
            order_by: s.inserted_at,
            select: {s.workflow_id, s.step_name, s.attempt, s.status, s.error, s.inserted_at}
          )
        ),
      activity: Durable.Activity.list!(limit: 50)
    }
  end

  defp still_running(query, tries) do
    case IntegrationRepo.all(query) do
      rows when rows == [] or tries == 0 ->
        rows

      _rows ->
        Process.sleep(50)
        still_running(query, tries - 1)
    end
  end

  # What a run nobody touched must have done, exactly.
  defp check_exactly(%{id: id, case_id: case_id, script: script, workflow: workflow} = run) do
    check_always(run, [])

    row = get(id)
    label = label(row, script, [])
    {how, done, never} = walk(@tree, script)

    assert row.status in statuses(how, done, workflow), "status, modelled #{how}: #{label}"

    for name <- done do
      assert hits(case_id, name, :done) == 1, "#{name} never completed: #{label}"

      entered = hits(case_id, name, :enter)
      wanted = enters(script.steps[name])
      assert entered == wanted, "#{name} entered #{entered}, wanted #{wanted}: #{label}"
    end

    for name <- never do
      assert hits(case_id, name, :enter) == 0, "#{name} must never start: #{label}"
    end

    for step <- @undone do
      want = if row.status == :compensated and step in done, do: 1, else: 0
      assert hits(case_id, :undo, step) == want, "#{step} undone: #{label}"
    end
  end

  defp check_data(seq, script, trail, data, label) do
    Enum.reduce(seq, trail, fn
      {:step, name}, trail ->
        trail ++ [to_string(name)]

      {:call, name, _kid}, trail ->
        trail ++ [to_string(name)]

      {:branch, name, arms}, trail ->
        check_data(arms[script.arms[name]], script, trail ++ [to_string(name)], data, label)

      {:into, name, _lanes}, trail ->
        assert data["checked"] == true, "#{name}'s into: left no mark: #{label}"
        trail

      {:parallel, name, lanes}, trail ->
        results = data[to_string(name)]

        assert is_map(results) and map_size(results) == length(lanes),
               "#{name} holds #{inspect(results && Map.keys(results))}: #{label}"

        for {lane, seq} <- lanes do
          lane_data = results[to_string(lane)]
          lane_trail = check_data(seq, script, trail, lane_data, label)
          assert lane_data["trail"] == lane_trail, "the trail of #{name}.#{lane}: #{label}"
        end

        trail
    end)
  end

  # ===========================================================================
  # Properties
  # ===========================================================================

  property "untouched, an order of lanes, a child and an into: does what its script says" do
    check all(
            scripts <- list_of(script(), length: @batch),
            workflows <-
              list_of(member_of(["fuzz_blocks_order", "fuzz_blocks_order_halt"]), length: @batch),
            max_runs: @runs,
            max_shrinking_steps: 10
          ) do
      runs = Enum.zip_with(scripts, workflows, &start_run/2)
      drive(Enum.map(runs, & &1.id))
      quiesce()

      for run <- runs do
        check_exactly(run)
        note_reach(run.case_id)
        Probe.note({:ended, get(run.id).status})
      end
    end

    ended = Map.new(terminal(), &{&1, Probe.hits({:ended, &1})})
    total = ended |> Map.values() |> Enum.sum()

    # The far end has to be reached often, and every other way to end.
    assert ended.completed * 6 >= total, "too few runs completed: #{inspect(ended)}"

    for status <- [:compensated, :failed, :cancelled],
        do: assert(ended[status] > 0, "never ended #{status}: #{inspect(ended)}")

    assert_reached()
  end

  property "operators, sweeps and kills never hang an order, undo what never ran, or lose a lane" do
    check all(
            scripts <- list_of(script(), length: @batch),
            workflows <-
              list_of(member_of(["fuzz_blocks_order", "fuzz_blocks_order_halt"]), length: @batch),
            ops <- list_of(tuple({integer(0..250), op()}), min_length: 4, max_length: 24),
            second_node? <- boolean(),
            max_runs: @runs,
            max_shrinking_steps: 10
          ) do
      if second_node? do
        peer = start_node!(:"audit6_b#{System.unique_integer([:positive])}", @limits)
        Probe.put(:peer, peer)
      end

      runs = Enum.zip_with(scripts, workflows, &start_run/2)

      # The runs go on meanwhile, their waits answered, so an operator can
      # meet them anywhere: mid-step, waiting, failed, being undone.
      driver = Task.async(fn -> keep_driving(Enum.map(runs, & &1.id)) end)

      touched =
        ops
        |> Task.async_stream(
          fn {pause, op} ->
            Process.sleep(pause)
            apply_op(op, runs)
          end,
          max_concurrency: 3,
          timeout: 60_000
        )
        |> Enum.flat_map(fn {:ok, hits} -> hits end)
        |> Enum.group_by(&elem(&1, 0), fn {_i, how} -> {how, 1} end)

      send(driver.pid, :stop)
      Task.await(driver, 30_000)

      for queue <- @queues, do: Durable.resume_queue(queue)
      drive(Enum.map(runs, & &1.id))
      quiesce()

      # What a lost worker left is swept once it's a second old (`sweep_all/0`
      # counts that as stale): an attempt a cancel couldn't close, say. The
      # runs can all have ended before then.
      if Enum.any?(Map.values(touched), &lost_worker?/1) do
        Process.sleep(1_100)
        sweep_all()
        drive(Enum.map(runs, & &1.id))
        quiesce()
      end

      # Whatever node is left goes, with nothing of the case's still to run.
      with peer when peer != nil <- Probe.fetch_or(:peer, nil) do
        Probe.put(:peer, nil)

        assert_eventually(
          fn ->
            Enum.all?(
              @queues,
              &(:erpc.call(peer, Manager, :status, [Durable, &1]).active_jobs == 0)
            )
          end,
          15_000,
          10
        )

        crash_node!(peer)
      end

      for {run, i} <- Enum.with_index(runs) do
        case Map.get(touched, i, []) do
          [] -> check_exactly(run)
          hits -> check_always(run, hits)
        end

        note_reach(run.case_id)
        Probe.note({:chaos_ended, get(run.id).status})
      end
    end

    # The operators have to land, not only be refused.
    for how <- [
          :retry,
          :rollback,
          :retry_lane,
          :cancel_rollback,
          :cancel_lane,
          :kill_task,
          :kill_worker,
          :crash_node,
          :expire
        ] do
      assert Probe.hits({:op_hit, how}) > 0, "#{how} never landed"
    end

    for status <- [:completed, :compensated, :failed, :cancelled] do
      assert Probe.hits({:chaos_ended, status}) > 0, "never ended #{status} under chaos"
    end

    assert_reached()
  end
end
