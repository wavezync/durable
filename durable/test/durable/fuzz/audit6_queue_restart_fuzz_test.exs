defmodule Durable.Fuzz.Audit6QueueRestartTest do
  @moduledoc """
  Audit 6: the node stops cleanly and starts again at random moments while
  generated runs execute, with a grace period that some steps outlast. A step
  handed back runs again from the top and uses no attempt, so every run still
  ends as its script says, each step it finishes is recorded once, and no
  two steps of a run ever run at once.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  import Durable.FuzzScripts

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "30"))
  @limits %{default: 8, q_a: 2, q_b: 3}
  @batch 8

  setup do
    boot()
    :ok
  end

  defp boot,
    do: start_durable!(@limits, heartbeat_interval: 100, shutdown_grace_period: grace())

  defp grace, do: Enum.random([0, 20, 150])

  defp op do
    frequency([
      {2, constant(:restart)},
      {3, tuple({constant(:wait), integer(0..60)})}
    ])
  end

  defp apply_op(:restart) do
    stop_supervised!(Durable)
    boot()
  end

  defp apply_op({:wait, ms}), do: Process.sleep(ms)

  # What a run handed back must still do: end as its script says, with each
  # step it finished recorded once, never two of its steps at once.
  defp check_handed_back(%{id: id, case_id: case_id, script: script} = run) do
    %{status: expected} = model(script, :rollback)
    row = get(id)
    label = "#{inspect(script)}\n#{inspect(describe(row))}"

    assert row.status == expected, "status, expected #{expected}: #{label}"
    assert let_go?(id), "left locked: #{label}"
    assert Probe.peak({:run, case_id}) <= 1, "steps overlapped: #{label}"

    rows = IntegrationRepo.all(from(s in StepExecution, where: s.workflow_id == ^id))
    assert Enum.all?(rows, &(&1.status != :running)), "a step row left running: #{label}"

    completed =
      for %{status: :completed, is_compensation: false} = r <- rows, do: r.step_name

    assert completed == Enum.uniq(completed), "a step completed twice: #{label}"
    run
  end

  property "a node restarting cleanly mid-run never changes how a run ends" do
    check all(
            scripts <- list_of(script(), length: @batch),
            ops <- list_of(op(), min_length: 2, max_length: 8),
            max_runs: @runs,
            max_shrinking_steps: 10
          ) do
      runs = Enum.map(scripts, &start_run/1)
      Enum.each(ops, &apply_op/1)
      drive(runs)

      if :restart in ops,
        do: Enum.each(runs, &check_handed_back/1),
        else: Enum.each(runs, &check_run/1)
    end

    # The property means nothing if no restart ever cut a step off: its
    # attempt is closed `node_stopped` as its run is handed back. How many
    # restarts find a step running is timing: one right after another finds
    # nothing claimed yet, more often on a slower machine.
    cut_off =
      IntegrationRepo.aggregate(
        from(s in StepExecution, where: fragment("?->>'type' = 'node_stopped'", s.error)),
        :count
      )

    assert cut_off > 0, "no restart cut a step off"
  end
end
