defmodule Durable.Fuzz.Audit6WaitsLoadTest do
  @moduledoc """
  Audit 6: a few hundred runs waiting at once, on live pollers, while many
  processes answer them, keep events for them, cancel their waits, cancel
  them, push their waits and deadlines past due under two timeout sweeps, kill
  their steps and retry them, all at the same time.

  Nothing can say what each call should return, so every result is kept and
  checked against the rows once every run has ended: each wait's row ended
  once and the run saw what that row says; every answer taken is on a row;
  no wait is left open on a run that ended.
  """
  use Durable.IntegrationCase, tag: :fuzz

  @moduletag :capture_log
  @moduletag timeout: :infinity

  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup}
  alias Durable.Wait
  alias Durable.Wait.TimeoutWorker

  @rounds String.to_integer(System.get_env("FUZZ_RUNS", "2"))
  @runs 120
  @actors 8
  @round_ms 15_000

  defmodule Audit6EveryWait do
    use Durable
    use Durable.Wait

    alias Durable.Fuzz.Audit6WaitsLoadTest, as: T

    # An hour for the run, so a deadline can be pushed past.
    workflow "audit6_every_wait", timeout: 3_600_000 do
      step :ask, fn data ->
        got = wait_for_input("ask", timeout: 3_600_000, timeout_value: "timeout")
        {:ok, Map.put(data, "ask", T.describe(got))}
      end

      step :event, fn data ->
        got = wait_for_event("ev", timeout: 3_600_000, timeout_value: "timeout")
        {:ok, Map.put(data, "ev", T.describe(got))}
      end

      step :any, fn data ->
        got = wait_for_any(["a", "b"], timeout: 3_600_000, timeout_value: "timeout")
        {:ok, Map.put(data, "any", T.describe(got))}
      end

      step :all, fn data ->
        got = wait_for_all(["c", "d"], timeout: 3_600_000, timeout_value: "timeout")
        {:ok, Map.put(data, "all", T.describe(got))}
      end

      step :nap, fn data ->
        sleep(30)
        {:ok, data}
      end
    end
  end

  def describe(%{"p" => p}), do: "p:#{p}"
  def describe("timeout"), do: "timeout"
  def describe({:cancelled, _reason}), do: "cancelled"
  def describe({name, %{"p" => p}}), do: "#{name}:p:#{p}"
  def describe(%{} = all), do: Map.new(all, fn {name, payload} -> {name, describe(payload)} end)
  def describe(other), do: "other:#{inspect(other)}"

  setup do
    start_durable!(%{default: 12}, sleep_waker_interval: 50)

    other = %{Durable.Config.get(Durable) | name: Audit6OtherNode}
    start_supervised!({TimeoutWorker, config: other, interval: :timer.hours(1)}, id: :other_sweep)
    :ok
  end

  defp sweep do
    for name <- [Durable, Audit6OtherNode], do: TimeoutWorker.check_timeouts(name)
  end

  defp make_due(id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    for schema <- [PendingInput, PendingEvent, WaitGroup] do
      IntegrationRepo.update_all(
        from(p in schema, where: p.workflow_id == ^id and p.status == :pending),
        set: [timeout_at: past]
      )
    end
  end

  # The process running `id`'s step, if one is.
  defp task_of(id) do
    Enum.find(Process.list(), fn pid ->
      match?({:dictionary, %{durable_workflow_id: ^id}}, dictionary(pid))
    end)
  end

  defp dictionary(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> {:dictionary, Map.new(dict)}
      nil -> nil
    end
  end

  @event_names ["ev", "a", "b", "c", "d"]

  # Each kind of call, and how often it's made.
  @kinds [input: 25, event: 50, cancel_wait: 7, due: 7, expire: 3, retry: 5, kill: 2, cancel: 1]

  defp pick do
    roll = :rand.uniform(Enum.sum(Keyword.values(@kinds)))

    Enum.reduce_while(@kinds, roll, fn {kind, weight}, left ->
      if left <= weight, do: {:halt, kind}, else: {:cont, left - weight}
    end)
  end

  defp call(:input, id, uid), do: {"ask", false, Durable.provide_input(id, "ask", %{"p" => uid})}

  defp call(:event, id, uid) do
    name = Enum.random(@event_names)
    buffer = :rand.uniform(4) == 1
    {name, buffer, Durable.send_event(id, name, %{"p" => uid}, buffer: buffer)}
  end

  defp call(:cancel_wait, id, _uid), do: {nil, false, Wait.cancel_wait(id, reason: "op")}

  defp call(:due, id, _uid) do
    make_due(id)
    {nil, false, sweep()}
  end

  defp call(:expire, id, _uid) do
    expire!(id)
    {nil, false, sweep()}
  end

  defp call(:retry, id, _uid), do: {nil, false, Durable.retry(id)}

  defp call(:kill, id, _uid) do
    pid = task_of(id)
    {nil, false, if(pid, do: Process.exit(pid, :kill), else: :no_task)}
  end

  defp call(:cancel, id, _uid), do: {nil, false, Durable.cancel(id, "op")}

  defp op(ids) do
    id = Enum.random(ids)
    kind = pick()
    uid = System.unique_integer([:positive])

    {name, buffer, result} =
      try do
        call(kind, id, uid)
      rescue
        error -> {nil, false, {:raised, Exception.message(error)}}
      end

    %{id: id, kind: kind, name: name, uid: uid, buffer: buffer, result: result}
  end

  @open [:pending, :running, :waiting, :failed]

  defp actor(ids, until, log) do
    active =
      IntegrationRepo.all(
        from(w in WorkflowExecution, where: w.id in ^ids and w.status in ^@open, select: w.id)
      )

    if System.monotonic_time(:millisecond) >= until or active == [],
      do: log,
      else: actor(ids, until, Enum.map(1..20, fn _ -> op(active) end) ++ log)
  end

  # Every run ends: what's waiting times out, what failed is left failed.
  defp settle(ids) do
    assert_eventually(
      fn ->
        runs = IntegrationRepo.all(from(w in WorkflowExecution, where: w.id in ^ids))
        for run <- runs, run.status == :waiting, do: make_due(run.id)
        sweep()
        Enum.all?(runs, &(&1.status in [:completed, :cancelled, :failed]))
      end,
      120_000,
      500
    )

    # A cancel closes what the run had open after it commits.
    assert_eventually(fn -> open_waits(ids) == [] end, 10_000, 100)
  end

  test "each wait ends once, and the run sees what its row says" do
    log =
      for _round <- 1..@rounds, reduce: [] do
        log -> log ++ round()
      end

    kinds = log |> Enum.map(&{&1.kind, outcome(&1.result)}) |> Enum.frequencies()

    # The generator reached every kind of call, and each one that can take
    # effect did at least once.
    for kind <- [:input, :event, :cancel_wait, :retry, :cancel] do
      assert Map.get(kinds, {kind, :ok}, 0) > 0, "no #{kind} took effect"
    end

    for kind <- [:due, :expire, :kill], do: assert(Enum.any?(log, &(&1.kind == kind)))
  end

  defp outcome(:ok), do: :ok
  defp outcome({:ok, _}), do: :ok
  defp outcome(other), do: other

  defp round do
    ids =
      for _ <- 1..@runs do
        {:ok, id} = Durable.start(Audit6EveryWait, %{})
        id
      end

    until = System.monotonic_time(:millisecond) + @round_ms

    log =
      1..@actors
      |> Enum.map(fn _ -> Task.async(fn -> actor(ids, until, []) end) end)
      |> Task.await_many(:infinity)
      |> List.flatten()

    settle(ids)

    raised = Enum.filter(log, &match?({:raised, _}, &1.result))
    assert raised == [], "calls raised: #{inspect(Enum.take(raised, 5))}"

    runs = IntegrationRepo.all(from(w in WorkflowExecution, where: w.id in ^ids))

    problems =
      Enum.flat_map(runs, &check_run/1) ++ answers_on_rows(log, ids) ++ kept_on_retry(ids)

    assert problems == []
    log
  end

  # The run saw what the last row of each of its waits says.
  defp check_run(%{status: :completed} = run) do
    [
      {"ask", seen_by(last(PendingInput, run.id, "ask"))},
      {"ev", seen_by(last(PendingEvent, run.id, "ev"))},
      {"any", seen_by(last(WaitGroup, run.id, ["a", "b"]))},
      {"all", seen_by(last(WaitGroup, run.id, ["c", "d"]))}
    ]
    |> Enum.reject(fn {key, row_says} -> run.context[key] == row_says end)
    |> Enum.map(fn {key, row_says} -> {:saw, run.id, key, run.context[key], row_says} end)
  end

  defp check_run(_cancelled_or_failed), do: []

  defp last(PendingInput, id, name) do
    IntegrationRepo.one(
      from(p in PendingInput,
        where: p.workflow_id == ^id and p.input_name == ^name,
        order_by: [desc: p.inserted_at],
        limit: 1
      )
    )
  end

  defp last(PendingEvent, id, name) do
    IntegrationRepo.one(
      from(p in PendingEvent,
        where: p.workflow_id == ^id and p.event_name == ^name and is_nil(p.wait_group_id),
        where: p.status != :buffered,
        order_by: [desc: p.inserted_at],
        limit: 1
      )
    )
  end

  defp last(WaitGroup, id, names) do
    IntegrationRepo.one(
      from(g in WaitGroup,
        where: g.workflow_id == ^id and g.event_names == ^names,
        order_by: [desc: g.inserted_at],
        limit: 1
      )
    )
  end

  defp seen_by(%PendingInput{status: :completed, response: response}), do: describe(response)
  defp seen_by(%PendingEvent{status: :received, payload: payload}), do: describe(payload)

  defp seen_by(%WaitGroup{status: :completed, wait_type: :any, received_events: got}),
    do: got |> Enum.map(&describe/1) |> hd()

  defp seen_by(%WaitGroup{status: :completed, received_events: got}), do: describe(got)
  defp seen_by(%{status: :timeout}), do: "timeout"
  defp seen_by(%{status: :cancelled}), do: "cancelled"
  defp seen_by(row), do: {:row, row && row.status}

  # Every answer a caller was told was taken is on one wait's row. A retried
  # wait_for_all has it on the new wait's too, and an event under another name
  # of a wait_for_any that has its answer is told :ok and taken by nothing.
  defp answers_on_rows(log, ids) do
    inputs =
      IntegrationRepo.all(
        from(p in PendingInput,
          where: p.workflow_id in ^ids and p.status == :completed,
          select: p.response
        )
      )

    events =
      IntegrationRepo.all(
        from(p in PendingEvent,
          where: p.workflow_id in ^ids and p.status == :received,
          select: p.payload
        )
      )

    taken = Enum.frequencies(Enum.map(inputs ++ events, & &1["p"]))

    for %{kind: kind, result: :ok, buffer: false} = op <- log,
        kind in [:input, :event],
        rows = Map.get(taken, op.uid, 0),
        (op.name in ["ask", "ev"] and rows != 1) or (op.name in ["c", "d"] and rows == 0) do
      {:answer_not_on_its_row, op, rows}
    end
  end

  # A wait_for_all that a retry made again has every event the one before it
  # got: their senders were told they were taken.
  defp kept_on_retry(ids) do
    IntegrationRepo.all(
      from(g in WaitGroup,
        where: g.workflow_id in ^ids and g.event_names == ^["c", "d"],
        order_by: [asc: g.inserted_at]
      )
    )
    |> Enum.group_by(& &1.workflow_id)
    |> Enum.flat_map(fn {id, groups} ->
      for [before, again] <- Enum.chunk_every(groups, 2, 1, :discard),
          before.status != :completed,
          lost = Map.keys(before.received_events) -- Map.keys(again.received_events),
          lost != [],
          do: {:lost_on_retry, id, lost}
    end)
  end

  defp open_waits(ids) do
    for schema <- [PendingInput, PendingEvent, WaitGroup],
        row <-
          IntegrationRepo.all(
            from(p in schema,
              join: w in WorkflowExecution,
              on: w.id == p.workflow_id,
              where: p.workflow_id in ^ids and p.status == :pending and w.status != :waiting,
              select: {p.id, w.id, w.status}
            )
          ),
        do: {:open_wait_on_ended_run, schema, row}
  end
end
