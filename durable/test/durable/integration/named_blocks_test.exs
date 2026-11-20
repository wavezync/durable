defmodule Durable.Integration.NamedBlocksTest do
  @moduledoc "Lanes under live workers: waits answered by lane, a deadline, a cancel, and a retry."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 120_000

  alias Durable.Queue.Manager
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput}
  alias Durable.Wait.TimeoutWorker

  defmodule Waits do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "named_waits", timeout: hours(1) do
      parallel :both do
        lane :a do
          step(:a1, fn data ->
            Probe.note(:a1)
            {:ok, data}
          end)

          step(:a2, fn data ->
            answer = wait_for_event("go")
            Probe.note(:a2)
            {:ok, Map.put(data, :went, answer["with"])}
          end)

          step(:a3, fn data ->
            Probe.note(:a3)
            {:ok, data}
          end)
        end

        step(:b, fn data ->
          answer = wait_for_input("ok")
          Probe.note(:b)
          {:ok, Map.put(data, :said, answer["value"])}
        end)
      end

      step(:after, fn %{both: %{a: a, b: b}} = data ->
        Probe.note(:after)
        {:ok, Map.put(data, :joined, [a["went"], b["said"]])}
      end)
    end
  end

  defmodule Breaks do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "named_breaks" do
      parallel :both do
        lane :slow do
          step(:s1, fn data ->
            Probe.note(:s1)
            {:ok, data}
          end)

          step(:s2, fn data ->
            Probe.note(:s2_started)
            Probe.wait_for(:release_slow)
            Probe.note(:s2)
            {:ok, data}
          end)
        end

        lane :quick do
          step(:q1, fn data ->
            Probe.wait_for(:slow_is_in_s2)

            if Probe.set?(:fixed),
              do: {:ok, data},
              else: {:fail, "quick is broken"}
          end)
        end
      end

      step(:after, fn data ->
        Probe.note(:after)
        {:ok, data}
      end)
    end
  end

  defp lanes(id) do
    IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^id))
  end

  defp lane(id, name) do
    Enum.find(lanes(id), &(&1.context["__parallel_step"] == name))
  end

  defp waiting_lanes(id) do
    assert_eventually(fn ->
      rows = lanes(id)
      length(rows) == 2 and Enum.all?(rows, &(&1.status == :waiting))
    end)

    lanes(id)
  end

  test "each lane's wait is answered at the lane, and the next step joins them" do
    start_durable!(%{default: 4})
    {:ok, id} = Durable.start(Waits, %{})
    waiting_lanes(id)

    assert get(id).status == :waiting
    assert Probe.hits(:a1) == 1

    :ok = Durable.send_event(lane(id, "both__a").id, "go", %{"with" => "event"})
    await_status(lane(id, "both__a").id, :completed)

    # One lane done doesn't move the block on.
    assert get(id).status == :waiting
    assert Probe.hits(:after) == 0

    :ok = Durable.provide_input(lane(id, "both__b").id, "ok", %{"value" => "input"})
    run = await_status(id, :completed)

    assert run.context["joined"] == ["event", "input"]
    assert {Probe.hits(:a1), Probe.hits(:a2), Probe.hits(:a3), Probe.hits(:b)} == {1, 1, 1, 1}
    assert Probe.hits(:after) == 1
  end

  test "a run past its timeout fails, and its waiting lanes stop with it" do
    start_durable!(%{default: 4})
    {:ok, id} = Durable.start(Waits, %{})
    waiting_lanes(id)

    expire!(id)
    TimeoutWorker.check_timeouts(Durable)
    run = await_status(id, :failed)

    assert run.error["type"] == "timeout"

    assert_eventually(fn ->
      Enum.all?(lanes(id), &(&1.status in [:cancelled, :failed]))
    end)

    lane_ids = Enum.map(lanes(id), & &1.id)

    for schema <- [PendingEvent, PendingInput] do
      open = from(p in schema, where: p.workflow_id in ^lane_ids and p.status == :pending)
      assert IntegrationRepo.aggregate(open, :count) == 0
    end

    assert {Probe.hits(:a2), Probe.hits(:a3), Probe.hits(:after)} == {0, 0, 0}
  end

  test "cancelling the run cancels every lane, and an answer afterwards starts nothing" do
    start_durable!(%{default: 4})
    {:ok, id} = Durable.start(Waits, %{})
    [first | _] = waiting_lanes(id)

    :ok = Durable.cancel(id, "changed our mind")

    assert_eventually(fn -> Enum.all?(lanes(id), &(&1.status == :cancelled)) end)
    assert get(id).status == :cancelled

    assert {:error, _} = Durable.send_event(first.id, "go", %{})
    Process.sleep(200)
    assert {Probe.hits(:a2), Probe.hits(:a3), Probe.hits(:after)} == {0, 0, 0}
  end

  test "a lane stopped in the middle of a step picks that step up again when the run is retried" do
    start_durable!(%{default: 4}, heartbeat_interval: 100)
    {:ok, id} = Durable.start(Breaks, %{})

    # The slow lane is inside s2 when the quick lane fails the block.
    assert_eventually(fn -> Probe.hits(:s2_started) == 1 end)
    Probe.set(:slow_is_in_s2)
    run = await_status(id, :failed)
    assert run.error["message"] =~ "quick is broken"

    slow = lane(id, "both__slow")
    assert_eventually(fn -> get(slow.id).status == :cancelled end)

    # Its worker is told at its next heartbeat and stops the step. Until then
    # the step is still running, and a retry in that gap would run it beside
    # the old one: wait for the worker to be gone.
    assert_eventually(fn -> Manager.status(Durable, :default).active_jobs == 0 end)

    rows = IntegrationRepo.all(from(s in StepExecution, where: s.workflow_id == ^slow.id))
    assert Enum.all?(rows, &(&1.status != :running))

    assert Probe.hits(:s2) == 0

    Probe.set(:fixed)
    Probe.set(:release_slow)
    {:ok, _} = Durable.retry(id)
    run = await_status(id, :completed)

    assert run.status == :completed
    # s1 was done and isn't repeated; s2 was stopped part-way and runs again.
    assert {Probe.hits(:s1), Probe.hits(:s2), Probe.hits(:after)} == {1, 1, 1}
    assert Probe.hits(:s2_started) == 2
    assert length(lanes(id)) == 2
  end
end
