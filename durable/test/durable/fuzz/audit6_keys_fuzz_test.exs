defmodule Durable.Fuzz.Audit6KeysFuzzTest do
  @moduledoc """
  Audit 6: random starts, cancels, retries, rollbacks and kills over a few
  keys, on two live nodes, checked against what workflow_keys.md promises:

    * one run of a key at a time: no two steps of a key's runs are going at once
    * the newest input runs last: each case ends with a run_again start on
      every key, and that input is the last to run
    * nothing is stuck: once the ops stop, every run ends and the key is free

  Failures that match a bug already reported (issue #48) are counted and
  printed, not failed on: see `known/3`.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  alias Durable.Config
  alias Durable.KeyWorkflows, as: K
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Storage.Schemas.ActivityEvent

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "50"))
  @open [:pending, :running, :waiting, :compensating]
  @settle_ms 20_000

  setup do
    start_supervised!(K.Ledger)
    start_durable!(%{default: 4})
    peer = start_node!(:keys_b, %{default: 4})
    {:ok, peer: peer}
  end

  # ===========================================================================
  # Ops
  # ===========================================================================

  # Most ops run one after another; some go on in the background, racing the
  # ops after them.
  defp op do
    frequency([
      {4, step()},
      {1, tuple({constant(:async), step()})},
      {1,
       tuple({constant(:async), tuple({constant(:hold_lock), integer(0..2), integer(20..400)})})}
    ])
  end

  defp step do
    key = integer(0..2)
    run = integer(0..9)

    frequency([
      {6, tuple({constant(:start), key, constant(:run_again), spec(), where()})},
      {2,
       tuple(
         {constant(:start), key, member_of([:use_existing, :cancel_existing, :error]), spec(),
          where()}
       )},
      {2, tuple({constant(:burst), key, integer(2..6)})},
      {1, tuple({constant(:start_many), list_of(key, min_length: 1, max_length: 5), where()})},
      {1, tuple({constant(:release), key, run})},
      {2, tuple({constant(:cancel), key, run})},
      {1, tuple({constant(:cancel_undo), key, run})},
      {2, tuple({constant(:retry), key, run})},
      {2, tuple({constant(:retry_when_idle), key, run})},
      {1, tuple({constant(:rollback), key, run})},
      {2, tuple({constant(:kill_task), key})},
      {1, tuple({constant(:kill_worker), key})},
      {1, tuple({constant(:kill_claimed), key, member_of([:task, :worker])})},
      {1, constant(:recover)},
      {4, tuple({constant(:wait), integer(0..80)})}
    ])
  end

  defp spec do
    fixed_map(%{
      "ms" => one_of([integer(0..20), integer(30..150)]),
      "save_ms" => integer(0..30),
      "fail" => frequency([{2, constant(false)}, {1, constant(true)}])
    })
  end

  defp where, do: member_of([:here, :peer])

  defp apply_op({:start, k, mode, spec, where}, ctx) do
    key = Enum.at(ctx.keys, k)
    input = Map.merge(spec, %{"key" => key, "v" => System.unique_integer([:positive])})
    opts = if mode == :run_again, do: [key: key], else: [key: key, on_duplicate: mode]
    result = on(where, ctx, Durable, :start, [workflow(key), input, opts])
    [{:start, key, input["v"], mode, result}]
  end

  defp apply_op({:burst, k, n}, ctx) do
    1..n
    |> Task.async_stream(fn i ->
      apply_op({:start, k, :run_again, %{"ms" => 5}, Enum.at([:here, :peer], rem(i, 2))}, ctx)
    end)
    |> Enum.flat_map(fn {:ok, records} -> records end)
  end

  # One batch: starts of several keys, a key more than once.
  defp apply_op({:start_many, ks, where}, ctx) do
    items =
      for k <- ks do
        key = Enum.at(ctx.keys, k)
        input = %{"key" => key, "v" => System.unique_integer([:positive]), "ms" => 5}
        {workflow(key), input, [key: key]}
      end

    results = on(where, ctx, Durable, :start_many, [items])

    for {{_module, input, opts}, result} <- Enum.zip(items, results),
        do: {:start_many, opts[:key], input["v"], :run_again, result}
  end

  # A finished holder lets its key go, as an operator would.
  defp apply_op({:release, k, i}, ctx) do
    case runs_of(Enum.at(ctx.keys, k), [:completed, :failed, :cancelled]) do
      [] -> []
      ids -> [{:release, Durable.release_key(Enum.at(ids, rem(i, length(ids))), by: "fuzz")}]
    end
  end

  defp apply_op({control, k, i}, ctx)
       when control in [:cancel, :cancel_undo, :retry, :rollback] do
    targets = if control in [:retry, :rollback], do: [:failed], else: @open

    case runs_of(Enum.at(ctx.keys, k), targets) do
      [] ->
        []

      ids ->
        id = Enum.at(ids, rem(i, length(ids)))

        result =
          case control do
            :cancel -> Durable.cancel(id, "fuzz")
            :cancel_undo -> Durable.cancel(id, "fuzz", rollback: true)
            :retry -> Durable.retry(id)
            :rollback -> Durable.rollback(id)
          end

        [{control, id, result}]
    end
  end

  # Most retries meet a newer run going and are refused: this one waits for
  # the key's runs to end first, so the failed run can take the key back.
  defp apply_op({:retry_when_idle, k, i}, ctx) do
    key = Enum.at(ctx.keys, k)
    await_idle(key, 50)

    lost =
      IntegrationRepo.all(
        from(w in WorkflowExecution,
          where: w.key == ^key and w.status == :failed and not w.holds_key,
          order_by: w.inserted_at,
          select: w.id
        )
      )

    case lost do
      [] ->
        apply_op({:retry, k, i}, ctx)

      ids ->
        id = Enum.at(ids, rem(i, length(ids)))
        [{:retry, id, Durable.retry(id)}]
    end
  end

  # Another transaction holds the key's lock a while: a start inside a long
  # transaction of the caller's.
  defp apply_op({:hold_lock, k, ms}, ctx) do
    key = Enum.at(ctx.keys, k)
    {module, name} = {workflow(key), workflow_name(key)}
    name = Durable.Keys.lock_name(module, name, key)

    IntegrationRepo.transaction(fn ->
      IntegrationRepo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [name])
      Process.sleep(ms)
    end)

    []
  end

  defp apply_op({kill, k}, ctx) when kill in [:kill_task, :kill_worker] do
    case K.Ledger.inside_now(Enum.at(ctx.keys, k)) do
      [{step, worker, id} | _] ->
        Process.exit(if(kill == :kill_task, do: step, else: worker), :kill)
        [{kill, id}]

      [] ->
        []
    end
  end

  # A run that waited for the key, claimed by a worker that hasn't taken the
  # key for it yet, loses its worker or task. The key's lock is held a while,
  # so a waiter claimed meanwhile stays there.
  defp apply_op({:kill_claimed, k, what}, ctx) do
    holding = Task.async(fn -> apply_op({:hold_lock, k, 400}, ctx) end)
    killed = kill_claimed(Enum.at(ctx.keys, k), what, ctx, 15)
    Task.await(holding)
    killed
  end

  defp apply_op(:recover, ctx), do: [{:recover, recover(ctx)}]

  defp apply_op({:wait, ms}, _ctx) do
    Process.sleep(ms)
    []
  end

  defp await_idle(_key, 0), do: :ok

  defp await_idle(key, tries) do
    open = from(w in WorkflowExecution, where: w.key == ^key and w.status in @open)

    if IntegrationRepo.exists?(open) do
      Process.sleep(20)
      await_idle(key, tries - 1)
    end
  end

  defp kill_claimed(_key, _what, _ctx, 0), do: []

  defp kill_claimed(key, what, ctx, tries) do
    claimed =
      IntegrationRepo.all(
        from(w in WorkflowExecution,
          where: w.key == ^key and w.status == :running and not is_nil(w.runs_after_id),
          select: w.id
        )
      )

    case for(id <- claimed, worker = worker_of(ctx, id), do: {id, worker}) do
      [] ->
        Process.sleep(20)
        kill_claimed(key, what, ctx, tries - 1)

      workers ->
        for {id, worker} <- workers, do: {:kill_claimed, id, kill(worker, what)}
    end
  end

  defp worker_of(ctx, id) do
    Durable.DataCase.get_worker_pid(id) ||
      :erpc.call(ctx.peer, Durable.DataCase, :get_worker_pid, [id])
  end

  defp kill(worker, :worker), do: Process.exit(worker, :kill)

  defp kill(worker, :task) do
    with %{task_pid: task} when is_pid(task) <- :sys.get_state(worker, 1_000),
         do: Process.exit(task, :kill)
  catch
    :exit, _gone -> false
  end

  # The third key's workflow is debounced.
  defp workflow(key), do: if(String.ends_with?(key, ":k3"), do: K.Debounced, else: K.Again)

  defp workflow_name(key),
    do: if(String.ends_with?(key, ":k3"), do: "kw_debounced", else: "kw_again")

  defp on(:here, _ctx, m, f, a), do: apply(m, f, a)
  defp on(:peer, ctx, m, f, a), do: :erpc.call(ctx.peer, m, f, a)

  defp recover(ctx) do
    case Postgres.recover_stale_locks(ctx.config, 1) do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  # The key's runs in one of `statuses`, or all of them if none is.
  defp runs_of(key, statuses) do
    runs =
      IntegrationRepo.all(
        from(w in WorkflowExecution,
          where: w.key == ^key,
          order_by: w.inserted_at,
          select: {w.id, w.status}
        )
      )

    case for({id, status} <- runs, status in statuses, do: id) do
      [] -> Enum.map(runs, &elem(&1, 0))
      ids -> ids
    end
  end

  defp rows_of(keys) do
    IntegrationRepo.all(from(w in WorkflowExecution, where: w.key in ^keys))
  end

  # Checked after every op, in one read: a run of a key that is going holds
  # the key, waits for it, or is being rolled back (and so has let it go).
  # Anything else would run beside the holder.
  defp without_key(keys) do
    for run <- rows_of(keys), not accounted_for?(run), do: {:runs_without_key, describe(run)}
  end

  defp accounted_for?(%{holds_key: true}), do: true
  defp accounted_for?(%{status: status}) when status not in @open, do: true
  # Waiting, or claimed and about to take the key.
  defp accounted_for?(%{runs_after_id: id}) when id != nil, do: true
  defp accounted_for?(%{status: :compensating}), do: true
  defp accounted_for?(%{engine_state: state}), do: Map.has_key?(state, "__rollback__")

  # ===========================================================================
  # Checks
  # ===========================================================================

  # Waits until no run of the keys is open or locked, sweeping up runs whose
  # worker was killed. Returns the sweep errors it met.
  defp settle(ctx, deadline, errors \\ []) do
    errors =
      case recover(ctx) do
        :ok -> errors
        error -> [error | errors]
      end

    open = Enum.filter(rows_of(ctx.keys), &(&1.status in @open or &1.locked_by != nil))

    cond do
      open == [] ->
        errors

      System.monotonic_time(:millisecond) > deadline ->
        errors

      true ->
        Process.sleep(100)
        settle(ctx, deadline, errors)
    end
  end

  defp describe(run) do
    %{
      id: String.slice(run.id, 0, 8),
      status: run.status,
      holds_key: run.holds_key,
      runs_after: run.runs_after_id && String.slice(run.runs_after_id, 0, 8),
      v: run.input["v"],
      locked: run.locked_by != nil,
      error: run.error && Map.take(run.error, ["type", "message"])
    }
  end

  defp check_key(key, {final_v, final_result}, rows, sweep_errors) do
    runs = Map.new(rows, &{&1.id, &1})
    overlaps = for {a, b} <- K.overlaps(key), do: overlap(a, b, runs[a])
    stuck = for run <- rows, run.status in @open or run.locked_by != nil, do: run

    order =
      case {final_result, List.last(K.ran(key))} do
        {{:ok, _}, ^final_v} -> []
        _ when stuck != [] -> []
        {result, last} -> [{:newest_not_last, %{final: final_v, result: result, last_ran: last}}]
      end

    surprises = for run <- rows, finding = surprise(run), do: finding
    overlaps ++ Enum.map(stuck, &stuck(&1, sweep_errors)) ++ order ++ surprises
  end

  defp overlap(id, id, _run), do: {:same_run_twice, id}

  defp overlap(a, b, %{status: :cancelled}), do: {:known, 3, {:overlap_after_cancel, a, b}}
  defp overlap(a, b, _run), do: {:overlap, a, b}

  defp stuck(%{runs_after_id: id, id: id}, _errors), do: {:known, 1, {:waits_behind_itself, id}}
  defp stuck(run, [error | _]), do: {:known, 2, {:sweep_failed, run.id, error}}
  defp stuck(run, []), do: {:stuck, describe(run)}

  # A run that ended in a way no op or body asked for.
  defp surprise(%{status: :failed, error: %{"message" => "told to"}}), do: nil
  defp surprise(%{status: :failed, error: %{"type" => "task_crash"}}), do: nil

  defp surprise(%{status: :failed, runs_after_id: after_id} = run) when after_id != nil,
    do: {:known, 1, {:waiter_failed_taking_key, describe(run)}}

  defp surprise(%{status: :failed} = run), do: {:failed, describe(run)}

  defp surprise(%{status: :cancelled, error: error} = run) do
    message = error["message"] || ""

    expected =
      message == "fuzz" or is_binary(error["replaced_by"]) or
        message =~ "a newer start is waiting"

    if expected, do: nil, else: {:cancelled, describe(run)}
  end

  defp surprise(_run), do: nil

  # ===========================================================================
  # Coverage
  # ===========================================================================

  defp coverage(keys, records) do
    activity =
      IntegrationRepo.all(
        from(a in ActivityEvent,
          where: fragment("?->>'key'", a.details) in ^keys,
          select: {a.kind, fragment("?->>'outcome'", a.details)}
        )
      )

    nodes = for {:enter, key, _id, _v, node} <- K.Ledger.events(), key in keys, do: node

    %{
      waiter_made: Enum.count(activity, &(&1 == {"key_duplicate", "run_again"})),
      replaced: Enum.count(activity, &(&1 == {"key_duplicate", "cancel_existing"})),
      handed_off: Enum.count(activity, &match?({"key_handed_off", _}, &1)),
      retaken: Enum.count(activity, &match?({"key_retaken", _}, &1)),
      retried: Enum.count(records, &match?({:retry, _, {:ok, _}}, &1)),
      rolled_back: Enum.count(records, &match?({:rollback, _, {:ok, _}}, &1)),
      cancelled: Enum.count(records, &match?({:cancel, _, :ok}, &1)),
      killed: Enum.count(records, &match?({kill, _} when kill in [:kill_task, :kill_worker], &1)),
      killed_claimed: Enum.count(records, &match?({:kill_claimed, _, true}, &1)),
      debounced: Enum.count(activity, &(&1 == {"key_duplicate", "debounced"})),
      batched: Enum.count(records, &match?({:start_many, _, _, _, {:ok, _}}, &1)),
      released: Enum.count(records, &match?({:release, :ok}, &1)),
      on_peer: Enum.count(nodes, &(&1 != node())),
      here: Enum.count(nodes, &(&1 == node()))
    }
  end

  # ===========================================================================
  # Property
  # ===========================================================================

  property "keys hold under random starts, cancels, retries, rollbacks and kills on two nodes",
           %{peer: peer} do
    {:ok, tally} = Agent.start_link(fn -> %{coverage: %{}, known: %{}, cases: 0} end)
    config = Config.get(Durable)

    check all(
            nkeys <- integer(1..3),
            ops <- list_of(op(), min_length: 5, max_length: 30),
            max_runs: @runs,
            max_shrinking_steps: 0
          ) do
      n = Agent.get_and_update(tally, &{&1.cases, %{&1 | cases: &1.cases + 1}})
      keys = for i <- 1..nkeys, do: "c#{n}:k#{i}"
      ctx = %{keys: keys, peer: peer, config: config}
      ops = Enum.map(ops, &clamp(&1, nkeys))

      {records, background} =
        Enum.reduce(ops, {[], []}, fn
          {:async, op}, {records, tasks} ->
            {records, [Task.async(fn -> apply_op(op, ctx) end) | tasks]}

          op, {records, tasks} ->
            {records ++ apply_op(op, ctx) ++ without_key(keys), tasks}
        end)

      records = records ++ Enum.flat_map(background, &Task.await(&1, 60_000))

      # The last start of every key: its input runs last.
      finals =
        Map.new(keys, fn key ->
          v = System.unique_integer([:positive])
          {key, {v, Durable.start(workflow(key), %{"key" => key, "v" => v}, key: key)}}
        end)

      sweep_errors = settle(ctx, System.monotonic_time(:millisecond) + @settle_ms)
      rows = rows_of(keys)

      findings =
        Enum.flat_map(keys, fn key ->
          check_key(key, finals[key], Enum.filter(rows, &(&1.key == key)), sweep_errors)
        end) ++ Enum.filter(records, &match?({:runs_without_key, _}, &1))

      {known, new} = Enum.split_with(findings, &match?({:known, _, _}, &1))
      record(tally, coverage(keys, records), known, ops)

      assert new == [],
             "#{inspect(new, pretty: true)}\n\nops: #{inspect(ops)}\nrecords: " <>
               inspect(records, pretty: true) <>
               "\nruns: #{inspect(Enum.map(rows, &describe/1), pretty: true)}"
    end

    %{coverage: coverage, known: known} = Agent.get(tally, & &1)
    IO.puts("\nkeys fuzz coverage: #{inspect(coverage)}")

    for {bug, {count, example}} <- known do
      IO.puts("known bug ##{bug} hit #{count}x, e.g. #{inspect(example, pretty: true)}")
    end

    # The property means nothing if the cases never got this far.
    for {what, count} <- coverage, do: assert(count > 0, "never got to #{what}")
  end

  defp clamp({:wait, _ms} = op, _nkeys), do: op
  defp clamp({:async, op}, nkeys), do: {:async, clamp(op, nkeys)}

  defp clamp({:start_many, ks, where}, nkeys),
    do: {:start_many, Enum.map(ks, &rem(&1, nkeys)), where}

  defp clamp(op, nkeys) when is_tuple(op), do: put_elem(op, 1, rem(elem(op, 1), nkeys))

  defp clamp(op, _nkeys), do: op

  defp record(tally, coverage, known, ops) do
    Agent.update(tally, fn tally ->
      %{
        tally
        | coverage: Map.merge(tally.coverage, coverage, fn _k, a, b -> a + b end),
          known: Enum.reduce(known, tally.known, &count_known(&1, &2, ops))
      }
    end)
  end

  # How often each known bug was hit, and the first case that hit it.
  defp count_known({:known, bug, what}, known, ops),
    do: Map.update(known, bug, {1, {what, ops}}, fn {count, first} -> {count + 1, first} end)
end
