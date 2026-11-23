defmodule Audit6BlocksClaim do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The assessor is booked while the policy is looked up. Closing the claim
  # stands the assessor down if one was booked, as the parallel guide says to.
  # A failure halts: an operator decides whether to undo.
  workflow "audit6_claim" do
    step :open_claim, [compensate: :close_claim], fn claim -> {:ok, claim} end

    parallel :checks do
      step :policy, fn _claim ->
        Process.sleep(50)
        {:error, "no such policy"}
      end

      step :assessor, fn claim ->
        Process.sleep(300)
        Probe.note(:assessor_booked)
        {:ok, claim}
      end
    end

    compensate :close_claim, fn claim ->
      Probe.note({:closed_with_assessor_booked, Probe.hits(:assessor_booked)})
      {:ok, claim}
    end
  end
end

defmodule Durable.Integration.Audit6BlocksTest do
  @moduledoc """
  Audit 6: parallel blocks, children and rollbacks with live pollers, raced
  against operators.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  # A lane that fails stops the others at their workers' next heartbeat, and
  # until then a step of theirs can still finish. `Durable.rollback/2` asked
  # straight after the failure undid the run at once, before the stopped lane's
  # step landed: the compensation looked for an assessor not yet booked.
  test "a rollback asked for as a block fails waits for its stopped lanes" do
    start_durable!(%{default: 4}, heartbeat_interval: 1_000)

    {:ok, id} = Durable.start(Audit6BlocksClaim, %{})
    await_status(id, :failed)

    assert {:ok, ^id} = Durable.rollback(id)
    await_status(id, :compensated, 5_000)
    assert_eventually(fn -> Probe.hits(:assessor_booked) == 1 end)
    Process.sleep(200)

    assert Probe.hits({:closed_with_assessor_booked, 1}) == 1,
           "undone before the stopped lane's step finished: #{inspect(Probe.log())}"
  end
end
