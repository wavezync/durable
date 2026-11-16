defmodule Durable.Fuzz.NamedTest do
  @moduledoc """
  Named branches and lanes, nested in each other, checked against a model: which
  steps ran, how often, in what order each run's data went through them, and how
  the run ended. Then the same with operators and recovery acting at random.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  import Durable.FuzzScripts, only: [answer_waits: 1, describe: 1, terminal: 0]

  alias Durable.Config
  alias Durable.FuzzWorkflows.{NamedCollect, NamedOptional, NamedTree, NamedTreePlain}
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Queue.Manager
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput}
  alias Durable.Wait.{SleepWaker, TimeoutWorker}

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "30"))
  @limits %{default: 12, q_a: 3, q_b: 3}
  @queues Map.keys(@limits)
  @max_attempts 3

  # The workflow, as the model sees it. A join is a step that also checks what
  # the block before it handed over.
  @tree [
    {:step, :first},
    {:branch, :route,
     a: [
       {:step, :a1},
       {:branch, :inner,
        x: [{:step, :x1}, {:step, :x2}],
        y: [],
        z: [
          {:parallel, :zp, l1: [{:step, :z1}, {:step, :z2}], z3: [{:step, :z3}]},
          {:step, :zjoin}
        ]},
       {:step, :a2}
     ],
     b: [],
     c: [{:step, :c1}]},
    {:parallel, :fan,
     one: [
       {:step, :p1},
       {:branch, :pick, m: [{:step, :m1}], n: [{:step, :n1}, {:step, :n2}]},
       {:step, :p2}
     ],
     two: [
       {:step, :q1},
       {:parallel, :deep, da: [{:step, :d1}, {:step, :d2}], db: [{:step, :d3}]},
       {:step, :q2}
     ],
     solo: [{:step, :solo}]},
    {:step, :join},
    {:step, :last}
  ]

  @retried [:route, :a1, :z1, :p1, :pick, :q1, :d2, :i1, :c, :reduce]
  # The same names in the collecting and the optional tree are retried in both.
  @arms %{route: [:a, :b, :c], inner: [:x, :y, :z], pick: [:m, :n]}

  setup do
    start_durable!(@limits, heartbeat_interval: 100)
    :ok
  end

  # ===========================================================================
  # Generating
  # ===========================================================================

  # Every name that runs code: steps, joins and the branches' deciders.
  defp names(seq) do
    Enum.flat_map(seq, fn
      {:step, name} -> [name]
      {:branch, name, arms} -> [name | Enum.flat_map(arms, fn {_arm, seq} -> names(seq) end)]
      {:parallel, _name, lanes} -> Enum.flat_map(lanes, fn {_lane, seq} -> names(seq) end)
    end)
  end

  # A step with retries misbehaves often, since it usually gets past it. The
  # rest mostly work: a run has some twenty steps to get through, and the far
  # end of the tree has to be reached.
  defp action(name) do
    frequency([
      {40, constant(:ok)},
      {1, constant(:fail)},
      {1, constant(:cancel)},
      {4, constant(:sleep)},
      {4, constant(:event)},
      {2, constant(:input)},
      {if(name in @retried, do: 12, else: 1),
       tuple({member_of([:error, :raise, :killed]), integer(1..4)})},
      {4, tuple({constant(:snooze), integer(1..2)})}
    ])
  end

  defp script do
    all = names(@tree)

    gen all(
          actions <- fixed_list(Enum.map(all, &action/1)),
          arms <- fixed_map(Map.new(@arms, fn {branch, arms} -> {branch, member_of(arms)} end))
        ) do
      %{steps: all |> Enum.zip(actions) |> Map.new(), arms: arms}
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

  # How a sequence ends, the steps that certainly completed and the steps that
  # certainly never started. A parallel block that doesn't finish makes no
  # promise about its lanes' steps but that none runs twice: a sibling's
  # failure stops a lane wherever it has got to.
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

  defp statuses(:done, _done), do: [:completed]
  defp statuses(:cancelled, _done), do: [:cancelled]
  defp statuses(:either, _done), do: [:compensated, :cancelled]
  defp statuses(:failed, done), do: if(:first in done, do: [:compensated], else: [:failed])

  # ===========================================================================
  # Driving
  # ===========================================================================

  defp start_run(script, opts \\ [], workflow \\ NamedTree) do
    case_id = System.unique_integer([:positive])
    :ok = Probe.put(case_id, script)
    {:ok, id} = Durable.start(workflow, %{"case" => case_id}, opts)
    %{id: id, case_id: case_id, script: script}
  end

  defp family(id) do
    children =
      IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^id))

    [id | Enum.flat_map(children, &family(&1.id))]
  end

  defp open(ids) do
    for id <- ids, member <- family(id), get(member).status not in terminal(), do: member
  end

  defp drive(ids, tries \\ 800)

  defp drive(ids, 0) do
    stuck = for member <- open(ids), do: {describe(get(member)), Map.keys(get(member).context)}
    flunk("never finished: #{inspect(stuck, pretty: true)}")
  end

  defp drive(ids, tries) do
    case open(ids) do
      [] ->
        :ok

      members ->
        for member <- members, get(member).status == :waiting, do: answer_waits(member)
        SleepWaker.wake_now(Durable)
        Process.sleep(25)
        drive(ids, tries - 1)
    end
  end

  # ===========================================================================
  # Checking
  # ===========================================================================

  defp hits(case_id, name, what), do: Probe.hits({case_id, name, what})

  defp label(run, script), do: "#{inspect(script)}\n#{inspect(describe(run))}"

  # What holds whatever happened to the run.
  defp check_always(%{id: id, case_id: case_id, script: script}) do
    run = get(id)
    label = label(run, script)
    {_how, _done, never} = walk(@tree, script)

    assert run.status in terminal(), "not finished: #{label}"
    assert run.locked_by == nil, "left locked: #{label}"
    refute match?(%{"type" => "zombie_detected"}, run.error), "declared dead: #{label}"

    for name <- names(@tree) do
      done = hits(case_id, name, :done)
      assert done <= 1, "#{name} completed #{done} times: #{label}"
    end

    for name <- never do
      assert hits(case_id, name, :enter) == 0, "#{name} must never start: #{label}"
    end

    undone = hits(case_id, :undo, :first)
    assert undone <= 1, "undone #{undone} times: #{label}"
    if run.status == :compensated, do: assert(undone == 1, "never undone: #{label}")

    for member <- family(id) do
      row = get(member)
      assert row.status in terminal(), "family left open: #{inspect(describe(row))} #{label}"
      assert row.locked_by == nil, "family left locked: #{inspect(describe(row))} #{label}"

      # A lane stopped by a sibling's failure is closed by its own worker at
      # its next heartbeat, which can be after the run has ended.
      running =
        from(s in StepExecution,
          where: s.workflow_id == ^member and s.status == :running,
          select: {s.step_name, s.attempt, s.inserted_at}
        )

      left = still_running(running, 60)
      assert left == [], "a step row left running #{inspect(left)}: #{label}"

      for schema <- [PendingEvent, PendingInput], row.status == :completed do
        waits = from(p in schema, where: p.workflow_id == ^member and p.status == :pending)
        assert IntegrationRepo.aggregate(waits, :count) == 0, "wait left open: #{label}"
      end
    end
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

  # What a run nobody interfered with must have done, exactly.
  defp check_exactly(%{id: id, case_id: case_id, script: script} = started) do
    check_always(started)

    run = get(id)
    label = label(run, script)
    {how, done, _never} = walk(@tree, script)

    assert run.status in statuses(how, done), "status, modelled #{how}: #{label}"

    for name <- done do
      assert hits(case_id, name, :done) == 1, "#{name} never completed: #{label}"

      entered = hits(case_id, name, :enter)
      wanted = enters(script.steps[name])
      assert entered == wanted, "#{name} entered #{entered}, wanted #{wanted}: #{label}"
    end

    want_undone = if run.status == :compensated, do: 1, else: 0
    assert hits(case_id, :undo, :first) == want_undone, "undo count: #{label}"

    if run.status == :completed do
      assert length(family(id)) == 1 + lanes_run(@tree, script), "lane runs: #{label}"
      trail = check_data(@tree, script, [], run.context, label)
      assert run.context["trail"] == trail, "the run's trail: #{label}"
    end
  end

  # The order a run's data went through the steps: its own, and each lane's
  # under the block's name, starting from what the block was given.
  defp check_data(seq, script, trail, data, label) do
    Enum.reduce(seq, trail, fn
      {:step, name}, trail ->
        trail ++ [to_string(name)]

      {:branch, name, arms}, trail ->
        check_data(arms[script.arms[name]], script, trail ++ [to_string(name)], data, label)

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

  defp lanes_run(seq, script), do: seq |> Enum.map(&lanes_in(&1, script)) |> Enum.sum()

  defp lanes_in({:step, _name}, _script), do: 0
  defp lanes_in({:branch, name, arms}, script), do: lanes_run(arms[script.arms[name]], script)

  defp lanes_in({:parallel, _name, lanes}, script),
    do: Enum.sum(for {_lane, seq} <- lanes, do: 1 + lanes_run(seq, script))

  property "a run of nested branches and lanes does what its script says" do
    check all(
            scripts <- list_of(script(), length: 6),
            max_runs: @runs,
            max_shrinking_steps: 15
          ) do
      runs = Enum.map(scripts, &start_run/1)
      drive(Enum.map(runs, & &1.id))
      Enum.each(runs, &check_exactly/1)

      for %{id: id} <- runs, do: Probe.note({:ended, get(id).status})
    end

    for {queue, limit} <- @limits, queue != :default do
      assert Probe.peak({:queue, queue}) <= limit
    end

    # The generator has to keep reaching the far end of the tree, and every
    # way of ending short of it.
    ended = Map.new(terminal(), &{&1, Probe.hits({:ended, &1})})
    total = ended |> Map.values() |> Enum.sum()

    assert ended.completed * 5 >= total, "too few runs completed: #{inspect(ended)}"

    assert ended.compensated > 0 and ended.cancelled > 0,
           "an ending never seen: #{inspect(ended)}"
  end

  # ===========================================================================
  # Collecting
  # ===========================================================================

  @collect_lanes [
    a: [{:step, :a1}, {:step, :a2}],
    b: [
      {:step, :b1},
      {:parallel, :inner, i1: [{:step, :i1}], i2: [{:step, :i2}]},
      {:step, :b2}
    ],
    c: [{:step, :c}]
  ]
  @collect_after [{:step, :reduce}, {:step, :last}]
  @collect_steps [:first, :a1, :a2, :b1, :i1, :i2, :b2, :c, :reduce, :last]

  defp collect_script do
    gen all(actions <- fixed_list(Enum.map(@collect_steps, &action/1))) do
      # A cancel ends the whole run; here a step that would cancel fails.
      actions = Enum.map(actions, &if(&1 == :cancel, do: :fail, else: &1))
      %{steps: @collect_steps |> Enum.zip(actions) |> Map.new(), arms: %{}}
    end
  end

  # A lane that failed doesn't fail the block: only :first and what follows can.
  defp collect_model(script) do
    lanes = for {lane, seq} <- @collect_lanes, do: {lane, walk(seq, script)}
    {after_how, after_done, after_never} = walk(@collect_after, script)

    handed =
      Map.new(lanes, fn {lane, {how, _, _}} -> {lane, if(how == :done, do: :ok, else: :error)} end)

    if outcome(script.steps.first, :first) == :done do
      %{
        status: if(after_how == :done, do: :completed, else: :failed),
        done: [:first | Enum.flat_map(lanes, fn {_, {_, done, _}} -> done end)] ++ after_done,
        never: Enum.flat_map(lanes, fn {_, {_, _, never}} -> never end) ++ after_never,
        handed: handed,
        lane_runs:
          handed
          |> Map.values()
          |> Enum.frequencies_by(&if(&1 == :ok, do: :completed, else: :failed))
      }
    else
      %{
        status: :failed,
        done: [],
        never: @collect_steps -- [:first],
        handed: handed,
        lane_runs: %{}
      }
    end
  end

  defp check_collected(%{id: id, script: script} = started) do
    model = collect_model(script)
    check_modelled(started, model)
    run = get(id)
    if run.status == :completed, do: check_stored_pairs(run, model.handed, label(run, script))
  end

  # What a model of a block says of a run: how it ended, the steps that ran
  # once, the steps that never started, how its lanes' runs ended and what the
  # step after the block was handed.
  defp check_modelled(%{id: id, case_id: case_id, script: script}, model) do
    run = get(id)
    label = label(run, script)

    assert run.status == model.status, "status: #{label}"

    for name <- model.done do
      assert hits(case_id, name, :done) == 1, "#{name} completed other than once: #{label}"
      entered = hits(case_id, name, :enter)
      wanted = enters(script.steps[name])
      assert entered == wanted, "#{name} entered #{entered}, wanted #{wanted}: #{label}"
    end

    for name <- model.never do
      assert hits(case_id, name, :enter) == 0, "#{name} must never start: #{label}"
    end

    for member <- family(id), row = get(member) do
      assert row.status in terminal(), "family left open: #{inspect(describe(row))} #{label}"
      assert row.locked_by == nil, "family left locked: #{label}"
    end

    children =
      IntegrationRepo.all(
        from(w in WorkflowExecution, where: w.parent_workflow_id == ^id, select: w.status)
      )

    if model.lane_runs do
      assert Enum.frequencies(children) == model.lane_runs,
             "lane runs #{inspect(children)}: #{label}"
    end

    check_handed(case_id, model, label)
  end

  defp check_handed(case_id, model, label) do
    if model.handed && :reduce in model.done do
      assert Probe.fetch({case_id, :handed}) == model.handed, "what :reduce was handed: #{label}"
      Probe.note({:handed, model.handed |> Map.values() |> Enum.uniq() |> Enum.sort()})
    end
  end

  defp check_stored_pairs(run, handed, label) do
    for {lane, tag} <- handed do
      assert [stored, %{} = lane_data] = run.context["lookups"]["#{lane}"]
      assert stored == "#{tag}", "#{lane} stored as #{stored}: #{label}"
      trail = if tag == :ok, do: lane_data["trail"], else: ["first", "a lane's own steps"]
      assert List.last(trail) != "first", "#{lane}'s trail: #{label}"
    end

    assert run.context["trail"] == ["first", "reduce", "last"], "the run's trail: #{label}"
  end

  property "a block that collects hands the next step every lane, however each ended" do
    check all(
            scripts <- list_of(collect_script(), length: 6),
            max_runs: @runs,
            max_shrinking_steps: 15
          ) do
      runs = Enum.map(scripts, &start_run(&1, [], NamedCollect))
      drive(Enum.map(runs, & &1.id))
      Enum.each(runs, &check_collected/1)
    end

    # The mixed case is the point: some lanes through, some not.
    assert Probe.hits({:handed, [:error, :ok]}) > 0, "never reduced a mix of ok and failed lanes"
    assert Probe.hits({:handed, [:ok]}) > 0, "never reduced lanes that all finished"
  end

  # ===========================================================================
  # Optional lanes
  # ===========================================================================

  @optional_lanes [a: [{:step, :a1}, {:step, :a2}], b1: [{:step, :b1}], c: [{:step, :c}]]
  @optional_steps [:first, :a1, :a2, :b1, :c, :reduce, :last]

  defp optional_script do
    gen all(actions <- fixed_list(Enum.map(@optional_steps, &action/1))) do
      actions = Enum.map(actions, &if(&1 == :cancel, do: :fail, else: &1))
      %{steps: @optional_steps |> Enum.zip(actions) |> Map.new(), arms: %{}}
    end
  end

  # Lane :a failing costs nothing; :b1 or :c failing fails the block, and then
  # a lane is stopped wherever it has got to.
  defp optional_model(script) do
    lanes = for {lane, seq} <- @optional_lanes, do: {lane, walk(seq, script)}
    {after_how, after_done, after_never} = walk(@collect_after, script)
    required_done? = Enum.all?(lanes, fn {lane, {how, _, _}} -> lane == :a or how == :done end)
    never = Enum.flat_map(lanes, fn {_, {_, _, never}} -> never end)

    handed =
      Map.new(lanes, fn {lane, {how, _, _}} ->
        {lane, if(how == :done, do: :data, else: :nothing)}
      end)

    cond do
      outcome(script.steps.first, :first) != :done ->
        %{
          status: :failed,
          done: [],
          never: @optional_steps -- [:first],
          handed: nil,
          lane_runs: %{}
        }

      required_done? ->
        %{
          status: if(after_how == :done, do: :completed, else: :failed),
          done: [:first | Enum.flat_map(lanes, fn {_, {_, done, _}} -> done end)] ++ after_done,
          never: never ++ after_never,
          handed: handed,
          lane_runs:
            handed
            |> Map.values()
            |> Enum.frequencies_by(&if(&1 == :data, do: :completed, else: :failed))
        }

      true ->
        %{
          status: :failed,
          done: [:first],
          never: never ++ [:reduce, :last],
          handed: nil,
          lane_runs: nil
        }
    end
  end

  defp check_optional(%{id: id, case_id: case_id, script: script} = started) do
    run = get(id)
    label = label(run, script)
    model = optional_model(script)
    check_modelled(started, model)

    if model.handed && run.status == :completed do
      for {lane, came} <- model.handed do
        stored = run.context["lookups"]["#{lane}"]
        assert is_map(stored) == (came == :data), "#{lane} stored as #{inspect(stored)}: #{label}"
      end
    end

    for name <- @optional_steps do
      assert hits(case_id, name, :done) <= 1, "#{name} completed twice: #{label}"
    end
  end

  property "a lane the block can do without never fails it, and a lane it needs still does" do
    check all(
            scripts <- list_of(optional_script(), length: 6),
            max_runs: @runs,
            max_shrinking_steps: 15
          ) do
      runs = Enum.map(scripts, &start_run(&1, [], NamedOptional))
      drive(Enum.map(runs, & &1.id))
      Enum.each(runs, &check_optional/1)
    end

    assert Probe.hits({:handed, [:data, :nothing]}) > 0, "never went on without the optional lane"
    assert Probe.hits({:handed, [:data]}) > 0, "never reduced lanes that all finished"
  end

  # ===========================================================================
  # Retrying
  # ===========================================================================

  # The steps that started, didn't finish and never will as scripted.
  defp broken(case_id, script) do
    for {name, action} <- script.steps,
        outcome(action, name) != :done,
        hits(case_id, name, :enter) > 0,
        hits(case_id, name, :done) == 0,
        do: name
  end

  # Fixes what broke and retries, until the run gets through.
  defp retry_until_done(%{id: id, case_id: case_id} = run, script, rounds) do
    case get(id).status do
      :failed when rounds > 0 ->
        fixed = %{
          script
          | steps: Map.merge(script.steps, Map.new(broken(case_id, script), &{&1, :ok}))
        }

        assert fixed != script, "failed with nothing broken: #{label(get(id), script)}"

        :ok = Probe.put(case_id, fixed)
        assert {:ok, _} = Durable.retry(id), "couldn't retry: #{label(get(id), script)}"
        drive([id])
        retry_until_done(run, fixed, rounds - 1)

      _ended ->
        fixed_all = %{script | steps: Map.new(script.steps, fn {name, _} -> {name, :ok} end)}
        {script, fixed_all, length(names(@tree)) - rounds}
    end
  end

  property "a run that fails is fixed and retried until it's through" do
    check all(
            scripts <- list_of(script(), length: 6),
            max_runs: @runs,
            max_shrinking_steps: 15
          ) do
      # A cancelled run can't be retried, so here a step that would cancel fails.
      scripts =
        for script <- scripts do
          steps =
            Map.new(script.steps, fn {name, a} -> {name, if(a == :cancel, do: :fail, else: a)} end)

          %{script | steps: steps}
        end

      runs = Enum.map(scripts, &start_run(&1, [], NamedTreePlain))
      drive(Enum.map(runs, & &1.id))

      for %{id: id, case_id: case_id, script: script} = run <- runs do
        if get(id).status == :failed, do: Probe.note(:retried)
        {last, fixed_all, retries} = retry_until_done(run, script, length(names(@tree)))

        row = get(id)
        label = label(row, last)
        assert row.status == :completed, "not through: #{label}"

        {:done, done, never} = walk(@tree, fixed_all)

        # A lane is stopped where it stands when another lane fails. If that is
        # after a step's result was recorded and before the lane moved on, the
        # retry runs that one step again: the engine promises a step at least
        # once. So a run may repeat one step for each time it was retried, and
        # a run that was never retried repeats nothing.
        members = family(id)
        rows = IntegrationRepo.all(from(s in StepExecution, where: s.workflow_id in ^members))

        for member <- members do
          repeated =
            rows
            |> Enum.filter(&(&1.workflow_id == member and &1.status == :completed))
            |> Enum.frequencies_by(& &1.step_name)
            |> Enum.filter(fn {_step, times} -> times > 1 end)

          allowed = if get(member).retried_at, do: retries, else: 0

          assert length(repeated) <= allowed and
                   Enum.all?(repeated, fn {_step, times} -> times <= 1 + retries end),
                 "repeated #{inspect(repeated)} over #{retries} retries: #{label}"
        end

        for name <- done do
          own = Enum.filter(rows, &(List.last(String.split(&1.step_name, "__")) == "#{name}"))
          recorded = Enum.count(own, &(&1.status == :completed))
          count = hits(case_id, name, :done)

          assert recorded >= 1, "#{name} has no completed row: #{label}"

          # Each time its body got to the end, in an attempt of its own.
          assert count in recorded..length(own)//1,
                 "#{name} finished #{count} times in #{length(own)} attempts, " <>
                   "#{recorded} recorded: #{label}"
        end

        for name <- never do
          assert hits(case_id, name, :enter) == 0, "#{name} must never start: #{label}"
        end

        assert length(members) == 1 + lanes_run(@tree, fixed_all), "lane runs: #{label}"
        for member <- members, do: assert(get(member).status == :completed, "a lane: #{label}")

        trail = check_data(@tree, fixed_all, [], row.context, label)
        assert row.context["trail"] == trail, "the run's trail: #{label}"
      end
    end

    assert Probe.hits(:retried) > 0, "no run ever needed a retry"
  end

  # ===========================================================================
  # Chaos
  # ===========================================================================

  @batch 6

  defp op do
    index = integer(0..(@batch - 1))

    one_of([
      tuple({constant(:cancel), index}),
      tuple({constant(:retry), index}),
      tuple({constant(:retry), index}),
      tuple({constant(:cancel_lane), index}),
      constant(:sweep),
      constant(:recover),
      constant(:recover),
      constant(:wake_sleepers),
      tuple({constant(:pause), member_of(@queues)}),
      tuple({constant(:resume), member_of(@queues)}),
      tuple({constant(:wait), integer(0..40)})
    ])
  end

  defp apply_op({:cancel, i}, runs) do
    Durable.cancel(Enum.at(runs, i).id, "chaos")
    [i]
  end

  defp apply_op({:retry, i}, runs) do
    Durable.retry(Enum.at(runs, i).id)
    [i]
  end

  # An operator cancels one lane's run, not the workflow.
  defp apply_op({:cancel_lane, i}, runs) do
    case family(Enum.at(runs, i).id) do
      [_run, lane | _] -> Durable.cancel(lane, "chaos")
      _no_lanes_yet -> :ok
    end

    [i]
  end

  defp apply_op(:sweep, _runs) do
    TimeoutWorker.check_timeouts(Durable)
    []
  end

  defp apply_op(:recover, _runs) do
    config = Config.get(Durable)
    Postgres.recover_stale_locks(config, 1)
    Postgres.recover_zombie_workflows(config, 1)
    []
  end

  defp apply_op(:wake_sleepers, _runs) do
    SleepWaker.wake_now(Durable)
    []
  end

  defp apply_op({:pause, queue}, _runs) do
    Durable.pause_queue(queue)
    []
  end

  defp apply_op({:resume, queue}, _runs) do
    Durable.resume_queue(queue)
    []
  end

  defp apply_op({:wait, ms}, _runs) do
    Process.sleep(ms)
    []
  end

  defp quiesce do
    assert_eventually(
      fn -> Enum.all?(@queues, &(Manager.status(Durable, &1).active_jobs == 0)) end,
      10_000,
      10
    )
  end

  property "operators and sweeps never hang a tree, repeat a step or disturb the others" do
    check all(
            scripts <- list_of(script(), length: @batch),
            ops <- list_of(op(), min_length: 4, max_length: 20),
            max_runs: @runs,
            max_shrinking_steps: 15
          ) do
      runs = Enum.map(scripts, &start_run/1)

      touched =
        ops
        |> Task.async_stream(&apply_op(&1, runs), max_concurrency: 4, timeout: 30_000)
        |> Enum.flat_map(fn {:ok, indexes} -> indexes end)
        |> MapSet.new()

      for queue <- @queues, do: Durable.resume_queue(queue)
      drive(Enum.map(runs, & &1.id))
      quiesce()

      for {run, i} <- Enum.with_index(runs) do
        if i in touched, do: check_always(run), else: check_exactly(run)
      end
    end
  end
end
