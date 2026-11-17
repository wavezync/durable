defmodule Durable.Integration.OnFailureTest do
  @moduledoc "Rolling a failed run back by hand, with live pollers and racing callers."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.IntegrationProbe, as: Probe

  defmodule Booking do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "of_booking" do
      step(:hold_seat, [compensate: :release_seat], fn trip -> {:ok, trip} end)

      step(:charge_card, fn _trip ->
        Probe.note({:charge, Durable.Context.workflow_id()})
        {:error, "payments timed out"}
      end)

      compensate(:release_seat, fn trip ->
        Probe.note({:release, Durable.Context.workflow_id()})
        {:ok, trip}
      end)
    end
  end

  test "a failed run is left alone until Durable.rollback/1, then a worker undoes it" do
    start_durable!(%{default: 2})

    {:ok, id} = Durable.start(Booking, %{})
    await_status(id, :failed)
    assert Probe.hits({:release, id}) == 0

    assert {:ok, ^id} = Durable.rollback(id)
    await_status(id, :compensated)

    assert Probe.hits({:release, id}) == 1
    assert Probe.hits({:charge, id}) == 1
    assert get(id).error["message"] == "payments timed out"
  end

  test "a retry and a rollback of one run don't both win" do
    Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)
    config = Durable.Config.get(Durable)

    ids =
      for _ <- 1..30 do
        {:ok, id} = Durable.start(Booking, %{})
        Durable.Executor.execute_workflow(id, config)
        assert get(id).status == :failed
        id
      end

    for id <- ids do
      results =
        [fn -> Durable.retry(id) end, fn -> Durable.rollback(id) end]
        |> Enum.map(&Task.async/1)
        |> Task.await_many()

      assert Enum.sort(results) == [{:error, :not_failed}, {:ok, id}]
      Durable.Executor.execute_workflow(id, config)

      case results do
        # The retry won: the charge ran again and nothing was undone.
        [{:ok, _}, _] ->
          assert get(id).status == :failed
          assert {Probe.hits({:charge, id}), Probe.hits({:release, id})} == {2, 0}

        # The rollback won: undone once, and the charge wasn't tried again.
        [_, {:ok, _}] ->
          assert get(id).status == :compensated
          assert {Probe.hits({:charge, id}), Probe.hits({:release, id})} == {1, 1}
      end
    end
  end
end
