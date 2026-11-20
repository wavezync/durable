defmodule Durable.Integration.AuditKeysAndChildrenRegressionsTest do
  @moduledoc """
  The engine audit after issue #36: what needs committed rows, real
  concurrency or a second node.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Config
  alias Durable.Executor

  defmodule AlwaysFails do
    use Durable

    workflow "probe_always_fails" do
      step(:work, fn _data -> {:fail, "nope"} end)
    end
  end

  defp spin(us) do
    until = System.monotonic_time(:microsecond) + us
    spin_until(until)
  end

  defp spin_until(until) do
    if System.monotonic_time(:microsecond) < until, do: spin_until(until), else: :ok
  end

  # W.Parent calls W.Child with `ref: :child` and waits. The first node runs the
  # call and dies; a second node, which has never run that call, runs the child
  # and resumes the parent.
  test "a parent resumed on a node that never ran its call_workflow doesn't start the child again" do
    a = start_node!(:node_a, %{documents: 2, ocr: 2})
    {:ok, parent_id} = :erpc.call(a, Durable, :start, [W.Parent, %{}, []])

    await_status(parent_id, :waiting)
    crash_node!(a)

    children = fn ->
      IntegrationRepo.all(
        from(w in WorkflowExecution,
          where: w.parent_workflow_id == ^parent_id,
          order_by: w.inserted_at,
          select: {w.id, w.status}
        )
      )
    end

    assert [{_child, :pending}] = children.()

    b = start_node!(:node_b, %{documents: 2, ocr: 2, default: 2, llm: 2})
    # Give the second node time to finish the run, then look at what it did.
    Process.sleep(5_000)
    parent = get(parent_id)

    assert b
    assert parent.status == :completed
    assert length(children.()) == 1
    assert Probe.hits(:child_work) == 1
  end

  # A failed run that holds its key is retried while a new start with the same
  # key takes the key from it. Only one of the two may end up open.
  test "retrying a failed key holder never leaves two open runs for the key" do
    Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)
    config = Config.get(Durable)

    both_open =
      for n <- 1..300, reduce: [] do
        acc ->
          key = "race:#{n}"
          {:ok, id} = Durable.start(AlwaysFails, %{}, key: key)
          Executor.execute_workflow(id, config)
          %{status: :failed, holds_key: true} = get(id)

          # The start goes first by 0 to 3 ms, so the retry lands at every point of it.
          delay_us = rem(n * 37, 3_000)

          tasks = [
            Task.async(fn ->
              spin(delay_us)
              Durable.retry(id)
            end),
            Task.async(fn -> Durable.start(AlwaysFails, %{}, key: key) end)
          ]

          results = Task.await_many(tasks, 10_000)

          open =
            IntegrationRepo.all(
              from(w in WorkflowExecution,
                where: w.key == ^key and w.status in [:pending, :running, :waiting],
                select: {w.id, w.status, w.holds_key}
              )
            )

          if length(open) > 1, do: [{n, results, open} | acc], else: acc
      end

    assert both_open == []
  end
end
