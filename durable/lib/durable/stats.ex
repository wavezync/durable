defmodule Durable.Stats do
  @moduledoc """
  Aggregate health of a Durable instance, read straight from its tables —
  the numbers behind the dashboard's Overview and Workflow pages, available
  to your own alerts and dashboards too.

  Postgres is the source of truth here, so these work across nodes and
  survive restarts; use `Durable.Telemetry` for live per-node signals.

  ## Common options

    * `:durable` — instance name (default `Durable`)
    * `:since` / `:until` — the window (`DateTime`; default the last 24 hours)
    * `:workflow` — limit to one workflow name
    * `:include_children` — count child runs too (default `false`: parallel
      fan-out and called workflows would otherwise inflate every number)

  A run counts as *started* in the window by `inserted_at` and *finished* by
  `completed_at`. "Failed" here means failed, rolled back (compensated) or
  rollback-failed — every run that didn't do what it set out to.
  """

  import Ecto.Query

  alias Durable.Config
  alias Durable.Repo

  alias Durable.Storage.Schemas.{
    PendingEvent,
    PendingInput,
    Queue,
    QueueSample,
    StepExecution,
    WorkflowExecution
  }

  @failed [:failed, :compensated, :compensation_failed]
  @finished [:completed, :cancelled | @failed]

  @doc """
  Headline numbers for the window:

      %{
        started: 12_482,
        finished: %{completed: 12_031, failed: 180, compensated: 34, cancelled: 21, ...},
        failure_rate: 0.017,            # failed-like ÷ finished
        duration_ms: %{p50: 380, p95: 4_210, max: 11_800},   # completed runs
        queue_wait_ms: %{p50: 120, p95: 1_300},             # scheduled → started
        backlog: 37,                    # ready to start right now
        waiting: %{input: 9, event: 96, sleeping: 23}       # right now
      }
  """
  @spec overview(keyword()) :: map()
  def overview(opts \\ []) do
    {config, since, until} = window(opts)
    runs = runs(opts)

    finished =
      Repo.all(
        config,
        from(w in runs,
          where: w.status in ^@finished and w.completed_at >= ^since and w.completed_at < ^until,
          group_by: w.status,
          select: {w.status, count(w.id)}
        )
      )
      |> Map.new()

    total = finished |> Map.values() |> Enum.sum()
    failed = @failed |> Enum.map(&Map.get(finished, &1, 0)) |> Enum.sum()

    %{
      started:
        Repo.one(
          config,
          from(w in runs,
            where: w.inserted_at >= ^since and w.inserted_at < ^until,
            select: count(w.id)
          )
        ),
      finished: finished,
      failure_rate: if(total > 0, do: failed / total, else: 0.0),
      duration_ms: duration_percentiles(config, runs, since, until),
      queue_wait_ms: queue_wait_percentiles(config, runs, since, until),
      backlog: Repo.one(config, from(w in ready(runs), select: count(w.id))),
      waiting: waiting(config, opts)
    }
  end

  @doc """
  The window cut into `:bucket_seconds` (default: ~48 buckets), oldest
  first, zero-filled:

      [%{at: ~U[...], started: 260, completed: 251, failed: 6, cancelled: 1,
         failure_rate: 0.023, p50_ms: 1_900, p95_ms: 4_200}, ...]

  `failed` includes rolled-back runs; `p50_ms`/`p95_ms` are over runs
  completed in the bucket (nil when none).
  """
  @spec timeline(keyword()) :: [map()]
  def timeline(opts \\ []) do
    {config, since, until} = window(opts)
    span = DateTime.diff(until, since, :second)
    bucket = Keyword.get(opts, :bucket_seconds, max(div(span, 48), 60))
    runs = runs(opts)
    origin = DateTime.to_unix(since)

    finished =
      Repo.all(
        config,
        from(w in runs,
          where: w.status in ^@finished and w.completed_at >= ^since and w.completed_at < ^until,
          group_by: [fragment("bucket"), w.status],
          select: {
            fragment(
              "floor((extract(epoch from ?) - ?) / ?)::int AS bucket",
              w.completed_at,
              ^origin,
              ^bucket
            ),
            w.status,
            count(w.id)
          }
        )
      )

    started =
      Repo.all(
        config,
        from(w in runs,
          where: w.inserted_at >= ^since and w.inserted_at < ^until,
          group_by: fragment("bucket"),
          select: {
            fragment(
              "floor((extract(epoch from ?) - ?) / ?)::int AS bucket",
              w.inserted_at,
              ^origin,
              ^bucket
            ),
            count(w.id)
          }
        )
      )
      |> Map.new()

    durations =
      Repo.all(
        config,
        from(w in runs,
          where: w.status == :completed and w.completed_at >= ^since and w.completed_at < ^until,
          where: not is_nil(w.started_at),
          group_by: fragment("bucket"),
          select: {
            fragment(
              "floor((extract(epoch from ?) - ?) / ?)::int AS bucket",
              w.completed_at,
              ^origin,
              ^bucket
            ),
            fragment(
              "percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch from (? - ?)) * 1000)",
              w.completed_at,
              w.started_at
            ),
            fragment(
              "percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch from (? - ?)) * 1000)",
              w.completed_at,
              w.started_at
            )
          }
        )
      )
      |> Map.new(fn {b, p50, p95} -> {b, {round(p50), round(p95)}} end)

    by_bucket = Enum.group_by(finished, &elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

    for b <- 0..max(div(span - 1, bucket), 0) do
      counts = Map.new(Map.get(by_bucket, b, []))
      failed = @failed |> Enum.map(&Map.get(counts, &1, 0)) |> Enum.sum()
      total = counts |> Map.values() |> Enum.sum()
      {p50, p95} = Map.get(durations, b, {nil, nil})

      %{
        at: DateTime.add(since, b * bucket, :second),
        started: Map.get(started, b, 0),
        completed: Map.get(counts, :completed, 0),
        failed: failed,
        cancelled: Map.get(counts, :cancelled, 0),
        failure_rate: if(total > 0, do: failed / total, else: 0.0),
        p50_ms: p50,
        p95_ms: p95
      }
    end
  end

  @doc """
  Failures grouped by what went wrong: error type, message with numbers
  replaced by `<n>` (so "timeout after 1503ms" and "after 1499ms" group), and
  the step it happened at. Biggest group first.

      [%{workflow: "fulfill_order", step: "ship_order", type: "RuntimeError",
         message: "carrier API returned <n>", count: 41,
         first_at: ~U[...], last_at: ~U[...], rolled_back: 41}]
  """
  @spec error_groups(keyword()) :: [map()]
  def error_groups(opts \\ []) do
    {config, since, until} = window(opts)

    Repo.all(
      config,
      from(w in runs(opts),
        where: w.status in ^@failed and w.completed_at >= ^since and w.completed_at < ^until,
        group_by: [
          w.workflow_name,
          w.current_step,
          fragment("? ->> 'type'", w.error),
          fragment(
            "regexp_replace(coalesce(? ->> 'message', ? ->> 'reason', ?::text), '[0-9]+', '<n>', 'g')",
            w.error,
            w.error,
            w.error
          )
        ],
        order_by: [desc: count(w.id)],
        limit: ^Keyword.get(opts, :limit, 20),
        select: %{
          workflow: w.workflow_name,
          type: fragment("? ->> 'type'", w.error),
          message:
            fragment(
              "regexp_replace(coalesce(? ->> 'message', ? ->> 'reason', ?::text), '[0-9]+', '<n>', 'g')",
              w.error,
              w.error,
              w.error
            ),
          step: w.current_step,
          count: count(w.id),
          first_at: min(w.completed_at),
          last_at: max(w.completed_at),
          rolled_back: filter(count(w.id), w.status == :compensated)
        }
      )
    )
  end

  @doc """
  Workflows with failures in the window, worst first, each with its biggest
  error group:

      [%{workflow: "fulfill_order", failed: 41, finished: 660, failure_rate: 0.062,
         last_failed_at: ~U[...], top_error: %{type:, message:, step:, count:}}]
  """
  @spec failing_workflows(keyword()) :: [map()]
  def failing_workflows(opts \\ []) do
    {config, since, until} = window(opts)

    rows =
      Repo.all(
        config,
        from(w in runs(opts),
          where: w.status in ^@finished and w.completed_at >= ^since and w.completed_at < ^until,
          group_by: w.workflow_name,
          having: filter(count(w.id), w.status in ^@failed) > 0,
          order_by: [desc: filter(count(w.id), w.status in ^@failed)],
          limit: ^Keyword.get(opts, :limit, 5),
          select: %{
            workflow: w.workflow_name,
            failed: filter(count(w.id), w.status in ^@failed),
            finished: count(w.id),
            last_failed_at: filter(max(w.completed_at), w.status in ^@failed)
          }
        )
      )

    tops =
      opts
      |> Keyword.put(:limit, 200)
      |> error_groups()
      |> Enum.group_by(& &1.workflow)

    Enum.map(rows, fn row ->
      top = tops |> Map.get(row.workflow, []) |> List.first()

      Map.merge(row, %{
        failure_rate: row.failed / row.finished,
        top_error: top && Map.take(top, [:type, :message, :step, :count])
      })
    end)
  end

  @doc """
  Every workflow that has run, with its numbers for the window — one grouped
  query, for a catalog page. Busiest first.

      [%{workflow: "fulfill_order", module: "Elixir.App.Orders", started: 660,
         finished: 655, failed: 41, failure_rate: 0.063, retried: 121,
         p50_ms: 1_920, p95_ms: 4_210, running: 4, waiting: 0,
         last_run_at: ~U[...]}]

  `retried` counts runs where some step needed a second attempt. `running`,
  `waiting` and `last_run_at` are as of now, not limited to the window.
  """
  @spec workflows(keyword()) :: [map()]
  def workflows(opts \\ []) do
    {config, since, until} = window(opts)

    config
    |> Repo.all(
      from(w in runs(opts),
        as: :run,
        group_by: [w.workflow_name, w.workflow_module],
        order_by: [desc: max(w.inserted_at)],
        select: %{
          workflow: w.workflow_name,
          module: w.workflow_module,
          started: filter(count(w.id), w.inserted_at >= ^since and w.inserted_at < ^until),
          finished:
            filter(
              count(w.id),
              w.status in ^@finished and w.completed_at >= ^since and w.completed_at < ^until
            ),
          failed:
            filter(
              count(w.id),
              w.status in ^@failed and w.completed_at >= ^since and w.completed_at < ^until
            ),
          # An Ecto subquery, not raw SQL, so the schema prefix applies to it.
          retried:
            filter(
              count(w.id),
              w.inserted_at >= ^since and w.inserted_at < ^until and
                exists(
                  from(s in StepExecution,
                    where: s.workflow_id == parent_as(:run).id and s.attempt > 1,
                    select: 1
                  )
                )
            ),
          p50_ms:
            fragment(
              "percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch from (? - ?)) * 1000) FILTER (WHERE ? = 'completed' AND ? >= ? AND ? < ?)",
              w.completed_at,
              w.started_at,
              w.status,
              w.completed_at,
              ^since,
              w.completed_at,
              ^until
            ),
          p95_ms:
            fragment(
              "percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch from (? - ?)) * 1000) FILTER (WHERE ? = 'completed' AND ? >= ? AND ? < ?)",
              w.completed_at,
              w.started_at,
              w.status,
              w.completed_at,
              ^since,
              w.completed_at,
              ^until
            ),
          running: filter(count(w.id), w.status == :running),
          waiting: filter(count(w.id), w.status == :waiting),
          last_run_at: max(w.inserted_at)
        }
      )
    )
    |> Enum.map(fn row ->
      Map.merge(row, %{
        failure_rate: if(row.finished > 0, do: row.failed / row.finished, else: 0.0),
        p50_ms: round_ms(row.p50_ms),
        p95_ms: round_ms(row.p95_ms)
      })
    end)
  end

  @doc """
  Per-step performance over attempts that started in the window, in the
  order steps first ran. Durations are active time — sleeps and waits are
  not attempts. Compensations are included with `compensation: true`.

  `failed_runs` counts runs whose last attempt at the step failed — runs that
  gave up there, as opposed to `failed_attempts` that a retry recovered.

      [%{workflow: "fulfill_order", step: "ship_order", compensation: false,
         runs: 660, attempts: 771, failed_attempts: 117, failed_runs: 41,
         retried_runs: 121, p50_ms: 640, p95_ms: 2_140, max_ms: 6_040}]
  """
  @spec step_performance(keyword()) :: [map()]
  def step_performance(opts \\ []) do
    {config, since, until} = window(opts)

    query =
      from(s in StepExecution,
        as: :step,
        join: w in WorkflowExecution,
        on: w.id == s.workflow_id,
        where: s.started_at >= ^since and s.started_at < ^until and s.status != :waiting,
        group_by: [w.workflow_name, s.step_name],
        order_by: [asc: min(s.started_at)],
        select: %{
          workflow: w.workflow_name,
          step: s.step_name,
          compensation: fragment("bool_or(?)", s.is_compensation),
          runs: count(s.workflow_id, :distinct),
          attempts: count(s.id),
          failed_attempts: filter(count(s.id), s.status == :failed),
          failed_runs:
            filter(
              count(s.workflow_id, :distinct),
              s.status == :failed and
                not exists(
                  from(later in StepExecution,
                    where:
                      later.workflow_id == parent_as(:step).workflow_id and
                        later.step_name == parent_as(:step).step_name and
                        later.status != :waiting and
                        later.started_at > parent_as(:step).started_at,
                    select: 1
                  )
                )
            ),
          retried_runs:
            fragment("count(DISTINCT ?) FILTER (WHERE ? > 1)", s.workflow_id, s.attempt),
          p50_ms: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", s.duration_ms),
          p95_ms: fragment("percentile_cont(0.95) WITHIN GROUP (ORDER BY ?)", s.duration_ms),
          max_ms: max(s.duration_ms)
        }
      )

    query =
      case Keyword.get(opts, :workflow) do
        nil -> query
        name -> from([s, w] in query, where: w.workflow_name == ^name)
      end

    config
    |> Repo.all(query)
    |> Enum.map(fn row -> %{row | p50_ms: round_ms(row.p50_ms), p95_ms: round_ms(row.p95_ms)} end)
  end

  @doc """
  Every queue's state right now — configured queues are listed even when idle:

      [%{queue: "default", paused: false, running: 8, ready: 31, scheduled: 412,
         oldest_ready_at: ~U[...], done_last_5m: 910, wait_p95_ms: 1_300}]

  `wait_p95_ms` is scheduled → started over the last hour.
  """
  @spec queues(keyword()) :: [map()]
  def queues(opts \\ []) do
    config = Config.get(Keyword.get(opts, :durable, Durable))
    now = DateTime.utc_now()
    hour_ago = DateTime.add(now, -3_600, :second)
    five_min_ago = DateTime.add(now, -300, :second)

    live =
      Repo.all(
        config,
        from(w in WorkflowExecution,
          where: w.status in [:pending, :running],
          group_by: w.queue,
          select:
            {w.queue,
             %{
               running: filter(count(w.id), w.status == :running),
               ready:
                 filter(
                   count(w.id),
                   w.status == :pending and (is_nil(w.scheduled_at) or w.scheduled_at <= ^now)
                 ),
               scheduled: filter(count(w.id), w.status == :pending and w.scheduled_at > ^now),
               # A raw fragment loses the column type; cast it back so the
               # result is a DateTime rather than a NaiveDateTime.
               oldest_ready_at:
                 type(
                   fragment(
                     "min(coalesce(?, ?)) FILTER (WHERE ? = 'pending' AND (? IS NULL OR ? <= ?))",
                     w.scheduled_at,
                     w.inserted_at,
                     w.status,
                     w.scheduled_at,
                     w.scheduled_at,
                     ^now
                   ),
                   :utc_datetime_usec
                 )
             }}
        )
      )
      |> Map.new()

    recent =
      Repo.all(
        config,
        from(w in WorkflowExecution,
          where: not is_nil(w.started_at) and w.started_at >= ^hour_ago,
          group_by: w.queue,
          select:
            {w.queue,
             %{
               done_last_5m: filter(count(w.id), w.completed_at >= ^five_min_ago),
               wait_p95_ms:
                 fragment(
                   "percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch from (? - coalesce(?, ?))) * 1000)",
                   w.started_at,
                   w.scheduled_at,
                   w.inserted_at
                 )
             }}
        )
      )
      |> Map.new()

    paused =
      MapSet.new(
        Repo.all(config, from(q in Queue, where: not is_nil(q.paused_at), select: q.name))
      )

    names = Enum.map(Map.keys(config.queues), &to_string/1)

    (names ++ Map.keys(live) ++ Map.keys(recent))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name ->
      l = Map.get(live, name, %{running: 0, ready: 0, scheduled: 0, oldest_ready_at: nil})
      r = Map.get(recent, name, %{done_last_5m: 0, wait_p95_ms: nil})

      Map.merge(l, %{
        queue: name,
        paused: MapSet.member?(paused, name),
        done_last_5m: r.done_last_5m,
        wait_p95_ms: round_ms(r.wait_p95_ms)
      })
    end)
  end

  @doc """
  Each queue's depth per minute over the window, from `Durable.Queue.Sampler`,
  oldest first. Minutes with no sample (no node was up) are absent.

      %{"default" => [%{at: ~U[2026-10-16 09:00:00Z], ready: 31, scheduled: 4,
                        running: 8, waiting: 120}, ...]}
  """
  @spec queue_history(keyword()) :: %{String.t() => [map()]}
  def queue_history(opts \\ []) do
    {config, since, until} = window(opts)

    config
    |> Repo.all(
      from(s in QueueSample,
        where: s.at >= ^since and s.at <= ^until,
        order_by: [asc: s.at],
        select: %{
          queue: s.queue,
          at: s.at,
          ready: s.ready,
          scheduled: s.scheduled,
          running: s.running,
          waiting: s.waiting
        }
      )
    )
    |> Enum.group_by(& &1.queue, &Map.delete(&1, :queue))
  end

  # --------------------------------------------------------------------------

  defp window(opts) do
    config = Config.get(Keyword.get(opts, :durable, Durable))
    until = Keyword.get(opts, :until, DateTime.utc_now())
    since = Keyword.get(opts, :since, DateTime.add(until, -86_400, :second))
    {config, since, until}
  end

  defp runs(opts) do
    query = WorkflowExecution

    query =
      if Keyword.get(opts, :include_children, false),
        do: query,
        else: from(w in query, where: is_nil(w.parent_workflow_id))

    case Keyword.get(opts, :workflow) do
      nil -> query
      name -> from(w in query, where: w.workflow_name == ^name)
    end
  end

  defp ready(runs) do
    now = DateTime.utc_now()

    from(w in runs,
      where: w.status == :pending and (is_nil(w.scheduled_at) or w.scheduled_at <= ^now)
    )
  end

  defp duration_percentiles(config, runs, since, until) do
    Repo.one(
      config,
      from(w in runs,
        where: w.status == :completed and w.completed_at >= ^since and w.completed_at < ^until,
        where: not is_nil(w.started_at),
        select: %{
          p50:
            fragment(
              "percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch from (? - ?)) * 1000)",
              w.completed_at,
              w.started_at
            ),
          p95:
            fragment(
              "percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch from (? - ?)) * 1000)",
              w.completed_at,
              w.started_at
            ),
          max: fragment("max(extract(epoch from (? - ?)) * 1000)", w.completed_at, w.started_at)
        }
      )
    )
    |> Map.new(fn {k, v} -> {k, round_ms(v)} end)
  end

  defp queue_wait_percentiles(config, runs, since, until) do
    Repo.one(
      config,
      from(w in runs,
        where: w.inserted_at >= ^since and w.inserted_at < ^until and not is_nil(w.started_at),
        select: %{
          p50:
            fragment(
              "percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch from (? - coalesce(?, ?))) * 1000)",
              w.started_at,
              w.scheduled_at,
              w.inserted_at
            ),
          p95:
            fragment(
              "percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch from (? - coalesce(?, ?))) * 1000)",
              w.started_at,
              w.scheduled_at,
              w.inserted_at
            )
        }
      )
    )
    |> Map.new(fn {k, v} -> {k, round_ms(v)} end)
  end

  # Internal events (`__parallel_done:…`, `__child_done:…`) are plumbing, not
  # something a person is waiting on.
  defp waiting(config, opts) do
    workflow = Keyword.get(opts, :workflow)

    scope = fn query ->
      if workflow,
        do: from([x, w] in query, where: w.workflow_name == ^workflow),
        else: query
    end

    inputs =
      from(p in PendingInput,
        join: w in WorkflowExecution,
        on: w.id == p.workflow_id,
        where: p.status == :pending
      )

    events =
      from(e in PendingEvent,
        join: w in WorkflowExecution,
        on: w.id == e.workflow_id,
        where: e.status == :pending and not like(e.event_name, "\\_\\_%")
      )

    sleeping =
      from(w in WorkflowExecution, where: w.status == :waiting and not is_nil(w.scheduled_at))

    sleeping =
      if workflow, do: from(w in sleeping, where: w.workflow_name == ^workflow), else: sleeping

    %{
      input: Repo.one(config, from([p] in scope.(inputs), select: count(p.id))),
      event: Repo.one(config, from([e] in scope.(events), select: count(e.id))),
      sleeping: Repo.one(config, from(w in sleeping, select: count(w.id)))
    }
  end

  defp round_ms(nil), do: nil
  defp round_ms(value) when is_float(value), do: round(value)
  defp round_ms(%Decimal{} = value), do: value |> Decimal.round() |> Decimal.to_integer()
  defp round_ms(value), do: value
end
