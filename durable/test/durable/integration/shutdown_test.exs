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
    assert run.status == :running
    assert run.locked_by
  end
end
