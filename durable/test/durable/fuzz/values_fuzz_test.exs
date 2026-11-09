defmodule Durable.Fuzz.ValuesTest do
  @moduledoc """
  Whatever a workflow hands Durable, the run ends and the engine carries on.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  import Durable.FuzzTerms

  alias Durable.Executor
  alias Durable.Executor.StepRunner
  alias Durable.FuzzWorkflows.{Asks, Hostile, HostileUndo, Waits, WaitsAny}
  alias Durable.Wait.TimeoutWorker

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "60"))
  @terminal [:completed, :failed, :cancelled, :compensated, :compensation_failed]

  @step_surfaces [
    :ok_value,
    :ok_raw,
    :return,
    :error,
    :fail,
    :cancel,
    :goto,
    :throw,
    :exit,
    :raise,
    :put_context,
    :put_context_key,
    :snooze,
    :log,
    :timeout_value,
    :input_options
  ]

  @undo_surfaces [:undo_return, :undo_error, :undo_fail, :undo_raise, :undo_throw]

  defp storable!(value) do
    assert {:ok, _} = IntegrationRepo.query("SELECT $1::jsonb", [%{"v" => value}])
  end

  defp await_end(id, label) do
    Enum.reduce_while(1..200, nil, fn _, _ ->
      run = get(id)

      if run.status in @terminal do
        {:halt, run}
      else
        TimeoutWorker.check_timeouts(Durable)
        Process.sleep(25)
        {:cont, run}
      end
    end)
    |> tap(fn run ->
      assert run.status in @terminal,
             "#{inspect(label)} is stuck: #{inspect(Map.take(run, [:status, :current_step, :locked_by, :queue, :scheduled_at, :error]))}, pids #{inspect(pids())}"
    end)
  end

  property "anything sanitized is JSON that Postgres will store" do
    check all(term <- nasty_term(), max_runs: @runs * 20) do
      safe = Executor.sanitize_for_json(term)
      assert {:ok, _} = Jason.encode(safe)
      storable!(safe)
      storable!(Executor.storable_error(term))
      storable!(StepRunner.serialize_output(term))
    end
  end

  describe "with live workers" do
    setup do
      start_durable!(%{default: 10})
      :ok
    end

    defp pids do
      for name <- [
            Durable.Queue.Manager,
            Durable.Queue.Poller.Default,
            TimeoutWorker.worker_name(Durable)
          ],
          do: Process.whereis(name)
    end

    defp start_case(workflow, surface, term) do
      case_id = System.unique_integer([:positive])
      :ok = Probe.put(case_id, {surface, term})
      {:ok, id} = Durable.start(workflow, %{"case" => case_id})
      {id, {surface, term}}
    end

    property "whatever a step does with a value, its run ends" do
      before = pids()

      check all(
              cases <- list_of({member_of(@step_surfaces), nasty_term()}, length: 8),
              max_runs: @runs,
              max_shrinking_steps: 30
            ) do
        started = for {surface, term} <- cases, do: start_case(Hostile, surface, term)
        for {id, label} <- started, do: await_end(id, label)
      end

      assert pids() == before
    end

    for {name, workflow, answer} <- [
          {"an event", Waits, quote(do: &Durable.send_event(&1, "go", &2))},
          {"a buffered event", Waits, quote(do: &Durable.send_event(&1, "go", &2, buffer: true))},
          {"an input", Asks, quote(do: &Durable.provide_input(&1, "approve", &2))},
          {"wait_for_any's event", WaitsAny, quote(do: &Durable.send_event(&1, "yes", &2))}
        ] do
      property "whatever #{name} carries, the run takes it and finishes" do
        answer = unquote(answer)

        check all(payload <- nasty_term(), max_runs: @runs, max_shrinking_steps: 30) do
          {:ok, id} = Durable.start(unquote(workflow), %{})
          assert_eventually(fn -> get(id).status == :waiting end, 5_000, 5)

          assert answer.(id, payload) == :ok
          assert await_end(id, payload).status == :completed
        end
      end
    end

    property "whatever a compensation returns, its run ends" do
      before = pids()

      check all(
              cases <- list_of({member_of(@undo_surfaces), nasty_term()}, length: 8),
              max_runs: @runs,
              max_shrinking_steps: 30
            ) do
        started = for {surface, term} <- cases, do: start_case(HostileUndo, surface, term)

        for {id, label} <- started do
          assert await_end(id, label).status in [:compensated, :compensation_failed]
        end
      end

      assert pids() == before
    end
  end
end
