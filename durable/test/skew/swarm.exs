# The clock-skew swarm. Every container loads this file: the Durable nodes
# (ROLE=node), whose clocks libfaketime skews, and the orchestrator (ROLE=setup,
# then ROLE=orch), which drives runs on the nodes and checks what they did.
# Side effects are marked in skew.marks with the database's clock_timestamp(),
# so every check reads one clock. See README.md.

defmodule Skew.Repo do
  use Ecto.Repo, otp_app: :durable, adapter: Ecto.Adapters.Postgres
end

defmodule Skew.Migration do
  use Ecto.Migration
  def up, do: Durable.Migration.up()
  def down, do: Durable.Migration.down()
end

defmodule Skew do
  @moduledoc false
  alias Durable.Queue.StaleJobRecovery
  alias Durable.Wait.TimeoutWorker
  alias Ecto.Adapters.Postgres
  alias Skew.Repo

  @stale_s 3
  @beat_ms 500

  def stale_s, do: @stale_s
  def beat_ms, do: @beat_ms

  def db_opts(pool_size) do
    [
      hostname: System.get_env("SKEW_DB_HOST", "durable-postgres-1"),
      port: String.to_integer(System.get_env("SKEW_DB_PORT", "5432")),
      username: "postgres",
      password: "postgres",
      database: System.get_env("SKEW_DB", "durable_skew"),
      pool_size: pool_size,
      log: false
    ]
  end

  def label, do: node() |> Atom.to_string() |> String.split("@") |> hd()
  def queue(label), do: String.to_atom("q_" <> label)

  # A row stamped with the database's clock, the one clock every check reads.
  def mark(run_id, kind, attempt \\ nil, info \\ %{}) do
    Repo.query!(
      "INSERT INTO skew.marks (run_id, kind, attempt, node, info) VALUES ($1, $2, $3, $4, $5)",
      [run_id && Ecto.UUID.dump!(run_id), kind, attempt, label(), info]
    )

    :ok
  end

  def marked?(run_id, kind) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM skew.marks WHERE run_id = $1 AND kind = $2", [
        Ecto.UUID.dump!(run_id),
        kind
      ])

    n > 0
  end

  # Works for `ms`, marking every 50 ms under an id of its own, so a check sees
  # when this body ran even if it was killed part-way.
  def busy(run_id, kind, ms) do
    attempt = Ecto.UUID.generate()
    tick(run_id, kind, attempt, System.monotonic_time(:millisecond) + ms)
  end

  defp tick(run_id, kind, attempt, until) do
    mark(run_id, kind, attempt)

    if System.monotonic_time(:millisecond) < until do
      Process.sleep(50)
      tick(run_id, kind, attempt, until)
    end
  end

  def run_id, do: Durable.Context.workflow_id()

  # ---------------------------------------------------------------------------
  # A node
  # ---------------------------------------------------------------------------

  def boot_node do
    Logger.configure(level: :warning)
    {:ok, _} = Repo.start_link(db_opts(20))
    poll = [concurrency: 20, poll_interval: 100]

    {:ok, _} =
      Durable.start_link(
        repo: Repo,
        queues: %{:shared => poll, queue(label()) => poll},
        stale_lock_timeout: @stale_s,
        heartbeat_interval: @beat_ms,
        scheduler_interval: 500,
        sleep_waker_interval: 100,
        shutdown_grace_period: 0
      )

    :telemetry.attach_many(
      "skew",
      [[:durable, :step, :retry], [:durable, :schedule, :trigger]],
      &__MODULE__.on_event/4,
      nil
    )

    # The sweeps run every 60 s on their own. A swarm round is a few minutes,
    # so it runs them about as often as its heartbeat.
    Task.start(fn -> sweep(0) end)
    IO.puts("[skew] #{label()} up, its clock reads #{DateTime.utc_now()}")
  end

  def on_event([:durable, :step, :retry], %{backoff_ms: ms}, meta, _),
    do: safely(fn -> mark(meta.workflow_id, "backoff", nil, %{"ms" => ms}) end)

  def on_event([:durable, :schedule, :trigger], _, meta, _),
    do: safely(fn -> mark(meta.workflow_id, "fire") end)

  defp safely(fun) do
    fun.()
  rescue
    error -> IO.puts("[skew] mark failed: #{Exception.message(error)}")
  end

  defp sweep(n) do
    TimeoutWorker.check_timeouts(Durable)
    if rem(n, 3) == 0, do: recover()
    Process.sleep(150)
    sweep(n + 1)
  end

  defp recover do
    StaleJobRecovery.recover_now(Durable)
  catch
    :exit, _busy -> :ok
  end

  # ---------------------------------------------------------------------------
  # Setup: a fresh database for the round
  # ---------------------------------------------------------------------------

  def setup do
    opts = db_opts(2)
    _ = Postgres.storage_down(opts)
    :ok = Postgres.storage_up(opts)
    {:ok, _} = Repo.start_link(opts)
    Logger.configure(level: :warning)
    Ecto.Migrator.run(Repo, [{1, Skew.Migration}], :up, all: true)

    Repo.query!("CREATE SCHEMA skew")

    Repo.query!("""
    CREATE TABLE skew.marks (
      id bigserial PRIMARY KEY,
      run_id uuid,
      kind text NOT NULL,
      attempt text,
      node text NOT NULL,
      info jsonb NOT NULL DEFAULT '{}',
      at double precision NOT NULL DEFAULT (extract(epoch FROM clock_timestamp()) * 1000)
    )
    """)

    Repo.query!("CREATE INDEX ON skew.marks (run_id, kind)")
  end
end

# =============================================================================
# Workflows. Each marks what it did, by the database's clock.
# =============================================================================

defmodule Skew.Long do
  use Durable

  workflow "long" do
    step :work, fn data ->
      Skew.busy(Skew.run_id(), "step", data["ms"])
      {:ok, data}
    end
  end
end

defmodule Skew.Keyed do
  use Durable

  workflow "keyed" do
    step :work, fn data ->
      Skew.busy(Skew.run_id(), "step", data["ms"])
      {:ok, data}
    end
  end
end

defmodule Skew.KeyedUndo do
  use Durable

  workflow "keyed_undo" do
    step :first, [compensate: :undo], fn data ->
      {:ok, Map.put(data, "id", Skew.run_id())}
    end

    step :work, fn data ->
      Skew.busy(Skew.run_id(), "step", data["ms"])
      {:ok, data}
    end

    compensate :undo, fn data ->
      Skew.busy(data["id"], "comp", 400)
      {:ok, data}
    end
  end
end

defmodule Skew.Sleeper do
  use Durable
  use Durable.Wait

  workflow "sleeper" do
    step :nap, fn data ->
      Skew.mark(Skew.run_id(), "req")
      sleep(data["ms"])
      {:ok, data}
    end

    step :done, fn data ->
      Skew.mark(Skew.run_id(), "done")
      {:ok, data}
    end
  end
end

defmodule Skew.Snoozer do
  use Durable

  workflow "snoozer" do
    step :nap, fn data ->
      if Skew.marked?(Skew.run_id(), "req") do
        Skew.mark(Skew.run_id(), "done")
        {:ok, data}
      else
        Skew.mark(Skew.run_id(), "req")
        {:snooze, data["ms"]}
      end
    end
  end
end

defmodule Skew.Retrier do
  use Durable

  workflow "retrier" do
    step :flaky, [retry: [max_attempts: 2, backoff: :constant, base: 2_000]], fn data ->
      if Skew.marked?(Skew.run_id(), "req") do
        Skew.mark(Skew.run_id(), "done")
        {:ok, data}
      else
        Skew.mark(Skew.run_id(), "req")
        {:error, "the first attempt fails"}
      end
    end
  end
end

defmodule Skew.EventWaiter do
  use Durable
  use Durable.Wait

  workflow "event_waiter" do
    step :wait, fn data ->
      Skew.mark(Skew.run_id(), "req")
      wait_for_event("never_sent", timeout: data["ms"], timeout_value: "timed_out")
      Skew.mark(Skew.run_id(), "done")
      {:ok, data}
    end
  end
end

defmodule Skew.Deadline do
  use Durable

  workflow "deadline", timeout: 2_500 do
    step :work, fn data ->
      Skew.busy(Skew.run_id(), "step", 8_000)
      {:ok, data}
    end
  end
end

defmodule Skew.Cron do
  use Durable

  workflow "cron" do
    step :fire, fn data -> {:ok, data} end
  end
end

# =============================================================================
# The orchestrator: drives a round on the nodes and checks it
# =============================================================================

defmodule Skew.Orch do
  @moduledoc false
  alias Durable.Queue.StaleJobRecovery
  alias Durable.Wait.TimeoutWorker
  alias Ecto.Adapters.Postgres
  alias Skew.Repo

  @labels ~w(zero ahead behind)
  @tolerance_ms 500
  @cron_tolerance_ms 1_500
  @wait_ms 2_000
  @deadline_ms 2_500
  @final ~w(completed failed cancelled compensated compensation_failed)

  def run do
    Logger.configure(level: :warning)
    {:ok, _} = Repo.start_link(Skew.db_opts(8))
    skew = String.to_integer(System.fetch_env!("SKEW"))
    round_ms = String.to_integer(System.get_env("ROUND_SECONDS", "130")) * 1_000
    nodes = Map.new(@labels, &{&1, :"#{&1}@skew-#{&1}"})
    connect!(nodes)

    began = db_now()
    {:ok, _} = call(nodes, "zero", Durable, :schedule, [Skew.Cron, "* * * * *", [name: "cron"]])

    tasks = [
      Task.async(fn -> stale(nodes) end),
      Task.async(fn -> keys(nodes) end),
      Task.async(fn -> timing(nodes) end),
      Task.async(fn ->
        Process.sleep(20_000)
        alive(nodes)
      end)
    ]

    findings = Enum.flat_map(tasks, &Task.await(&1, round_ms + 120_000))
    Process.sleep(max(round_ms - round(db_now() - began), 0))
    findings = findings ++ schedules(began) ++ alive(nodes)
    report(skew, findings)
  end

  defp connect!(nodes) do
    await!(
      fn ->
        Enum.all?(nodes, fn {_label, node} ->
          Node.connect(node) and
            is_pid(:erpc.call(node, Process, :whereis, [Durable.Supervisor]))
        end)
      end,
      120_000,
      "nodes to boot"
    )

    # Their first heartbeats, and their first beats in the registry.
    Process.sleep(2_000)
  end

  defp call(nodes, label, mod, fun, args),
    do: :erpc.call(Map.fetch!(nodes, label), mod, fun, args)

  # ---------------------------------------------------------------------------
  # The same step never runs on two nodes at once (a lock taken while live).
  # ---------------------------------------------------------------------------

  defp stale(nodes) do
    runs =
      for label <- @labels do
        {:ok, id} =
          call(nodes, label, Durable, :start, [
            Skew.Long,
            %{"ms" => 7_000},
            [queue: Skew.queue(label)]
          ])

        {label, id}
      end

    for {label, id} <- runs do
      status = await_final(id, 60_000)
      attempts = intervals("attempt", [id], "step")
      overlaps = overlaps(attempts)

      finding(
        "step-once",
        overlaps == [],
        "step claimed on #{label}: #{length(attempts)} attempt(s), run #{status}" <>
          overlap_text(overlaps)
      )
    end
  end

  # ---------------------------------------------------------------------------
  # A key never has two runs going at once, across a cancel mid-step, and an
  # undo waits for the step it undoes to stop.
  # ---------------------------------------------------------------------------

  defp keys(nodes) do
    # Who cancels and who starts the next run, on a worker whose clock is
    # right; then a worker whose clock is off, with both of those right.
    cases =
      for variant <- [:after_cancel, :run_again, :rollback],
          {worker, canceller, starter} <-
            for(c <- @labels, s <- @labels, do: {"zero", c, s}) ++
              [{"ahead", "zero", "zero"}, {"behind", "zero", "zero"}],
          do: {variant, worker, canceller, starter}

    cases
    |> Task.async_stream(&key_case(nodes, &1), timeout: 120_000, max_concurrency: 12)
    |> Enum.flat_map(fn {:ok, findings} -> findings end)
  end

  defp key_case(nodes, {variant, worker, canceller, starter}) do
    key = "#{variant}-#{worker}-#{canceller}-#{starter}"
    workflow = if variant == :rollback, do: Skew.KeyedUndo, else: Skew.Keyed

    {:ok, first} =
      call(nodes, worker, Durable, :start, [
        workflow,
        %{"ms" => 6_000},
        [key: key, queue: Skew.queue(worker)]
      ])

    await!(fn -> Skew.marked?(first, "step") end, 20_000, "the first run's step")
    # Lands anywhere between two of the worker's heartbeats.
    Process.sleep(:rand.uniform(Skew.beat_ms()))
    second = key_step(nodes, variant, first, {workflow, key, canceller, starter})

    await_final(first, 60_000)
    await_final(second, 60_000)
    runs = intervals("run_id", [first, second], "step")
    who = "#{variant}: worker #{worker}, cancelled on #{canceller}, next started on #{starter}"
    overlaps = overlaps(runs)

    key_once =
      finding("key-once", second != first and overlaps == [], who <> overlap_text(overlaps))

    if variant == :rollback do
      undo = overlaps(intervals("kind", [first], "step") ++ intervals("kind", [first], "comp"))
      undone? = intervals("kind", [first], "comp") != []

      [
        key_once,
        finding("undo-after-step", undone? and undo == [], who <> undo_text(undone?, undo))
      ]
    else
      [key_once]
    end
  end

  defp undo_text(false, _), do: " (never undone)"
  defp undo_text(true, overlaps), do: overlap_text(overlaps)

  defp key_step(nodes, :run_again, first, {workflow, key, canceller, starter}) do
    {:ok, second} =
      call(nodes, starter, Durable, :start, [
        workflow,
        %{"ms" => 1_500},
        [key: key, queue: :shared, on_duplicate: :run_again]
      ])

    :ok = call(nodes, canceller, Durable, :cancel, [first, "skew"])
    second
  end

  defp key_step(nodes, variant, first, {workflow, key, canceller, starter}) do
    opts = if variant == :rollback, do: [rollback: true], else: []
    :ok = call(nodes, canceller, Durable, :cancel, [first, "skew", opts])

    {:ok, second} =
      call(nodes, starter, Durable, :start, [
        workflow,
        %{"ms" => 1_500},
        [key: key, queue: :shared]
      ])

    second
  end

  # ---------------------------------------------------------------------------
  # Sleeps, snoozes, retries, event timeouts and deadlines fire on time.
  # ---------------------------------------------------------------------------

  defp timing(nodes) do
    waits =
      for label <- @labels,
          {invariant, workflow} <- [
            {"sleep-on-time", Skew.Sleeper},
            {"snooze-on-time", Skew.Snoozer},
            {"retry-on-time", Skew.Retrier},
            {"event-timeout-on-time", Skew.EventWaiter}
          ] do
        {:ok, id} =
          call(nodes, label, Durable, :start, [
            workflow,
            %{"ms" => @wait_ms},
            [queue: Skew.queue(label)]
          ])

        {invariant, label, id}
      end

    deadlines =
      for starter <- @labels, runner <- @labels do
        asked = db_now()

        {:ok, id} =
          call(nodes, starter, Durable, :start, [Skew.Deadline, %{}, [queue: Skew.queue(runner)]])

        {starter, runner, id, asked}
      end

    Enum.map(waits, &check_wait/1) ++ Enum.map(deadlines, &check_deadline/1)
  end

  defp check_wait({invariant, label, id}) do
    await_final(id, 60_000)
    asked = first_at(id, if(invariant == "retry-on-time", do: "backoff", else: "req"))
    done = first_at(id, "done")

    due =
      if invariant == "retry-on-time",
        do: asked && asked + backoff_ms(id),
        else: asked && asked + @wait_ms

    on_time("#{invariant}", "written on #{label}", due, done)
  end

  defp check_deadline({starter, runner, id, asked}) do
    status = await_final(id, 60_000)
    stopped = last_at(id, "step") || asked

    on_time(
      "deadline-on-time",
      "started on #{starter}, run on #{runner} (#{status})",
      asked + @deadline_ms,
      stopped
    )
  end

  defp on_time(invariant, who, due, at) when is_number(due) and is_number(at) do
    error = round(at - due)
    finding(invariant, abs(error) <= @tolerance_ms, "#{who}: #{signed(error)} ms off")
  end

  defp on_time(invariant, who, _due, _at), do: finding(invariant, false, "#{who}: never happened")

  # ---------------------------------------------------------------------------
  # Schedules fire once a slot, on time.
  # ---------------------------------------------------------------------------

  # The schedule was made on `zero`, whose clock is right: its first slot is
  # the minute after `began`.
  defp schedules(began) do
    fires = all_at("fire")
    now = db_now()
    first_slot = Float.ceil(began / 60_000) * 60_000
    slots = Stream.iterate(first_slot, &(&1 + 60_000)) |> Enum.take_while(&(&1 <= now - 2_000))
    errors = Enum.zip_with(slots, fires, fn slot, fire -> round(fire - slot) end)

    detail =
      "#{length(fires)} fire(s) for #{length(slots)} slot(s), " <>
        "off by #{Enum.map_join(errors, ", ", &signed/1)} ms"

    ok = length(fires) == length(slots) and Enum.all?(errors, &(abs(&1) <= @cron_tolerance_ms))
    [finding("schedule-once-on-time", ok, detail)]
  end

  # ---------------------------------------------------------------------------
  # Nodes don't see each other as missing.
  # ---------------------------------------------------------------------------

  defp alive(nodes) do
    for label <- @labels do
      {:ok, seen} = call(nodes, label, Durable, :list_nodes, [[]])
      missing = for %{status: :missing, id: id} <- seen, do: id

      finding(
        "nodes-alive",
        length(seen) == length(@labels) and missing == [],
        "#{label} sees #{length(seen)} node(s)" <>
          if(missing == [], do: "", else: ", missing: #{Enum.join(missing, ", ")}")
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Reading the marks
  # ---------------------------------------------------------------------------

  defp db_now do
    %{rows: [[at]]} = Repo.query!("SELECT extract(epoch FROM clock_timestamp()) * 1000")
    Decimal.to_float(at)
  end

  # [{group, node, from, to}] of the marks of `kind` on `ids`, grouped by `by`.
  defp intervals(by, ids, kind) do
    %{rows: rows} =
      Repo.query!(
        "SELECT #{by}::text, min(node), min(at), max(at) FROM skew.marks " <>
          "WHERE run_id = ANY($1) AND kind = $2 GROUP BY #{by} ORDER BY min(at)",
        [Enum.map(ids, &Ecto.UUID.dump!/1), kind]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp overlaps(intervals) do
    for {a, i} <- Enum.with_index(intervals),
        {b, j} <- Enum.with_index(intervals),
        i < j,
        {_, node_a, from_a, to_a} = a,
        {_, node_b, from_b, to_b} = b,
        (ms = min(to_a, to_b) - max(from_a, from_b)) > 0,
        do: {node_a, node_b, round(ms)}
  end

  defp overlap_text([]), do: ""

  defp overlap_text(overlaps) do
    "; ran at once: " <>
      Enum.map_join(overlaps, ", ", fn {a, b, ms} -> "#{a} and #{b} for #{ms} ms" end)
  end

  defp first_at(id, kind), do: one("min(at)", id, kind)
  defp last_at(id, kind), do: one("max(at)", id, kind)

  defp one(select, id, kind) do
    %{rows: [[at]]} =
      Repo.query!("SELECT #{select} FROM skew.marks WHERE run_id = $1 AND kind = $2", [
        Ecto.UUID.dump!(id),
        kind
      ])

    at
  end

  defp all_at(kind) do
    %{rows: rows} = Repo.query!("SELECT at FROM skew.marks WHERE kind = $1 ORDER BY at", [kind])
    List.flatten(rows)
  end

  defp backoff_ms(id) do
    %{rows: [[ms]]} =
      Repo.query!(
        "SELECT (info->>'ms')::int FROM skew.marks WHERE run_id = $1 AND kind = 'backoff' ORDER BY at LIMIT 1",
        [Ecto.UUID.dump!(id)]
      )

    ms
  end

  defp await_final(id, timeout) do
    query = fn ->
      %{rows: [[status]]} =
        Repo.query!("SELECT status FROM durable.workflow_executions WHERE id = $1", [
          Ecto.UUID.dump!(id)
        ])

      status
    end

    _ = await(fn -> query.() in @final end, timeout)
    query.()
  end

  defp await!(fun, timeout, what) do
    if not await(fun, timeout), do: raise("timed out waiting for #{what}")
  end

  defp await(fun, timeout) do
    cond do
      fun.() ->
        true

      timeout <= 0 ->
        false

      true ->
        Process.sleep(50)
        await(fun, timeout - 50)
    end
  end

  defp signed(n) when n > 0, do: "+#{n}"
  defp signed(n), do: "#{n}"

  defp finding(invariant, ok, detail), do: {invariant, ok, detail}

  defp report(skew, findings) do
    for {invariant, ok, detail} <- findings do
      IO.puts("RESULT skew=#{skew}s #{invariant} #{if ok, do: "PASS", else: "FAIL"} #{detail}")
    end

    findings
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {invariant, oks} ->
      IO.puts("SUMMARY skew=#{skew}s #{invariant} #{Enum.count(oks, & &1)}/#{length(oks)}")
    end)
  end
end

case System.get_env("ROLE") do
  "node" ->
    Skew.boot_node()
    Process.sleep(:infinity)

  "setup" ->
    Skew.setup()

  "orch" ->
    Skew.Orch.run()
end
