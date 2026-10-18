defmodule Durable.StatsTest do
  @moduledoc """
  `Durable.Stats`: the aggregates behind the Overview and Workflow pages,
  computed from the tables.
  """
  use Durable.DataCase, async: false
  use ExUnitProperties

  alias Durable.Config
  alias Durable.Stats
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, StepExecution, WorkflowExecution}

  @until ~U[2026-10-16 12:00:00.000000Z]
  @since ~U[2026-10-16 00:00:00.000000Z]

  defp at(minutes), do: DateTime.add(@since, minutes * 60, :second)
  defp repo, do: Config.get(Durable).repo

  defp run!(attrs) do
    defaults = %{
      workflow_module: "Elixir.App.Flow",
      workflow_name: "flow",
      status: :completed,
      queue: "default",
      input: %{},
      context: %{},
      inserted_at: at(10),
      updated_at: at(10)
    }

    repo().insert!(struct(WorkflowExecution, Map.merge(defaults, Map.new(attrs))))
  end

  defp opts(extra \\ []), do: [since: @since, until: @until] ++ extra

  describe "overview/1" do
    test "counts what started and finished in the window, and what's waiting now" do
      run!(status: :completed, started_at: at(10), completed_at: DateTime.add(at(10), 2, :second))
      run!(status: :completed, started_at: at(20), completed_at: DateTime.add(at(20), 4, :second))
      run!(status: :failed, completed_at: at(30))
      run!(status: :compensated, completed_at: at(31))
      run!(status: :cancelled, completed_at: at(32))
      run!(status: :completed, completed_at: at(-10), inserted_at: at(-20))
      run!(status: :completed, completed_at: at(40), parent_workflow_id: run!([]).id)

      run!(status: :pending, inserted_at: at(50))
      run!(status: :pending, scheduled_at: DateTime.add(DateTime.utc_now(), 3_600, :second))

      sleeper =
        run!(status: :waiting, scheduled_at: DateTime.add(DateTime.utc_now(), 60, :second))

      asker = run!(status: :waiting)

      repo().insert!(%PendingInput{
        workflow_id: asker.id,
        input_name: "approve",
        step_name: "ask"
      })

      repo().insert!(%PendingEvent{workflow_id: asker.id, event_name: "paid", step_name: "ask"})

      repo().insert!(%PendingEvent{
        workflow_id: sleeper.id,
        event_name: "__parallel_done:x",
        step_name: "p"
      })

      stats = Stats.overview(opts())

      # 10 top-level runs inserted inside the window — the child's parent
      # counts, the child itself doesn't, nor does the run from before.
      assert stats.started == 10
      assert stats.finished == %{completed: 2, failed: 1, compensated: 1, cancelled: 1}
      assert_in_delta stats.failure_rate, 2 / 5, 0.0001
      assert stats.duration_ms.p50 == 3_000
      assert stats.duration_ms.max == 4_000
      assert stats.backlog == 1
      assert stats.waiting == %{input: 1, event: 1, sleeping: 1}
    end

    test "is all zeros and nils on an empty instance" do
      stats = Stats.overview(opts())
      assert %{started: 0, finished: %{}, failure_rate: 0.0, backlog: 0} = stats
      assert stats.duration_ms == %{p50: nil, p95: nil, max: nil}
    end
  end

  test "timeline/1 buckets finished runs, zero-filled, oldest first" do
    run!(status: :completed, started_at: at(5), completed_at: at(10))
    run!(status: :failed, completed_at: at(70))
    run!(status: :compensated, completed_at: at(75))
    run!(status: :completed, started_at: at(60), completed_at: at(80))

    buckets = Stats.timeline(opts(bucket_seconds: 3_600))

    assert length(buckets) == 12
    assert hd(buckets).at == @since
    assert [first, second | rest] = buckets
    assert %{completed: 1, failed: 0, p50_ms: 300_000} = first
    assert %{completed: 1, failed: 2, failure_rate: rate} = second
    assert_in_delta rate, 2 / 3, 0.0001
    assert Enum.all?(rest, &(&1.completed == 0 and &1.failed == 0 and &1.p50_ms == nil))
  end

  test "error_groups/1 groups failures by type, numberless message and step" do
    run!(
      status: :failed,
      current_step: "ship",
      completed_at: at(1),
      error: %{"type" => "RuntimeError", "message" => "timeout after 1503ms"}
    )

    run!(
      status: :compensated,
      current_step: "ship",
      completed_at: at(2),
      error: %{"type" => "RuntimeError", "message" => "timeout after 99ms"}
    )

    run!(
      status: :failed,
      current_step: "charge",
      completed_at: at(3),
      error: %{"reason" => "card declined"}
    )

    assert [biggest, other] = Stats.error_groups(opts())

    assert %{
             type: "RuntimeError",
             message: "timeout after <n>ms",
             step: "ship",
             count: 2,
             rolled_back: 1
           } = biggest

    assert %{type: nil, message: "card declined", step: "charge", count: 1} = other
  end

  test "failing_workflows/1 ranks workflows by failures with their top error" do
    for i <- 1..3,
        do:
          run!(
            workflow_name: "orders",
            status: :failed,
            current_step: "ship",
            completed_at: at(i),
            error: %{"message" => "503"}
          )

    for i <- 1..7, do: run!(workflow_name: "orders", status: :completed, completed_at: at(i))

    run!(
      workflow_name: "emails",
      status: :failed,
      completed_at: at(9),
      error: %{"message" => "421"}
    )

    run!(workflow_name: "quiet", status: :completed, completed_at: at(9))

    assert [orders, emails] = Stats.failing_workflows(opts())
    assert %{workflow: "orders", failed: 3, finished: 10, failure_rate: 0.3} = orders
    assert %{step: "ship", message: "<n>", count: 3} = orders.top_error
    assert emails.workflow == "emails"
  end

  test "step_performance/1 reports attempts, retries and active-time percentiles per step" do
    for n <- 1..4 do
      run = run!(started_at: at(n))
      step!(run, "reserve", 1, :completed, 100 * n, at(n))

      if n == 4 do
        step!(run, "ship", 1, :failed, 2_000, at(n))
        step!(run, "ship", 2, :completed, 500, at(n))
      else
        step!(run, "ship", 1, :completed, 500, at(n))
      end

      step!(run, "ship", 1, :waiting, nil, at(n))
    end

    assert [reserve, ship] = Stats.step_performance(opts(workflow: "flow"))

    assert %{
             step: "reserve",
             runs: 4,
             attempts: 4,
             failed_attempts: 0,
             retried_runs: 0,
             p50_ms: 250,
             max_ms: 400
           } = reserve

    assert %{
             step: "ship",
             runs: 4,
             attempts: 5,
             failed_attempts: 1,
             retried_runs: 1,
             max_ms: 2_000
           } = ship
  end

  test "step_performance/1 counts the runs that gave up at a step apart from recovered attempts" do
    recovered = run!(started_at: at(1))
    step!(recovered, "ship", 1, :failed, 10, at(1))
    step!(recovered, "ship", 2, :completed, 10, DateTime.add(at(1), 1, :second))

    gave_up = run!(started_at: at(2))
    step!(gave_up, "ship", 1, :failed, 10, at(2))
    step!(gave_up, "ship", 2, :failed, 10, DateTime.add(at(2), 1, :second))

    assert [%{step: "ship", runs: 2, failed_attempts: 3, failed_runs: 1}] =
             Stats.step_performance(opts(workflow: "flow"))
  end

  defp step!(run, name, attempt, status, duration, started) do
    repo().insert!(%StepExecution{
      workflow_id: run.id,
      step_name: name,
      attempt: attempt,
      status: status,
      duration_ms: duration,
      started_at: started
    })
  end

  test "queues/1 lists configured queues, live counts and pause state" do
    run!(queue: "default", status: :running)

    run!(
      queue: "default",
      status: :pending,
      inserted_at: DateTime.add(DateTime.utc_now(), -30, :second)
    )

    run!(
      queue: "billing",
      status: :pending,
      scheduled_at: DateTime.add(DateTime.utc_now(), 600, :second)
    )

    :ok = Durable.pause_queue(:billing)

    queues = Map.new(Stats.queues(), &{&1.queue, &1})

    assert %{running: 1, ready: 1, scheduled: 0, paused: false, oldest_ready_at: %DateTime{}} =
             queues["default"]

    assert %{running: 0, ready: 0, scheduled: 1, paused: true} = queues["billing"]
  end

  test "workflows/1 rolls each workflow up in one query" do
    for i <- 1..3 do
      run =
        run!(
          workflow_name: "orders",
          status: :completed,
          started_at: at(i),
          completed_at: DateTime.add(at(i), i, :second)
        )

      if i == 1 do
        step!(run, "ship", 1, :failed, 10, at(i))
        step!(run, "ship", 2, :completed, 10, at(i))
      end

      # A failure with no second attempt isn't a retry.
      if i == 2, do: step!(run, "pack", 1, :failed, 10, at(i))
    end

    run!(workflow_name: "orders", status: :failed, completed_at: at(5))
    run!(workflow_name: "orders", status: :running)
    run!(workflow_name: "emails", status: :waiting)

    rows = Map.new(Stats.workflows(opts()), &{&1.workflow, &1})

    assert %{
             started: 5,
             finished: 4,
             failed: 1,
             failure_rate: 0.25,
             retried: 1,
             running: 1,
             p50_ms: 2_000
           } =
             rows["orders"]

    assert %{started: 1, finished: 0, waiting: 1, failure_rate: 0.0} = rows["emails"]
  end

  property "the timeline and the overview agree on what finished" do
    check all(
            runs <-
              list_of(
                tuple(
                  {member_of([:completed, :failed, :compensated, :cancelled]), integer(0..719)}
                ),
                max_length: 25
              ),
            bucket_minutes <- member_of([15, 30, 60, 240]),
            max_runs: 30
          ) do
      repo().delete_all(WorkflowExecution)
      for {status, minute} <- runs, do: run!(status: status, completed_at: at(minute))

      overview = Stats.overview(opts())
      timeline = Stats.timeline(opts(bucket_seconds: bucket_minutes * 60))

      assert length(timeline) == div(720, bucket_minutes)

      timeline_total = Enum.sum(Enum.map(timeline, &(&1.completed + &1.failed + &1.cancelled)))
      assert timeline_total == overview.finished |> Map.values() |> Enum.sum()
      assert timeline_total == length(runs)
    end
  end
end
