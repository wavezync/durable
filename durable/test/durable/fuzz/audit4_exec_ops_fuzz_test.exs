defmodule Durable.Fuzz.Audit4ExecOpsTest do
  @moduledoc """
  One workflow key, a generated run behind it, and an operator acting at
  random: cancel, cancel and roll back, retry, roll back, run again, release
  the key, answer an input, start again in every `on_duplicate:` mode. Under
  each `reuse:` policy and both `on_failure:` settings.

  Runs are drained inline, so every state checked is a settled one. What must
  hold after every action:

    * a run that ended stays ended, and each action answers by the status it found
    * a completed step never runs again, and nothing is undone unless the run
      was rolled back; then every completed step is undone once, newest first
    * one run at most is live for the key, and it holds the key
    * a start is never handed a run that was rolled back, unless `reuse: :never`
    * no run or step row is left open under a run that ended
  """
  use Durable.DataCase, async: false
  use ExUnitProperties

  import Durable.Testing

  alias Durable.Storage.Schemas.{PendingInput, StepExecution, WorkflowExecution}
  alias Durable.TestRepo, as: Repo

  @moduletag :fuzz
  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "60"))
  @table :audit4_exec_ops_seen

  @ended [:completed, :failed, :cancelled, :compensated, :compensation_failed]
  @rolled_back [:compensated, :compensation_failed]
  @reusable %{
    "after_close" => @ended,
    "after_failure" => @ended -- [:completed],
    "never" => []
  }
  # Which undo answers for which step, oldest step first.
  @undos [s1: :u1, l1: :ul, s2: :u2]
  @steps [:s1, :l1, :a1, :b1, :s2, :s3]

  defmodule Audit4ExecSeen do
    @moduledoc false
    @table :audit4_exec_ops_seen

    def note(event) do
      :ets.insert(@table, {event, System.unique_integer([:monotonic])})
      count(event)
    end

    def count(event), do: length(:ets.lookup(@table, event))

    # Every event of `kind` for `run`, oldest first.
    def of(kind, run) do
      @table
      |> :ets.match_object({{kind, run, :_}, :_})
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.map(fn {{_kind, _run, name}, _at} -> name end)
    end
  end

  defmodule Audit4ExecActs do
    @moduledoc false
    use Durable.Wait

    alias Durable.Context
    alias Durable.Fuzz.Audit4ExecOpsTest.Audit4ExecSeen, as: Seen

    def pick(data), do: {String.to_existing_atom(data["script"]["pick"]), data}

    # What the script says `name` does. The `_once` ones do it the first time
    # the step is entered in a run, so a retry gets past them.
    def act(data, name) do
      run = Context.workflow_id()
      entry = Seen.note({:entered, run, name})

      case {data["script"][Atom.to_string(name)], entry} do
        {"fail", _} -> {:fail, "#{name} can't be done"}
        {"rollback", _} -> {:rollback, "#{name} wants it all undone"}
        {"input", _} -> asked(data, name, run)
        {once, 1} -> once(once, name) || done(data, name, run)
        _ok -> done(data, name, run)
      end
    end

    defp once("fail_once", name), do: {:fail, "#{name} failed"}
    defp once("error_once", name), do: {:error, "#{name} errored"}
    defp once("raise_once", name), do: raise("#{name} raised")
    defp once("throw_once", name), do: throw({:thrown_by, name})
    defp once("exit_once", name), do: exit({:exited, name})
    defp once("cancel_once", name), do: {:cancel, "#{name} called it off"}
    defp once(_ok, _name), do: nil

    defp asked(data, name, run) do
      wait_for_input("in_#{name}")
      done(data, name, run)
    end

    defp done(data, name, run) do
      Seen.note({:ran, run, name})
      {:ok, data}
    end

    def undo(data, name) do
      Seen.note({:undo, Context.workflow_id(), name})

      case data["script"][Atom.to_string(name)] do
        "error" -> {:error, "#{name} errored"}
        "raise" -> raise "#{name} raised"
        "throw" -> throw({:thrown_by, name})
        "exit" -> exit({:exited, name})
        _ok -> {:ok, data}
      end
    end
  end

  defmodule Audit4ExecFlowDsl do
    @moduledoc false

    # The same steps under each `reuse:` and `on_failure:`.
    defmacro flow(name, opts) do
      acts = Durable.Fuzz.Audit4ExecOpsTest.Audit4ExecActs

      quote bind_quoted: [], unquote: true do
        workflow unquote(name), unquote(opts) do
          step(:s1, [compensate: :u1], fn data -> unquote(acts).act(data, :s1) end)

          branch :pick, fn data -> unquote(acts).pick(data) end do
            :left ->
              step(:l1, [compensate: :ul], fn data -> unquote(acts).act(data, :l1) end)

            :right ->
              parallel :fan do
                lane :a do
                  step(:a1, fn data -> unquote(acts).act(data, :a1) end)
                end

                lane :b do
                  step(:b1, fn data -> unquote(acts).act(data, :b1) end)
                end
              end

            :skip ->
              pass()
          end

          step(:s2, [compensate: :u2, retry: [max_attempts: 2]], fn data ->
            unquote(acts).act(data, :s2)
          end)

          step(:s3, fn data -> unquote(acts).act(data, :s3) end)

          compensate(:u1, fn data -> unquote(acts).undo(data, :u1) end)
          compensate(:ul, fn data -> unquote(acts).undo(data, :ul) end)
          compensate(:u2, fn data -> unquote(acts).undo(data, :u2) end)
        end
      end
    end
  end

  defmodule Audit4ExecFlow do
    use Durable

    import Durable.Fuzz.Audit4ExecOpsTest.Audit4ExecFlowDsl

    flow("ops_after_close_halt", reuse: :after_close, on_failure: :halt)
    flow("ops_after_close_rollback", reuse: :after_close, on_failure: :rollback)
    flow("ops_after_failure_halt", reuse: :after_failure, on_failure: :halt)
    flow("ops_after_failure_rollback", reuse: :after_failure, on_failure: :rollback)
    flow("ops_never_halt", reuse: :never, on_failure: :halt)
    flow("ops_never_rollback", reuse: :never, on_failure: :rollback)
  end

  setup do
    :ets.new(@table, [:named_table, :public, :duplicate_bag])
    :ok
  end

  # ===========================================================================
  # Generating
  # ===========================================================================

  defp behaviour do
    frequency([
      {8, constant("ok")},
      {2, constant("fail_once")},
      {1, constant("fail")},
      {1, constant("rollback")},
      {2, member_of(~w(error_once raise_once throw_once exit_once))},
      {1, constant("cancel_once")},
      {2, constant("input")}
    ])
  end

  defp script do
    gen all(
          acts <- fixed_list(Enum.map(@steps, fn _ -> behaviour() end)),
          undos <- list_of(member_of(~w(ok ok ok error raise throw exit)), length: 3),
          pick <- member_of(~w(left right skip))
        ) do
      steps = Map.new(Enum.zip(Enum.map(@steps, &Atom.to_string/1), acts))
      undos = Map.new(Enum.zip(~w(u1 ul u2), undos))
      steps |> Map.merge(undos) |> Map.put("pick", pick)
    end
  end

  # An action names a run by position among those started so far.
  defp action do
    one_of([
      tuple({constant(:start), member_of([:use_existing, :error, :cancel_existing, :run_again])}),
      tuple({constant(:start), member_of([:use_existing, :error, :cancel_existing, :run_again])}),
      tuple({constant(:cancel), integer(0..5), boolean()}),
      tuple({constant(:retry), integer(0..5)}),
      tuple({constant(:retry), integer(0..5)}),
      tuple({constant(:rollback), integer(0..5)}),
      tuple({constant(:rerun), integer(0..5)}),
      tuple({constant(:release), integer(0..5)}),
      tuple({constant(:input), integer(0..5)}),
      tuple({constant(:input), integer(0..5)})
    ])
  end

  defp scenario do
    gen all(
          reuse <- member_of(~w(after_close after_failure never)),
          on_failure <- member_of(~w(halt rollback)),
          scripts <- list_of(script(), length: 4),
          actions <- list_of(action(), min_length: 3, max_length: 9)
        ) do
      %{reuse: reuse, on_failure: on_failure, scripts: scripts, actions: actions}
    end
  end

  # ===========================================================================
  # Reading what happened
  # ===========================================================================

  defp get(id), do: Repo.get!(WorkflowExecution, id)

  defp tree(ids) do
    more =
      Repo.all(
        from(w in WorkflowExecution,
          where: w.parent_workflow_id in ^ids and w.id not in ^ids,
          select: w.id
        )
      )

    if more == [], do: ids, else: tree(ids ++ more)
  end

  defp keyed(key), do: Repo.all(from(w in WorkflowExecution, where: w.key == ^key))

  defp pending_inputs(id) do
    Repo.all(
      from(p in PendingInput,
        where: p.workflow_id in ^tree([id]) and p.status == :pending,
        select: {p.workflow_id, p.input_name}
      )
    )
  end

  # Waiting for a turn with the key, behind a run that hasn't ended.
  defp behind?(%{status: :pending, runs_after_id: id}) when is_binary(id),
    do: get(id).status not in @ended

  defp behind?(_run), do: false

  defp live?(run), do: run.status not in @ended and not behind?(run)

  defp settle(state) do
    for _round <- 1..3, id <- state.ids, do: drain(id)
    state
  end

  # ===========================================================================
  # Acting
  # ===========================================================================

  defp at(state, i), do: Enum.at(state.ids, rem(i, length(state.ids)))

  defp start(state, mode) do
    script = Enum.at(state.scripts, rem(length(state.ids), length(state.scripts)))
    before = keyed(state.key)

    result =
      Durable.start(Audit4ExecFlow, %{"script" => script},
        workflow: state.workflow,
        key: state.key,
        on_duplicate: mode,
        return: :details
      )

    check_start(state, mode, before, result)

    case result do
      {:ok, %{id: id, created: true}} -> %{state | ids: state.ids ++ [id]}
      _handed_or_refused -> state
    end
  end

  defp act(state, {:start, :run_again}) when state.reuse == "never", do: state
  defp act(state, {:start, mode}), do: start(state, mode)

  defp act(state, {:cancel, i, rollback?}) do
    id = at(state, i)
    was = get(id).status
    result = Durable.cancel(id, "operator", rollback: rollback?)

    if was in @ended,
      do:
        assert(
          result == {:error, :already_completed},
          "cancel of a #{was} run: #{inspect(result)}"
        ),
      else: assert(result == :ok, "cancel of a #{was} run: #{inspect(result)}")

    state
  end

  defp act(state, {:retry, i}),
    do: retry_or_roll_back(state, at(state, i), &Durable.retry/1, true)

  defp act(state, {:rollback, i}),
    do: retry_or_roll_back(state, at(state, i), &Durable.rollback/1, false)

  defp act(state, {:rerun, i}) do
    id = at(state, i)
    was = get(id).status
    before = keyed(state.key)
    result = Durable.rerun(id)

    case result do
      {:ok, new} ->
        assert was in @ended, "a #{was} run was run again"
        refute Enum.any?(before, &live?/1), "run again beside a live run: #{label(state)}"
        %{state | ids: state.ids ++ [new]}

      {:error, {:key_taken, holder}} ->
        assert was in @ended
        assert_keeps_key(state, holder)
        state

      {:error, :not_finished} ->
        assert was not in @ended
        state
    end
  end

  defp act(state, {:release, i}) do
    id = at(state, i)
    run = get(id)
    result = Durable.release_key(id)

    cond do
      not run.holds_key -> assert result == {:error, :no_key}
      run.status in @ended -> assert result == :ok
      true -> assert result == {:error, :not_finished}
    end

    state
  end

  defp act(state, {:input, i}) do
    for {run, name} <- pending_inputs(at(state, i)) do
      assert :ok == Durable.provide_input(run, name, %{"answered" => true})
    end

    state
  end

  defp retry_or_roll_back(state, id, fun, takes_key?) do
    was = get(id).status
    result = fun.(id)

    case result do
      {:ok, ^id} ->
        assert was == :failed, "#{inspect(fun)} took a #{was} run"

      {:error, :rolled_back} ->
        assert was in @rolled_back

      {:error, :not_failed} ->
        assert was not in [:failed | @rolled_back]

      {:error, {:key_taken, holder}} ->
        assert was == :failed and takes_key?
        assert_keeps_key(state, holder)
    end

    state
  end

  # ===========================================================================
  # Checking
  # ===========================================================================

  defp label(state),
    do: inspect(Map.take(state, [:workflow, :key, :done]), limit: :infinity, pretty: true)

  # Whoever is said to have the key has it, and may keep it from the caller.
  defp assert_keeps_key(state, holder_id) do
    holder = get(holder_id)
    assert holder.holds_key, "#{holder_id} was named as the holder: #{label(state)}"

    assert holder.status not in @reusable[state.reuse],
           "a #{holder.status} holder kept its key under reuse: #{state.reuse}: #{label(state)}"
  end

  defp check_start(state, _mode, _before, {:ok, %{id: id, created: false}}) do
    handed = get(id)

    assert handed.status not in @reusable[state.reuse] or behind?(handed),
           "a start was handed a #{handed.status} run it could have replaced: #{label(state)}"

    refute is_map_key(handed.engine_state, "__rollback__") and state.reuse != "never",
           "a start was handed a run that is being rolled back: #{label(state)}"
  end

  defp check_start(state, mode, before, {:ok, %{id: id, created: true}}) do
    live? = Enum.any?(before, &live?/1)

    assert not live? or mode in [:cancel_existing, :run_again],
           "#{mode} started a run beside a live one: #{label(state)}"

    # Beside a live run, run_again only ever adds one that waits its turn.
    assert not live? or mode != :run_again or behind?(get(id)),
           "run_again started a run that doesn't wait: #{label(state)}"
  end

  defp check_start(state, mode, _before, {:error, {:key_taken, holder}}) do
    assert mode != :use_existing, "use_existing was refused: #{label(state)}"
    assert_keeps_key(state, holder)
  end

  defp verify(state) do
    runs = keyed(state.key)

    assert length(Enum.filter(runs, & &1.holds_key)) <= 1, "two holders: #{label(state)}"

    case Enum.filter(runs, &live?/1) do
      [] -> :ok
      [one] -> assert one.holds_key, "the live run doesn't hold its key: #{label(state)}"
      many -> flunk("#{length(many)} live runs for one key: #{label(state)}")
    end

    Enum.each(state.ids, &check_run(state, get(&1)))
    for id <- state.ids, do: Audit4ExecSeen.note({:ended, get(id).status})
    %{state | last: Map.new(state.ids, &{&1, get(&1).status})}
  end

  defp check_run(state, run) do
    where = "#{run.status} #{String.slice(run.id, 0, 8)}: #{label(state)}"
    under = tree([run.id])

    was = state.last[run.id]
    # Only a failed run can be reopened, and only an open one cancelled.
    assert was in [nil, :pending, :waiting, :failed] or run.status == was,
           "a #{was} run became #{where}"

    refute is_map_key(run.engine_state, "__rollback__"), "still to be rolled back: #{where}"

    cond do
      run.status in @ended -> check_ended(run, under, where)
      run.status == :waiting -> assert pending_inputs(run.id) != [], "waits on nothing: #{where}"
      true -> assert behind?(run), "neither ended nor waiting: #{where}"
    end

    for id <- under, name <- @steps do
      assert Audit4ExecSeen.count({:ran, id, name}) <= 1, "#{name} completed twice: #{where}"
    end

    check_undone(run, where)
  end

  defp check_ended(run, under, where) do
    open =
      Repo.all(
        from(w in WorkflowExecution,
          where: w.id in ^under and w.status not in ^@ended,
          select: {w.current_step, w.status}
        )
      )

    assert open == [], "runs left open #{inspect(open)} under #{where}"

    rows =
      Repo.all(
        from(s in StepExecution,
          where: s.workflow_id in ^under and s.status in [:pending, :running],
          select: {s.step_name, s.status}
        )
      )

    assert rows == [], "step rows left open #{inspect(rows)} under #{where}"
    assert pending_inputs(run.id) == [], "an input still asked for under #{where}"
  end

  # Nothing is undone unless the run was rolled back; then every step that
  # completed is undone once, the newest first.
  defp check_undone(run, where) do
    undone = Audit4ExecSeen.of(:undo, run.id)

    completed =
      for {step, undo} <- @undos, Audit4ExecSeen.count({:ran, run.id, step}) == 1, do: undo

    if run.status in @rolled_back do
      assert undone == Enum.reverse(completed), "undid #{inspect(undone)}: #{where}"
      failed? = Enum.any?(undone, &(run.input["script"][Atom.to_string(&1)] != "ok"))
      assert run.status == if(failed?, do: :compensation_failed, else: :compensated), where
    else
      assert undone == [], "undid #{inspect(undone)} without a rollback: #{where}"
    end
  end

  # ===========================================================================
  # The property
  # ===========================================================================

  property "whatever an operator does to the runs of one key, each ends once and the key has one holder" do
    check all(scenario <- scenario(), max_runs: @runs, max_shrinking_steps: 40) do
      state = %{
        key: "ops-#{System.unique_integer([:positive])}",
        workflow: "ops_#{scenario.reuse}_#{scenario.on_failure}",
        reuse: scenario.reuse,
        scripts: scenario.scripts,
        ids: [],
        last: %{},
        done: []
      }

      state = state |> start(:use_existing) |> settle() |> verify()
      assert [_first] = state.ids

      Enum.reduce(scenario.actions, state, fn action, state ->
        state = %{state | done: state.done ++ [action]}
        state |> act(action) |> settle() |> verify()
      end)
    end

    # The generator has to reach every way a run can end, or this checks little.
    for status <- [:waiting | @ended] do
      assert Audit4ExecSeen.count({:ended, status}) > 0, "no run was ever #{status}"
    end
  end
end
