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
end
