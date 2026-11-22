defmodule Durable.Fuzz.ScriptedTest do
  @moduledoc """
  Generated run scripts against live workers, checked against a model of what
  each script must do.
  """
  use Durable.IntegrationCase, tag: :fuzz
  use ExUnitProperties

  import Durable.FuzzScripts

  @moduletag :capture_log
  @moduletag timeout: :infinity

  @runs String.to_integer(System.get_env("FUZZ_RUNS", "40"))
  @limits %{default: 8, q_a: 2, q_b: 3}

  setup do
    start_durable!(@limits)
    :ok
  end

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

  property "a failed run is left as it failed, and a rollback by hand undoes what on_failure: :rollback would" do
    check all(
            scripts <- list_of(script(), length: 10),
            max_runs: @runs,
            max_shrinking_steps: 25
          ) do
      runs = Enum.map(scripts, &start_run(&1, workflow: "fuzz_scripted_halt"))
      drive(runs)
      Enum.each(runs, &check_run(&1, :halt))

      failed = Enum.filter(runs, &(get(&1.id).status == :failed))
      for %{id: id} <- failed, do: assert({:ok, ^id} = Durable.rollback(id))
      await_rolled_back(failed)

      # No step ran again, and the undos are the ones a rollback at once runs.
      Enum.each(runs, &check_run/1)
      Probe.note({:rolled_back, length(failed)})
    end

    rolled_back = for {{:rolled_back, n}, _queue, _node} <- Probe.log(), do: n
    assert Enum.sum(rolled_back) > 0, "no generated run failed, so no rollback was tried"
  end

  # A run with nothing to undo goes back to :failed, so its status alone
  # doesn't say the worker has been: the marker leaving its context does.
  defp await_rolled_back(runs) do
    assert_eventually(fn ->
      Enum.all?(runs, fn %{id: id} ->
        run = get(id)
        run.status in terminal() and not is_map_key(run.engine_state, "__rollback__")
      end)
    end)
  end
end
