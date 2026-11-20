defmodule Durable.Integration.OnFailureTest do
  @moduledoc "Rolling a failed run back by hand, with live pollers and racing callers."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.IntegrationProbe, as: Probe
  alias Durable.Wait.TimeoutWorker

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

  defmodule Slow do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    # Cancelled at any moment: before, during or after the seat is held.
    workflow "of_slow_booking" do
      step(:hold_seat, [compensate: :release_seat], fn trip ->
        Process.sleep(20)
        {:ok, trip}
      end)

      step(:charge_card, fn trip ->
        Process.sleep(40)
        {:ok, trip}
      end)

      compensate(:release_seat, fn trip ->
        Probe.note({:release, Durable.Context.workflow_id()})
        {:ok, trip}
      end)
    end

    workflow "of_expiring_hold", on_failure: [rollback_after: days(5)] do
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

    workflow "of_referee" do
      parallel :checks do
        step(:credit, fn application -> {:ok, Map.put(application, :score, 700)} end)

        lane :referee, optional: true, timeout: 300 do
          step(:ask, fn application ->
            wait_for_input("referee")
            {:ok, application}
          end)
        end
      end

      step(:decide, fn application -> {:ok, application} end)
    end
  end

  defp held_seat?(id) do
    IntegrationRepo.exists?(
      from(s in Durable.Storage.Schemas.StepExecution,
        where: s.workflow_id == ^id and s.step_name == "hold_seat" and s.status == :completed
      )
    )
  end

  test "cancel with rollback: true, landing anywhere in a run, undoes exactly what completed" do
    start_durable!(%{default: 8})

    ids =
      for n <- 1..24 do
        {:ok, id} = Durable.start(Slow, %{}, workflow: "of_slow_booking")
        Process.sleep(rem(n * 7, 90))
        {id, Durable.cancel(id, "customer cancelled", rollback: true)}
      end

    for {id, cancelled} <- ids do
      assert_eventually(fn ->
        get(id).status in [:completed, :cancelled, :compensated, :compensation_failed]
      end)

      run = get(id)

      case cancelled do
        {:error, :already_completed} ->
          assert {run.status, Probe.hits({:release, id})} == {:completed, 0}

        :ok ->
          # A seat that was held is released, once. One that wasn't is left alone.
          expected = if held_seat?(id), do: {:compensated, 1}, else: {:cancelled, 0}
          assert {run.status, Probe.hits({:release, id})} == expected
          assert run.error["type"] == "cancelled"
      end
    end

    outcomes = for {id, _} <- ids, do: get(id).status
    assert :compensated in outcomes, "never cancelled a run that had held its seat"
  end

  test "sweeps on two nodes and a retry, all at once, act on an overdue run once" do
    start_durable!(%{default: 4})

    ids =
      for _ <- 1..20 do
        {:ok, id} = Durable.start(Slow, %{}, workflow: "of_expiring_hold")
        await_status(id, :failed)
        id
      end

    assert Enum.all?(ids, &match?(%DateTime{}, get(&1).scheduled_at))
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    IntegrationRepo.update_all(
      from(w in WorkflowExecution, where: w.id in ^ids),
      set: [scheduled_at: past]
    )

    sweep = fn ->
      TimeoutWorker.check_timeouts(Durable)
      :sys.get_state(TimeoutWorker.worker_name(Durable))
    end

    retries =
      [sweep, sweep | Enum.map(ids, fn id -> fn -> Durable.retry(id) end end)]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(15_000)
      |> Enum.drop(2)

    for {id, retried} <- Enum.zip(ids, retries) do
      assert_eventually(fn -> get(id).status in [:failed, :compensated] end)
      # Settled: a retried run has failed a second time.
      assert_eventually(fn ->
        Probe.hits({:charge, id}) == 2 or get(id).status == :compensated
      end)

      case retried do
        {:ok, _} ->
          assert {get(id).status, Probe.hits({:charge, id}), Probe.hits({:release, id})} ==
                   {:failed, 2, 0}

        {:error, :not_failed} ->
          assert {get(id).status, Probe.hits({:charge, id}), Probe.hits({:release, id})} ==
                   {:compensated, 1, 1}
      end
    end
  end

  test "a lane waiting past its timeout is ended by the sweep, and the run goes on without it" do
    start_durable!(%{default: 2})

    {:ok, id} = Durable.start(Slow, %{}, workflow: "of_referee")
    await_status(id, :waiting)
    Process.sleep(350)
    TimeoutWorker.check_timeouts(Durable)

    await_status(id, :completed)
    assert %{"credit" => %{"score" => 700}, "referee" => nil} = get(id).context["checks"]

    [lane] =
      IntegrationRepo.all(
        from(w in WorkflowExecution, where: w.parent_workflow_id == ^id and w.status == :failed)
      )

    assert lane.error["message"] =~ "lane referee passed its 300ms timeout"
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
