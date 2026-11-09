defmodule Durable.TelemetryTest do
  @moduledoc """
  The telemetry contract in `Durable.Telemetry`: run, step and compensation
  spans, retry events, `metrics/0` and the default logger.
  """
  use Durable.DataCase, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog
  import Durable.DataCase, only: [create_and_execute_workflow: 2, get_step_executions: 1]

  alias Durable.Config
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  defmodule Steps do
    @moduledoc false
    use Durable

    def act(i, data) do
      if knob(data, :cancel_at) == i, do: Durable.cancel(Durable.Context.workflow_id())
      if knob(data, :fail_at) == i, do: raise("boom at #{i}")
      {:ok, data}
    end

    defp knob(data, key), do: Map.get(data, key) || Map.get(data, Atom.to_string(key))

    workflow "telemetry_steps" do
      step(:a, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
        __MODULE__.act(1, data)
      end)

      step(:b, fn data -> __MODULE__.act(2, data) end)
      step(:c, fn data -> __MODULE__.act(3, data) end)
    end
  end

  defmodule RollsBack do
    @moduledoc false
    use Durable

    workflow "rolls_back" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
      step(:fail, fn _data -> raise "nope" end)
      compensate(:unbook, fn data -> {:ok, data} end)
    end
  end

  def forward(event, measurements, meta, pid),
    do: send(pid, {:telemetry, event, measurements, meta})

  setup do
    handler = "telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(handler, Durable.Telemetry.events(), &__MODULE__.forward/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp drain(acc \\ []) do
    receive do
      {:telemetry, event, measurements, meta} -> drain([{event, measurements, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp of(events, name), do: for({^name, m, meta} <- events, do: {m, meta})

  test "a completed run: one workflow span around one step span per step" do
    {:ok, run} = create_and_execute_workflow(Steps, %{})
    events = drain()

    assert [{%{system_time: _}, %{workflow: "telemetry_steps", resumed: false}}] =
             of(events, [:durable, :workflow, :start])

    assert [{%{duration: duration}, %{status: :completed, workflow_id: id}}] =
             of(events, [:durable, :workflow, :stop])

    assert id == run.id and duration > 0

    steps = for {_, meta} <- of(events, [:durable, :step, :stop]), do: {meta.step, meta.result}
    assert steps == [a: :ok, b: :ok, c: :ok]
  end

  test "a failing step: an error stop per attempt, a retry event between, a failed run" do
    # The retry parks the run, so each attempt is its own segment.
    {:ok, _run} = create_and_execute_workflow(Steps, %{"fail_at" => 1})
    events = drain()

    stops = for {_, meta} <- of(events, [:durable, :step, :stop]), do: {meta.attempt, meta.result}
    assert stops == [{1, :error}, {2, :error}]

    assert [{%{backoff_ms: backoff}, %{attempt: 1, error: %{type: "RuntimeError"}}}] =
             of(events, [:durable, :step, :retry])

    assert backoff >= 0

    assert [{_, %{status: :waiting}}, {_, %{status: :failed}}] =
             of(events, [:durable, :workflow, :stop])
  end

  test "a run cancelled mid-segment stops as :superseded" do
    {:ok, _run} = create_and_execute_workflow(Steps, %{"cancel_at" => 2})

    assert [{_, %{status: :superseded}}] = of(drain(), [:durable, :workflow, :stop])
  end

  test "a compensated run: a compensation span, and the run reports :compensated" do
    {:ok, run} = create_and_execute_workflow(RollsBack, %{})
    assert run.status == :compensated
    events = drain()

    assert [{%{duration: _}, %{compensation: :unbook, result: :ok}}] =
             of(events, [:durable, :compensation, :stop])

    assert [{_, %{status: :compensated}}] = of(events, [:durable, :workflow, :stop])
  end

  test "run and step events carry the run's key and tags" do
    {:ok, id} = Durable.start(Steps, %{}, key: "order:7", tags: ["account:1"])
    Durable.DataCase.execute_while_pending(id)
    events = drain()

    assert [{_, %{key: "order:7", tags: ["account:1"]}} | _] =
             of(events, [:durable, :workflow, :start])

    assert [{_, %{key: "order:7", tags: ["account:1"]}} | _] =
             of(events, [:durable, :step, :stop])
  end

  describe "Logger metadata" do
    defmodule Logged do
      @moduledoc false
      use Durable

      def report(data, label) do
        send(Durable.DataCase.bin_to_pid(data["pid"]), {:meta, label, Logger.metadata()})
      end

      workflow "logged",
        log_metadata: fn data ->
          if data["bad_metadata"], do: raise("no metadata for you")
          [account_id: data["account_id"]]
        end do
        step(:a, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn data ->
          __MODULE__.report(data, {:a, Durable.Context.attempt()})
          if Durable.Context.attempt() == 1, do: {:error, "again"}, else: {:ok, data}
        end)

        step(:b, [timeout: 5_000], fn data ->
          __MODULE__.report(data, :b)
          {:ok, data}
        end)

        step(:boom, [compensate: :undo], fn data -> {:ok, data} end)
        step(:fails, fn _data -> {:fail, "stop"} end)

        compensate(:undo, fn data ->
          __MODULE__.report(data, :undo)
          {:ok, data}
        end)
      end
    end

    defp input(extra \\ %{}),
      do: Map.merge(%{"pid" => Durable.DataCase.pid_to_bin(), "account_id" => 7}, extra)

    test "is set before every attempt of every step, with the workflow's own fields" do
      {:ok, id} = Durable.start(Logged, input())
      Durable.DataCase.execute_while_pending(id)

      assert_received {:meta, {:a, 1}, first}
      assert first[:workflow] == "logged"
      assert first[:workflow_id] == id
      assert first[:step] == :a
      assert first[:attempt] == 1
      assert first[:account_id] == 7

      assert_received {:meta, {:a, 2}, second}
      assert second[:attempt] == 2

      # A step with a `timeout:` runs in its own process.
      assert_received {:meta, :b, in_task}
      assert in_task[:step] == :b
      assert in_task[:account_id] == 7

      assert_received {:meta, :undo, undo}
      assert undo[:workflow_id] == id
      assert undo[:step] == :undo
    end

    test "a log_metadata function that raises costs the step nothing" do
      capture_log(fn ->
        {:ok, id} = Durable.start(Logged, input(%{"bad_metadata" => true}))
        run = Durable.DataCase.execute_while_pending(id)
        assert run.status == :compensated
      end)

      assert_received {:meta, {:a, 1}, meta}
      assert meta[:step] == :a
      refute Keyword.has_key?(meta, :account_id)
    end

    test "an inline run leaves the caller's metadata as it found it" do
      :logger.update_process_metadata(%{mine: true})
      {:ok, id} = Durable.start(Logged, input())
      Durable.DataCase.execute_while_pending(id)

      assert Logger.metadata() == [mine: true]
    after
      Logger.reset_metadata()
    end
  end

  test "metrics/0 only references events Durable emits" do
    for metric <- Durable.Telemetry.metrics() do
      assert metric.event_name in Durable.Telemetry.events(),
             "#{inspect(metric.name)} listens to an event Durable never emits"
    end
  end

  test "counters count every event, whatever its measurements" do
    # LiveDashboard drops an event whose named measurement is missing.
    for %Telemetry.Metrics.Counter{} = metric <- Durable.Telemetry.metrics() do
      assert metric.measurement.(%{duration: 1}) == 1, inspect(metric.name)
    end
  end

  test "attach_default_logger/1 logs finished runs and failed steps" do
    :ok = Durable.Telemetry.attach_default_logger()
    on_exit(fn -> :telemetry.detach("durable-default-logger") end)

    log =
      capture_log(fn ->
        {:ok, _} = create_and_execute_workflow(Steps, %{})
        {:ok, _} = create_and_execute_workflow(Steps, %{"fail_at" => 2})
      end)

    assert log =~ ~r/\[Durable\] telemetry_steps \S+ completed in \d+ms/
    assert log =~ ~r/step b failed \(attempt 1\/1, \d+ms\): RuntimeError: boom at 2/
    assert log =~ ~r/\[Durable\] telemetry_steps \S+ failed in \d+ms/

    # Durable's own lines don't end up in the step's captured logs.
    step_logs =
      Config.get(Durable).repo.all(from(s in StepExecution, select: s.logs))
      |> List.flatten()
      |> Enum.map(& &1["message"])

    refute Enum.any?(step_logs, &String.starts_with?(&1, "[Durable]"))
  end

  property "spans always close, and what telemetry reports matches what was persisted" do
    check all(
            fail_at <- one_of([constant(nil), integer(1..3)]),
            cancel_at <- one_of([constant(nil), integer(1..3)]),
            max_runs: 40
          ) do
      drain()

      {:ok, run} =
        create_and_execute_workflow(Steps, %{"fail_at" => fail_at, "cancel_at" => cancel_at})

      events = drain()

      # Every span that starts ends exactly once.
      ends = [:stop, :exception]

      for {[:durable, kind, :start], _, %{telemetry_span_context: ref}} <- events do
        starts =
          for {[:durable, ^kind, :start], _, %{telemetry_span_context: ^ref}} <- events, do: ref

        closes =
          for {[:durable, ^kind, phase], _, %{telemetry_span_context: ^ref}} <- events,
              phase in ends,
              do: phase

        # A run's segments follow one another, so they share the run's id.
        assert length(closes) == length(starts)
      end

      # The run's last reported status is the persisted one (a cancel shows up
      # as the segment being superseded); a parked retry ends a segment early.
      segments = of(events, [:durable, :workflow, :stop])
      {_, %{status: reported}} = List.last(segments)
      assert Enum.all?(Enum.drop(segments, -1), &match?({_, %{status: :waiting}}, &1))
      persisted = Config.get(Durable).repo.get!(WorkflowExecution, run.id).status
      assert reported == if(persisted == :cancelled, do: :superseded, else: persisted)

      # One step span per persisted attempt.
      assert length(of(events, [:durable, :step, :start])) == length(get_step_executions(run.id))
    end
  end
end
