defmodule Durable.Fuzz.ShapesTest do
  @moduledoc """
  Branches, parallel blocks, child workflows and goto, checked against a model,
  and concurrent starts on one workflow key.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  import Durable.FuzzScripts, only: [answer_waits: 1, describe: 1, terminal: 0]

  alias Durable.FuzzWorkflows.{Keyed, KeyedAgain, Tree}
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput}
  alias Durable.Wait.SleepWaker

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "40"))
  @limits %{default: 10, q_a: 3, q_b: 3}

  setup do
    start_durable!(@limits)
    :ok
  end

  defp action do
    one_of([
      constant(:ok),
      constant(:ok),
      constant(:ok),
      constant(:fail),
      constant(:sleep),
      constant(:event),
      tuple({constant(:error), integer(1..4)}),
      tuple({constant(:snooze), integer(1..2)})
    ])
  end

  defp tree_script do
    gen all(
          actions <- fixed_list(for _ <- 1..11, do: action()),
          path <- member_of(["a", "b", "c"]),
          child <- member_of([:ok, :ok, :fail, :cancel]),
          route <- member_of([:last, :next])
        ) do
      names = [:first, :a1, :a2, :b1, :c1, :p1, :p2, :p3, :call, :skipped, :last]
      %{steps: names |> Enum.zip(actions) |> Map.new(), path: path, child: child, route: route}
    end
  end

  # No retry option on these: one error fails the step.
  defp fails?({:error, times}, step) when step in [:a1, :b1], do: times >= 3
  defp fails?({:error, _times}, _step), do: true
  defp fails?(:fail, _step), do: true
  defp fails?(_action, _step), do: false

  defp clause_steps("a"), do: [:a1, :a2]
  defp clause_steps("b"), do: [:b1]
  defp clause_steps(_), do: [:c1]

  defp walk([], _script, done), do: {:completed, done}

  defp walk([step | rest], script, done) do
    if fails?(script.steps[step], step),
      do: {:failed, done},
      else: walk(rest, script, [step | done])
  end

  # What must happen: {status, sequential steps that must have completed}.
  defp tree_model(script) do
    before_parallel = [:first | clause_steps(script.path)]

    with {:completed, done} <- walk(before_parallel, script, []),
         :ok <-
           if(Enum.any?([:p1, :p2, :p3], &fails?(script.steps[&1], &1)),
             do: {:failed_in_parallel, done},
             else: :ok
           ),
         :ok <- if(script.child != :ok, do: {:failed_in_child, done}, else: :ok) do
      after_call = if(script.route == :last, do: [:call, :last], else: [:call, :skipped, :last])

      case walk(after_call, script, done) do
        {:completed, done} -> {:completed, done, :parallel_ok}
        {:failed, done} -> {:failed, done, :parallel_ok}
      end
    else
      {:failed, done} -> {:failed, done, :not_reached}
      {:failed_in_parallel, done} -> {:failed, done, :parallel_failed}
      {:failed_in_child, done} -> {:failed, done, :parallel_ok}
    end
  end

  defp expected_status(:completed, _done), do: :completed

  defp expected_status(:failed, done) do
    if :first in done, do: :compensated, else: :failed
  end

  defp family(id) do
    children =
      IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^id))

    [id | Enum.flat_map(children, &family(&1.id))]
  end

  defp drive_tree(ids, tries \\ 500)

  defp drive_tree(ids, 0) do
    stuck =
      for id <- ids,
          member <- family(id),
          get(member).status not in terminal(),
          do: {describe(get(member)), Map.keys(get(member).context)}

    flunk("never finished: #{inspect(stuck, pretty: true)}")
  end

  defp drive_tree(ids, tries) do
    open = for id <- ids, member <- family(id), get(member).status not in terminal(), do: member

    if open != [] do
      for member <- open, get(member).status == :waiting, do: answer_waits(member)
      SleepWaker.wake_now(Durable)
      Process.sleep(25)
      drive_tree(ids, tries - 1)
    end
  end

  defp entered?(case_id, step), do: Probe.hits({case_id, step, :enter}) > 0
  defp done_count(case_id, step), do: Probe.hits({case_id, step, :done})

  defp assert_done_once(case_id, step, label) do
    done = done_count(case_id, step)
    entered = Probe.hits({case_id, step, :enter})
    assert done == 1, "#{step} done #{done} times, entered #{entered} times: #{label}"
  end

  defp check_tree(%{id: id, case_id: case_id, script: script}) do
    {outcome, done, parallel} = tree_model(script)
    run = get(id)
    label = "#{inspect(script)}\n#{inspect(describe(run))}"

    assert run.status == expected_status(outcome, done), "status: #{label}"
    assert run.locked_by == nil, "left locked: #{label}"

    for step <- done, do: assert_done_once(case_id, step, label)

    check_path(case_id, script, done, label)
    check_parallel(case_id, parallel, label)

    undone = Probe.hits({case_id, :undo, :first})
    want = if run.status == :compensated, do: 1, else: 0
    assert undone == want, "undone #{undone} times: #{label}"

    for member <- family(id), do: check_member(get(member), label)
  end

  defp check_path(case_id, script, done, label) do
    others = Enum.flat_map(["a", "b", "c"] -- [script.path], &clause_steps/1)

    for step <- others,
        do: refute(entered?(case_id, step), "other clause's #{step} ran: #{label}")

    if script.route == :last and :call in done do
      refute entered?(case_id, :skipped), "goto didn't skip: #{label}"
    end
  end

  defp check_parallel(case_id, :parallel_ok, label) do
    for step <- [:p1, :p2, :p3], do: assert_done_once(case_id, step, label)
  end

  defp check_parallel(case_id, :not_reached, label) do
    for step <- [:p1, :p2, :p3], do: refute(entered?(case_id, step), "#{step} ran: #{label}")
  end

  defp check_parallel(_case_id, :parallel_failed, _label), do: :ok

  defp check_member(row, label) do
    assert row.status in terminal(), "family left open: #{inspect(describe(row))} #{label}"

    for schema <- [PendingEvent, PendingInput], row.status == :completed do
      open = from(p in schema, where: p.workflow_id == ^row.id and p.status == :pending)
      assert IntegrationRepo.aggregate(open, :count) == 0, "wait left open: #{label}"
    end
  end

  property "a run with every shape does what its script says" do
    check all(
            scripts <- list_of(tree_script(), length: 6),
            max_runs: @runs,
            max_shrinking_steps: 15
          ) do
      runs =
        for script <- scripts do
          case_id = System.unique_integer([:positive])
          :ok = Probe.put(case_id, script)
          {:ok, id} = Durable.start(Tree, %{"case" => case_id})
          %{id: id, case_id: case_id, script: script}
        end

      drive_tree(Enum.map(runs, & &1.id))
      Enum.each(runs, &check_tree/1)
    end

    for {queue, limit} <- @limits, queue != :default do
      assert Probe.peak({:queue, queue}) <= limit
    end
  end

  # ===========================================================================
  # Keys
  # ===========================================================================

  defp start_keyed(workflow, key, n, ms, opts \\ []) do
    Durable.start(workflow, %{"fuzz_key" => key, "n" => n, "ms" => ms}, [key: key] ++ opts)
  end

  defp open_runs(key) do
    IntegrationRepo.all(
      from(w in WorkflowExecution,
        where: w.key == ^key and w.status in [:pending, :running, :waiting]
      )
    )
  end

  defp settle(key) do
    assert_eventually(fn -> open_runs(key) == [] end, 20_000, 15)
  end

  defp ran(key, starts) do
    for n <- 1..starts, do: {n, Probe.hits({:key_ran, key, n})}
  end

  property "use_existing: concurrent starts share one run" do
    check all(
            starts <- integer(2..12),
            ms <- integer(1..40),
            max_runs: @runs,
            max_shrinking_steps: 10
          ) do
      key = "k#{System.unique_integer([:positive])}"

      ids =
        1..starts
        |> Task.async_stream(&start_keyed(Keyed, key, &1, ms), max_concurrency: 12)
        |> Enum.map(fn {:ok, {:ok, id}} -> id end)

      settle(key)
      assert Probe.peak({:key, key}) == 1, "two runs of #{key} at once"

      # Every start got a run that was open, or a new one once the last closed.
      assert ids |> Enum.uniq() |> length() ==
               Enum.sum(for {_n, hits} <- ran(key, starts), do: hits)
    end
  end

  property "run_again: one at a time, and nothing started during a run is lost" do
    check all(
            gaps <- list_of(integer(0..25), min_length: 2, max_length: 10),
            ms <- integer(5..40),
            max_runs: @runs,
            max_shrinking_steps: 10
          ) do
      key = "k#{System.unique_integer([:positive])}"

      for {gap, n} <- Enum.with_index(gaps, 1) do
        assert {:ok, _id} = start_keyed(KeyedAgain, key, n, ms)
        Process.sleep(gap)
      end

      settle(key)

      assert Probe.peak({:key, key}) == 1, "two runs of #{key} at once"

      # The last start's input ran, so the last change was picked up.
      last = length(gaps)

      assert Probe.hits({:key_ran, key, last}) >= 1,
             "the last start never ran: #{inspect(ran(key, last))}"
    end
  end
end
