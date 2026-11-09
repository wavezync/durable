defmodule Durable.Fuzz.ScriptedTest do
  @moduledoc """
  Generated run scripts against live workers, checked against a model of what
  each script must do.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  alias Durable.FuzzWorkflows.Scripted
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup}
  alias Durable.Wait.SleepWaker

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "40"))
  @steps [:s1, :s2, :s3, :s4, :s5, :s6]
  @compensated [:s1, :s2, :s4, :s6]
  @max_attempts 3
  @limits %{default: 8, q_a: 2, q_b: 3}
  @terminal [:completed, :failed, :cancelled, :compensated, :compensation_failed]

  # ===========================================================================
  # Generating
  # ===========================================================================

  defp action do
    one_of([
      constant(:ok),
      constant(:ok),
      constant(:fail),
      constant(:cancel),
      constant(:sleep),
      constant(:event),
      constant(:input),
      constant(:any),
      constant(:all),
      tuple({member_of([:error, :raise, :throw, :exit, :bad]), integer(1..4)}),
      tuple({constant(:snooze), integer(1..3)}),
      tuple({constant(:put), one_of([integer(), string(:ascii, max_length: 4)])})
    ])
  end

  defp script do
    gen all(
          actions <- fixed_list(Enum.map(@steps, fn _ -> action() end)),
          undos <-
            fixed_list(Enum.map(@compensated, fn _ -> member_of([:ok, :ok, :error, :raise]) end)),
          early <- boolean()
        ) do
      %{
        steps: @steps |> Enum.zip(actions) |> Map.new(),
        undo: @compensated |> Enum.zip(undos) |> Map.new(),
        early: early
      }
    end
  end

  # ===========================================================================
  # The model
  # ===========================================================================

  defp enters(:ok), do: 1
  defp enters(:fail), do: 1
  defp enters(:cancel), do: 1
  defp enters({:put, _}), do: 1
  defp enters({:snooze, times}), do: times + 1
  # A step that returns something invalid is a bug in the step: no retries.
  defp enters({:bad, _times}), do: 1
  defp enters({_misbehave, times}), do: min(times + 1, @max_attempts)
  defp enters(_wait), do: 2

  defp outcome(:fail), do: :failed
  defp outcome(:cancel), do: :cancelled
  defp outcome({:bad, _times}), do: :failed

  defp outcome({how, times})
       when how in [:error, :raise, :throw, :exit, :bad] and times >= @max_attempts, do: :failed

  defp outcome(_action), do: :done

  defp model(script) do
    {done, reached, stop} =
      Enum.reduce_while(@steps, {[], [], nil}, fn step, {done, reached, nil} ->
        case outcome(script.steps[step]) do
          :done -> {:cont, {[step | done], [step | reached], nil}}
          stop -> {:halt, {done, [step | reached], stop}}
        end
      end)

    undone = if stop == :failed, do: Enum.filter(done, &(&1 in @compensated)), else: []
    failed_undo? = Enum.any?(undone, &(script.undo[&1] != :ok))

    status =
      cond do
        stop == nil -> :completed
        stop == :cancelled -> :cancelled
        undone == [] -> :failed
        failed_undo? -> :compensation_failed
        true -> :compensated
      end

    %{status: status, done: Enum.reverse(done), reached: Enum.reverse(reached), undone: undone}
  end

  # ===========================================================================
  # Driving
  # ===========================================================================

  setup do
    start_durable!(@limits)
    :ok
  end

  defp start_run(script) do
    case_id = System.unique_integer([:positive])
    :ok = Probe.put(case_id, script)
    {:ok, id} = Durable.start(Scripted, %{"case" => case_id})

    # Sent before the run gets there. A run gets one per name.
    if script.early do
      for step <- @steps, script.steps[step] == :event do
        Durable.send_event(id, "e_#{step}", %{}, buffer: true)
      end
    end

    %{id: id, case_id: case_id, script: script}
  end

  defp answer_waits(id) do
    pending = fn schema ->
      from(p in schema, where: p.workflow_id == ^id and p.status == :pending)
    end

    for event <- IntegrationRepo.all(pending.(PendingEvent)),
        not String.starts_with?(event.event_name, "never_") do
      Durable.send_event(id, event.event_name, %{"got" => 1})
    end

    for input <- IntegrationRepo.all(pending.(PendingInput)) do
      Durable.provide_input(id, input.input_name, %{"got" => 1})
    end
  end

  defp drive(runs, tries \\ 400)

  defp drive(runs, 0) do
    stuck = for %{id: id, script: script} <- runs, do: {describe(get(id)), script}
    flunk("never finished: #{inspect(stuck, pretty: true)}")
  end

  defp drive(runs, tries) do
    open = Enum.reject(runs, &(get(&1.id).status in @terminal))

    if open != [] do
      for %{id: id} <- open, get(id).status == :waiting, do: answer_waits(id)
      SleepWaker.wake_now(Durable)
      Process.sleep(25)
      drive(open, tries - 1)
    end
  end

  defp describe(run),
    do: Map.take(run, [:status, :current_step, :queue, :locked_by, :scheduled_at, :error])

  # ===========================================================================
  # Checking
  # ===========================================================================

  defp hits(case_id, step, what), do: Probe.hits({case_id, step, what})

  defp check_run(%{id: id, case_id: case_id, script: script}) do
    expected = model(script)
    run = get(id)
    label = "#{inspect(script)}\n#{inspect(describe(run))}"

    assert run.status == expected.status, "status, expected #{expected.status}: #{label}"
    assert run.completed_at != nil, "no completed_at: #{label}"
    assert run.locked_by == nil, "left locked: #{label}"

    for step <- @steps do
      want_done = if step in expected.done, do: 1, else: 0
      assert hits(case_id, step, :done) == want_done, "#{step} done count: #{label}"

      want_enters = if step in expected.reached, do: enters(script.steps[step]), else: 0

      assert hits(case_id, step, :enter) == want_enters,
             "#{step} entered #{hits(case_id, step, :enter)}, wanted #{want_enters}: #{label}"
    end

    undone = for {{^case_id, :undo, step}, _queue, _node} <- Probe.log(), do: step
    assert undone == expected.undone, "undo order #{inspect(undone)}: #{label}"

    assert Probe.peak({:run, case_id}) == 1, "steps overlapped: #{label}"
    check_rows(id, expected, label)
    check_context(run, script, expected, label)
  end

  defp check_rows(id, expected, label) do
    open = fn schema ->
      IntegrationRepo.aggregate(
        from(p in schema, where: p.workflow_id == ^id and p.status == :pending),
        :count
      )
    end

    # A run that ended mid-wait has nothing left to wait for.
    if expected.status == :completed do
      for schema <- [PendingEvent, PendingInput, WaitGroup] do
        assert open.(schema) == 0, "#{inspect(schema)} left open: #{label}"
      end
    end

    rows = IntegrationRepo.all(from(s in StepExecution, where: s.workflow_id == ^id))
    assert Enum.all?(rows, &(&1.status != :running)), "a step row left running: #{label}"

    for step <- expected.done do
      completed =
        Enum.count(
          rows,
          &(&1.step_name == to_string(step) and &1.status == :completed and not &1.is_compensation)
        )

      assert completed == 1, "#{step} has #{completed} completed rows: #{label}"
    end
  end

  defp check_context(%{status: :completed} = run, script, _expected, label) do
    written =
      for step <- @steps, match?({:put, _}, script.steps[step]), into: %{} do
        {:put, value} = script.steps[step]
        {"put_#{step}", value}
      end

    for {key, value} <- written do
      assert run.context[key] == value, "context #{key}: #{inspect(run.context)} #{label}"
    end
  end

  defp check_context(_run, _script, _expected, _label), do: :ok

  property "every run does exactly what its script says" do
    check all(
            scripts <- list_of(script(), length: 10),
            max_runs: @runs,
            max_shrinking_steps: 25
          ) do
      runs = Enum.map(scripts, &start_run/1)
      drive(runs)
      Enum.each(runs, &check_run/1)
    end

    for {queue, limit} <- @limits, queue != :default do
      assert Probe.peak({:queue, queue}) <= limit, "#{queue} ran over its limit"
    end
  end
end
