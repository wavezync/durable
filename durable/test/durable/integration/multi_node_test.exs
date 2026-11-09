defmodule Durable.Integration.MultiNodeTest do
  @moduledoc """
  Real BEAM nodes on one database, connected the way a cluster is.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Queue.StaleJobRecovery
  alias Durable.Wait.TimeoutWorker

  @queues %{default: 5, ocr: 1}

  defp start_on!(node, workflow, input \\ %{}) do
    {:ok, id} = :erpc.call(node, Durable, :start, [workflow, input, []])
    id
  end

  test "concurrency is per node: two nodes with one slot run two at once" do
    a = start_node!(:node_a, @queues)
    b = start_node!(:node_b, @queues)
    connect_nodes!([a, b])

    ids = for n <- 1..6, do: start_on!(a, W.SlowOnOcr, %{"n" => n})

    assert_eventually(fn -> Enum.all?(ids, &(get(&1).status == :completed)) end, 15_000)
    assert Probe.peak(:ocr) == 2
  end

  test "polling a step's queue on one node makes its limit a total" do
    a = start_node!(:node_a, @queues)
    b = start_node!(:node_b, %{default: 5})
    connect_nodes!([a, b])

    ids = for n <- 1..4, do: start_on!(b, W.SlowOnOcr, %{"n" => n})

    assert_eventually(fn -> Enum.all?(ids, &(get(&1).status == :completed)) end, 15_000)
    assert Probe.peak(:ocr) == 1
    assert Probe.log() |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [a]
  end

  test "a move wakes the queue's poller on another node, with no poll to wait for" do
    a = start_node!(:node_a, %{default: 2}, poll_interval: :timer.hours(1))
    b = start_node!(:node_b, %{ocr: 2}, poll_interval: :timer.hours(1))
    connect_nodes!([a, b])

    id = start_on!(a, W.HeldOnOcr)
    :ok = Probe.set(:release)

    await_status(id, :completed, 5_000)

    assert Probe.log() == [{:held, "ocr", b}, {:save, "default", a}]
  end

  test "a start inside a transaction wakes another node's poller when it commits" do
    a = start_node!(:node_a, %{documents: 1}, poll_interval: :timer.hours(1))
    b = start_node!(:node_b, %{default: 2, ocr: 2}, poll_interval: :timer.hours(1))
    connect_nodes!([a, b])

    id = :erpc.call(a, Durable.IntegrationCase, :start_in_transaction, [W.QuickOnOcr, %{}])

    await_status(id, :completed, 5_000)
    assert [{_, _, ^b} | _] = Probe.log()
  end

  test "two nodes sharing queues never run a step twice" do
    queues = %{documents: 4, downloads: 2, ocr: 2, llm: 2}
    a = start_node!(:node_a, queues)
    b = start_node!(:node_b, queues)
    connect_nodes!([a, b])

    ids = for n <- 1..30, do: start_on!(a, W.Burst, %{"n" => n})

    assert_eventually(fn -> Enum.all?(ids, &(get(&1).status == :completed)) end, 30_000, 50)

    for n <- 1..30, step <- [:a, :b, :c, :d] do
      assert Probe.hits({step, n}) == 1, "#{step} of run #{n} ran #{Probe.hits({step, n})} times"
    end

    assert Probe.log() |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort([a, b])
  end

  test "a node that dies mid-step: another node runs the step again on that queue" do
    opts = [stale_lock_timeout: 1]
    a = start_node!(:node_a, @queues, opts)
    b = start_node!(:node_b, @queues, opts)
    connect_nodes!([a, b])

    id = start_on!(a, W.HeldOnOcr)
    assert_eventually(fn -> Probe.hits(:held) == 1 end)
    [{:held, "ocr", holder}] = Probe.log()
    survivor = if holder == a, do: b, else: a

    crash_node!(holder)
    assert get(id).status == :running

    :ok = Probe.set(:release)
    Process.sleep(1_200)
    :erpc.call(survivor, StaleJobRecovery, :recover_now, [Durable])

    run = await_status(id, :completed)

    assert Probe.log() == [
             {:held, "ocr", holder},
             {:held, "ocr", survivor},
             {:save, "default", survivor}
           ]

    assert {run.queue, run.home_queue} == {"default", nil}
  end

  test "pausing a queue from one node holds it on the others" do
    a = start_node!(:node_a, @queues)
    b = start_node!(:node_b, @queues)
    connect_nodes!([a, b])

    :erpc.call(a, Durable, :pause_queue, [:ocr])
    id = start_on!(b, W.QuickOnOcr)

    assert_eventually(fn -> get(id).queue == "ocr" end)
    Process.sleep(200)
    assert get(id).status == :pending
    assert Probe.hits(:quick) == 0

    :erpc.call(b, Durable, :resume_queue, [:ocr])
    await_status(id, :completed)
  end

  test "once the only node polling a queue is gone, another node's sweep times the run out" do
    a = start_node!(:node_a, %{ocr: 1})
    b = start_node!(:node_b, %{default: 5})
    connect_nodes!([a, b])

    :erpc.call(a, Durable, :pause_queue, [:ocr])
    id = start_on!(b, W.TimesOutOnOcr)
    assert_eventually(fn -> get(id).queue == "ocr" end)
    expire!(id)

    sweep_on(b)
    assert get(id).status == :pending

    crash_node!(a)

    {1, _} =
      IntegrationRepo.update_all(
        from(n in Durable.Storage.Schemas.Node, where: "ocr" in n.queues),
        set: [heartbeat_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

    sweep_on(b)

    run = await_status(id, :failed)
    assert run.error["type"] == "timeout"
    assert Probe.hits(:timed_ocr) == 0
  end

  defp sweep_on(node) do
    :erpc.call(node, TimeoutWorker, :check_timeouts, [Durable])
    :erpc.call(node, :sys, :get_state, [TimeoutWorker.worker_name(Durable)])
  end
end
