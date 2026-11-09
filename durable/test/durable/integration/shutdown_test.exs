defmodule Durable.Integration.ShutdownTest do
  @moduledoc """
  A node that stops lets its running work finish, with real pollers and workers.
  """
  use Durable.IntegrationCase, async: false

  defmodule Slow do
    use Durable

    workflow "shut_slow" do
      step(:work, fn data ->
        Probe.here(:work)
        Process.sleep(data["ms"])
        {:ok, data}
      end)
    end
  end

  defmodule Quick do
    use Durable

    workflow "shut_quick" do
      step(:work, fn data -> {:ok, data} end)
    end
  end

  defmodule TwoSteps do
    use Durable

    workflow "shut_two_steps" do
      step(:first, fn data ->
        Probe.here(:first)
        Process.sleep(400)
        {:ok, data}
      end)

      step(:second, fn data ->
        Probe.here(:second)
        {:ok, data}
      end)
    end
  end

  defmodule InBranch do
    use Durable

    workflow "shut_in_branch" do
      step(:pick, fn data -> {:ok, Map.put(data, "path", "a")} end)

      branch on: fn data -> data["path"] end do
        "a" ->
          step(:a1, fn data ->
            Probe.here(:a1)
            Process.sleep(400)
            {:ok, data}
          end)

          step(:a2, fn data ->
            Probe.here(:a2)
            {:ok, data}
          end)

        "b" ->
          step(:b1, fn data ->
            Probe.here(:b1)
            {:ok, data}
          end)
      end
    end
  end

  defmodule Cooperative do
    use Durable
    use Durable.Context

    workflow "shut_cooperative" do
      step(:long, fn data ->
        Probe.here(:long)

        stopping =
          Enum.find_value(1..100, fn _ -> shutting_down?() || (Process.sleep(10) && nil) end)

        if stopping, do: {:snooze, 0, "node stopping"}, else: {:ok, data}
      end)
    end
  end

  defmodule SlowOnce do
    use Durable

    workflow "shut_slow_once" do
      step(:work, fn data ->
        if Probe.here(:once) == 1, do: Process.sleep(30_000)
        {:ok, data}
      end)
    end
  end

  defmodule SlowUndo do
    use Durable

    workflow "shut_slow_undo" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
      step(:charge, fn _data -> {:fail, "declined"} end)

      compensate(:unbook, fn data ->
        Probe.here(:undoing)
        Process.sleep(500)
        {:ok, data}
      end)
    end
  end

  def forward(event, measurements, meta, pid), do: send(pid, {event, measurements, meta})

  defp start!(workflow, input, opts \\ []) do
    {:ok, id} = Durable.start(workflow, input, opts)
    id
  end

  defp await_working(count),
    do: assert_eventually(fn -> Probe.hits(:work) == count end, 5_000, 10)

  defp stop_ms do
    {us, _} = :timer.tc(fn -> stop_supervised!(Durable) end)
    div(us, 1_000)
  end

  test "a running step finishes, and runs only once" do
    start_durable!(%{default: 2}, shutdown_grace_period: 5_000)
    id = start!(Slow, %{"ms" => 300})
    await_working(1)

    stop_ms()

    assert get(id).status == :completed
    assert Probe.hits(:work) == 1
  end

  test "every queue drains at once, inside one grace period" do
    start_durable!(%{default: 1, ocr: 1}, shutdown_grace_period: 5_000)
    a = start!(Slow, %{"ms" => 1_500})
    b = start!(Slow, %{"ms" => 1_500}, queue: :ocr)
    await_working(2)

    assert stop_ms() < 2_700

    assert get(a).status == :completed
    assert get(b).status == :completed
  end

  test "nothing new is claimed while it drains" do
    start_durable!(%{default: 5}, shutdown_grace_period: 5_000)
    slow = start!(Slow, %{"ms" => 1_000})
    await_working(1)

    late =
      Task.async(fn ->
        Process.sleep(200)
        start!(Quick, %{})
      end)

    stop_ms()
    quick = Task.await(late)

    assert get(slow).status == :completed
    assert get(quick).status == :pending
  end

  test "a step that outlasts the grace period doesn't hold up the stop" do
    start_durable!(%{default: 1}, shutdown_grace_period: 200)
    id = start!(Slow, %{"ms" => 30_000})
    await_working(1)

    assert stop_ms() < 3_000

    run = get(id)
    assert run.status == :pending
    assert run.locked_by == nil
    assert run.lock_token == nil
  end

  test "a killed step's run can be claimed at once, without waiting for its lock to go stale" do
    start_durable!(%{default: 1}, shutdown_grace_period: 200)
    id = start!(SlowOnce, %{})
    assert_eventually(fn -> Probe.hits(:once) == 1 end, 5_000, 10)
    stop_ms()

    start_durable!(%{default: 1})

    assert await_status(id, :completed, 5_000)
    assert Probe.hits(:once) == 2
  end

  test "finishes the current step, then hands the rest to another node" do
    start_durable!(%{default: 2}, shutdown_grace_period: 5_000)
    id = start!(TwoSteps, %{})
    assert_eventually(fn -> Probe.hits(:first) == 1 end, 5_000, 10)

    stop_ms()

    run = get(id)
    assert {run.status, run.current_step, run.locked_by} == {:pending, "second", nil}
    assert Probe.hits(:second) == 0

    start_durable!(%{default: 2})

    assert await_status(id, :completed, 5_000)
    assert {Probe.hits(:first), Probe.hits(:second)} == {1, 1}
  end

  test "a run inside a branch stays on its clause when it's handed over" do
    start_durable!(%{default: 2}, shutdown_grace_period: 5_000)
    id = start!(InBranch, %{})
    assert_eventually(fn -> Probe.hits(:a1) == 1 end, 5_000, 10)

    stop_ms()
    assert get(id).status == :pending

    start_durable!(%{default: 2})

    assert await_status(id, :completed, 5_000)
    assert {Probe.hits(:a1), Probe.hits(:a2), Probe.hits(:b1)} == {1, 1, 0}
  end

  test "a step can see the stop coming and snooze, without using an attempt" do
    start_durable!(%{default: 1}, shutdown_grace_period: 5_000)
    id = start!(Cooperative, %{})
    assert_eventually(fn -> Probe.hits(:long) == 1 end, 5_000, 10)

    assert stop_ms() < 800

    assert get(id).status == :pending

    assert [{"long", 1, :snoozed}] ==
             IntegrationRepo.all(
               from(s in StepExecution,
                 where: s.workflow_id == ^id,
                 select: {s.step_name, s.attempt, s.status}
               )
             )

    start_durable!(%{default: 1})
    assert await_status(id, :completed, 5_000)
  end

  test "a compensation isn't handed over" do
    start_durable!(%{default: 1}, shutdown_grace_period: 5_000)
    id = start!(SlowUndo, %{})
    assert_eventually(fn -> Probe.hits(:undoing) == 1 end, 5_000, 10)

    stop_ms()

    assert get(id).status == :compensated
  end

  describe "Durable.drain/1" do
    test "stops this node claiming and waits, and the node keeps running" do
      start_durable!(%{default: 5}, shutdown_grace_period: 5_000)
      slow = start!(Slow, %{"ms" => 300})
      await_working(1)

      assert Durable.drain() == :ok
      assert get(slow).status == :completed

      late = start!(Quick, %{})
      Process.sleep(200)
      assert get(late).status == :pending
    end

    test "says when time ran out, and leaves the work running" do
      start_durable!(%{default: 1}, shutdown_grace_period: 5_000)
      id = start!(Slow, %{"ms" => 600})
      await_working(1)

      assert Durable.drain(timeout: 100) == {:error, :timeout}

      assert await_status(id, :completed, 5_000)
    end

    test "reports the drain to telemetry" do
      handler = "drain-#{System.unique_integer()}"
      start_durable!(%{default: 1}, shutdown_grace_period: 5_000)

      :telemetry.attach_many(
        handler,
        [[:durable, :node, :drain, :start], [:durable, :node, :drain, :stop]],
        &__MODULE__.forward/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert Durable.drain() == :ok

      assert_received {[:durable, :node, :drain, :start], _, %{durable: Durable}}
      assert_received {[:durable, :node, :drain, :stop], %{duration: _}, %{result: :ok}}
    end
  end
end
