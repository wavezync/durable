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
    """

    %{frames: frames} = Trace.error_parts(%{"message" => "x", "stacktrace" => stack})

    assert Enum.map(frames, & &1.function) == [
             "Orders · step :charge",
             "anonymous fn/1 in Orders · compensation :refund",
             "Orders · branch on:"
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
