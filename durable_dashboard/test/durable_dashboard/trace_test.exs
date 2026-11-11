defmodule DurableDashboard.TraceTest do
  @moduledoc """
  The run page's trace builder: rows per step, bars per attempt, the gaps
  between attempts, the compensation lane, and error parsing.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DurableDashboard.Trace

  @t0 ~U[2026-10-16 10:00:00.000000Z]
  defp t(ms), do: DateTime.add(@t0, ms, :millisecond)

  defp run(attrs \\ []),
    do: Enum.into(attrs, %{id: "run-1", status: :completed, started_at: t(0)})

  defp step(name, attrs) do
    from = Keyword.get(attrs, :from, 0)
    to = Keyword.get(attrs, :to, from + 10)

    Enum.into(attrs, %{
      id: "#{name}-#{Keyword.get(attrs, :attempt, 1)}-#{from}",
      workflow_id: "run-1",
      step_name: name,
      step_type: "step",
      status: :completed,
      attempt: 1,
      is_compensation: false,
      child_workflow_id: nil,
      started_at: t(from),
      completed_at: t(to),
      updated_at: t(to),
      inserted_at: t(from),
      duration_ms: to - from,
      input: nil,
      output: nil,
      error: nil,
      logs: []
    })
    |> Map.drop([:from, :to])
  end

  @snoozed %{"type" => "snoozed", "message" => "busy", "snooze_ms" => 1_000}

  describe "snoozes" do
    test "a snooze is a bar and a named gap, but not an attempt" do
      steps = [
        step("render", status: :snoozed, error: @snoozed, from: 0, to: 10),
        step("render", status: :snoozed, error: @snoozed, from: 2_010, to: 2_020),
        step("render", status: :completed, from: 4_020, to: 4_030)
      ]

      %{rows: [row]} = Trace.build(run(), steps, [], t(4_030))

      assert {row.attempts, row.snoozes, row.status} == {1, 2, :completed}
      assert row.duration_ms == 10
      assert Enum.map(row.segments, & &1.kind) == [:other, :snoozed, :other, :snoozed, :ok]

      [bar, gap | _] = row.segments
      assert gap.label == "snoozed 2s"
      assert bar.title =~ "Snoozed"
      assert bar.meta == "busy"
      assert bar.label == nil
    end

    test "a narrow gap has no room for its name" do
      steps = [
        step("render", status: :failed, from: 0, to: 10),
        step("render", attempt: 2, status: :completed, from: 11, to: 1_000)
      ]

      %{rows: [%{segments: [_bar, gap, _next]}]} = Trace.build(run(), steps, [], t(1_000))
      assert gap.kind == :backoff
      assert gap.label == nil
    end

    test "error_parts reads a snooze's reason, and says nothing without one" do
      assert %{message: "busy", type: nil} = Trace.error_parts(@snoozed)
      assert %{message: nil} = Trace.error_parts(%{"type" => "snoozed", "snooze_ms" => 5})
    end

    test "error_parts has no message to show for a cancel with no reason" do
      assert %{message: nil, type: "cancelled"} = Trace.error_parts(%{"type" => "cancelled"})
    end
  end

  describe "a parked run" do
    defp parked_run(step \\ "charge"),
      do: run(status: :pending, scheduled_at: t(5_000), current_step: step)

    defp failed(attrs \\ []) do
      step("charge", [status: :failed, attempt: 2, error: %{"message" => "timeout"}] ++ attrs)
    end

    test "parked/2 names a retry" do
      assert %{status: :retrying, step: "charge", attempt: 2, max: nil, reason: "timeout"} =
               Trace.parked(parked_run(), failed())
    end

    test "parked/2 names a snooze" do
      snoozed = step("charge", status: :snoozed, error: @snoozed)
      assert %{status: :snoozed, reason: "busy", at: at} = Trace.parked(parked_run(), snoozed)
      assert at == t(5_000)
    end

    test "parked/2 is nil when something else explains the wait" do
      assert Trace.parked(parked_run(), nil) == nil
      assert Trace.parked(parked_run("other"), failed()) == nil
      assert Trace.parked(parked_run(), step("charge", status: :completed)) == nil
      # Due now: an operator's retry, or a step's queue.
      assert Trace.parked(%{parked_run() | scheduled_at: nil}, failed()) == nil
      assert Trace.parked(%{parked_run() | status: :running}, failed()) == nil
    end

    test "the step reads Retrying and its gap runs on to now" do
      %{rows: [row]} = Trace.build(parked_run(), [failed(from: 0, to: 100)], [], t(3_000))

      assert row.status == :retrying
      assert [%{kind: :fail}, %{kind: :backoff, width: width}] = row.segments
      assert width > 90
    end

    test "a compensating run's failed step isn't going to run again" do
      run = run(status: :compensating, current_step: "charge")
      %{rows: [row]} = Trace.build(run, [failed(from: 0, to: 100)], [], t(3_000))

      assert row.status == :failed
      assert [%{kind: :fail}] = row.segments
    end

    test "a child run's step with the same name isn't the parked one" do
      child = failed(from: 0, to: 100) |> Map.put(:workflow_id, "child-1")
      %{rows: [row]} = Trace.build(parked_run(), [child], ["child-1"], t(3_000))
      assert row.status == :failed
    end

    test "time_left is what's left, and nil once it's due" do
      assert Trace.time_left(t(12_400), t(0)) == "12s"
      assert Trace.time_left(t(90_000), t(0)) == "1m 30s"
      assert Trace.time_left(t(0), t(0)) == nil
      assert Trace.time_left(t(0), t(5)) == nil
    end

    test "attempts_used leaves out a budget it doesn't know" do
      assert Trace.attempts_used(%{attempt: 2, max: 5}) == "2 of 5"
      assert Trace.attempts_used(%{attempt: 2, max: nil}) == "2"
    end
  end

  test "one row per step in start order, one bar per attempt, backoff between failures" do
    steps = [
      step("reserve", from: 0, to: 100),
      step("ship", attempt: 1, status: :failed, from: 200, to: 300),
      step("ship", attempt: 2, status: :completed, from: 500, to: 600)
    ]

    %{rows: [reserve, ship], span_ms: 600} = Trace.build(run(), steps, [], t(600))

    assert reserve.name == "reserve" and reserve.attempts == 1
    assert ship.attempts == 2 and ship.status == :completed and ship.duration_ms == 200

    assert Enum.map(ship.segments, & &1.kind) == [:fail, :backoff, :ok]
    [fail, backoff, ok] = ship.segments
    assert {fail.left, fail.width} == {33.33, 16.67}
    assert {backoff.left, backoff.width} == {50.0, 33.33}
    assert ok.left == 83.33

    # Each bar's tooltip: what it is, and when it ran from the run's start.
    assert fail.title == "Attempt 1 · failed" and fail.tip == "+200ms → +300ms · 100ms"
    assert backoff.title == "Backoff" and backoff.tip =~ "+300ms → +500ms · 200ms"
  end

  test "a suspension draws a wait gap, and keeps running to now while the run waits" do
    steps = [
      step("ask", status: :waiting, from: 0, to: 5, completed_at: nil),
      step("ask", attempt: 1, from: 1_000, to: 1_100)
    ]

    %{rows: [ask]} = Trace.build(run(), steps, [], t(1_100))
    assert Enum.map(ask.segments, & &1.kind) == [:wait, :ok]
    assert ask.attempts == 1

    live_steps = [step("ask", status: :waiting, from: 0, to: 5, completed_at: nil)]
    %{rows: [live]} = Trace.build(run(status: :waiting), live_steps, [], t(2_000))
    assert [%{kind: :wait, width: width}] = live.segments
    assert width > 99
  end

  test "compensations sort after the steps they undo, and child-run steps indent" do
    steps = [
      step("release", is_compensation: true, from: 900, to: 950),
      step("book", from: 0, to: 100),
      step("charge", workflow_id: "child-1", from: 100, to: 200),
      step("unrelated", workflow_id: "someone-else", from: 0, to: 1)
    ]

    %{rows: rows} = Trace.build(run(), steps, ["child-1"], t(950))

    assert Enum.map(rows, &{&1.name, &1.depth, &1.compensation?}) ==
             [{"book", 0, false}, {"charge", 1, false}, {"release", 0, true}]
  end

  test "parallel and branch qualifiers are stripped from names" do
    assert Trace.display_name("parallel_ab12__left") == "left"
    assert Trace.display_name("branch_x__high__notify") == "notify"
    assert Trace.display_name("plain") == "plain"
    assert Trace.display_name("parallel_93383175") == "parallel"

    assert Trace.returned(%{"__output__" => %{"a" => 1}, "__result__" => %{"a" => 1}}) == %{
             "a" => 1
           }

    assert Trace.returned(%{"a" => 1}) == %{"a" => 1}
    assert Trace.display_name("branch_12") == "branch"
  end

  test "error_parts splits app frames from library frames" do
    error = %{
      "type" => "RuntimeError",
      "message" => "carrier API returned 503",
      "stacktrace" => """
          (my_app 0.1.0) lib/my_app/carrier.ex:48: MyApp.Carrier.ship/2
          (durable 1.0.0) lib/durable/executor/step_runner.ex:104: Durable.Executor.StepRunner.execute/3
          (elixir 1.20.0) lib/task/supervised.ex:101: Task.Supervised.invoke_mfa/2
      """
    }

    %{type: "RuntimeError", message: "carrier API returned 503", frames: frames} =
      Trace.error_parts(error)

    assert Enum.map(frames, & &1.app?) == [true, false, false]

    assert %{app: "my_app", where: "lib/my_app/carrier.ex:48", function: "MyApp.Carrier.ship/2"} =
             hd(frames)
  end

  test "frames in DSL-generated functions read the way the workflow was written" do
    stack = """
    (my_app 0.1.0) lib/my_app/orders.ex:12: MyApp.Orders.__step_body_parallel_7__charge__/1
    (my_app 0.1.0) lib/my_app/orders.ex:30: anonymous fn/1 in MyApp.Orders.__compensate_body_refund__/1
    (my_app 0.1.0) lib/my_app/orders.ex:40: MyApp.Orders.__branch_condition_3__/1
    (my_app 0.1.0) lib/my_app/orders.ex:50: MyApp.Orders.__step_body_charge__in_91234__/1
    """

    %{frames: frames} = Trace.error_parts(%{"message" => "x", "stacktrace" => stack})

    assert Enum.map(frames, & &1.function) == [
             "Orders · step :charge",
             "anonymous fn/1 in Orders · compensation :refund",
             "Orders · branch on:",
             "Orders · step :charge"
           ]
  end

  test "a stack line that isn't a frame is kept whole" do
    %{frames: [frame]} = Trace.error_parts(%{"message" => "x", "stacktrace" => "nofile"})
    assert %{text: "nofile", function: "nofile", where: nil} = frame
  end

  test "error_parts handles a step that returned {:error, map}" do
    returned = %{"reason" => "Carrier rejected package", "carrier" => "DemoExpress"}

    assert %{
             type: nil,
             message: "Carrier rejected package",
             details: %{"carrier" => "DemoExpress"}
           } =
             Trace.error_parts(returned)

    assert %{message: ~s({"code":42})} = Trace.error_parts(%{"code" => 42})
  end

  test "format_ms reads at a glance" do
    assert Enum.map([0, 850, 1_234, 12_500, 185_000, 7_380_000], &Trace.format_ms/1) ==
             ["0ms", "850ms", "1.23s", "12.5s", "3m 05s", "2h 3m"]
  end

  property "bars stay inside the window and each row's bars follow its attempts" do
    check all(
            attempts <-
              list_of(
                tuple(
                  {member_of([:completed, :failed, :waiting]), integer(0..5_000),
                   integer(0..2_000)}
                ),
                min_length: 1,
                max_length: 6
              ),
            max_runs: 200
          ) do
      {steps, _} =
        Enum.map_reduce(attempts, 0, fn {status, gap, length}, at ->
          from = at + gap
          s = step("s", status: status, attempt: 1, from: from, to: from + length)
          {%{s | id: "s-#{from}-#{status}"}, from + length}
        end)

      %{rows: [row]} = Trace.build(run(), steps, [], List.last(steps).completed_at)

      for seg <- row.segments do
        assert seg.left >= 0 and seg.width >= 0
        assert seg.left + seg.width <= 100.01
      end

      bars = Enum.count(row.segments, &(&1.kind in [:ok, :fail]))
      assert bars == Enum.count(steps, &(&1.status != :waiting))
      assert row.attempts == bars
    end
  end
end
