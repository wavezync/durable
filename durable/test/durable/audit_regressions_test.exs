defmodule Durable.AuditRegressionsTest do
  @moduledoc """
  The engine audit after issue #36: keys, context, the public API, child
  workflows, pruning and queries. Each test failed before its fix.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Storage.Schemas.WorkflowExecution

  defmodule Rebuild do
    use Durable
    use Durable.Wait

    workflow "probe_rebuild", on_duplicate: :run_again do
      step(:work, fn data ->
        wait_for_event("go")
        {:ok, data}
      end)
    end
  end

  defmodule Debounced do
    use Durable

    workflow "probe_debounced", debounce: [period: 50] do
      step(:work, fn data -> {:ok, data} end)
    end
  end

  defmodule Waiter do
    use Durable
    use Durable.Wait

    workflow "probe_waiter" do
      step(:work, fn data ->
        wait_for_event("never")
        {:ok, data}
      end)
    end
  end

  defmodule PutMap do
    use Durable
    use Durable.Context

    workflow "probe_put_map" do
      step(:one, fn _data ->
        put_context(%{count: 5})
        {:ok, %{}}
      end)
    end

    workflow "probe_put_key" do
      step(:one, fn _data ->
        put_context(:count, 5)
        {:ok, %{}}
      end)
    end
  end

  defmodule FlakyChild do
    use Durable

    workflow "probe_flaky_child" do
      step(:work, fn data ->
        if :persistent_term.get({__MODULE__, :broken}, false),
          do: {:error, "child broken"},
          else: {:ok, Map.put(data, "child", "ok")}
      end)
    end
  end

  defmodule CallsFlaky do
    use Durable
    use Durable.Orchestration

    workflow "probe_calls_flaky" do
      step(:call, fn data ->
        case call_workflow(FlakyChild, %{}) do
          {:ok, result} -> {:ok, Map.put(data, "result", result)}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  defmodule CallsByRef do
    use Durable
    use Durable.Orchestration

    workflow "probe_calls_by_ref" do
      step(:call, fn data ->
        {:ok, child} = call_workflow(FlakyChild, %{}, ref: data["ref"])
        {:ok, _id} = start_workflow(FlakyChild, %{}, ref: data["ref"])
        {:ok, Map.put(data, "result", child)}
      end)
    end
  end

  defmodule HalfBroken do
    use Durable
    use Durable.Context

    workflow "probe_half_broken" do
      parallel do
        step(:left, fn data -> {:ok, Map.put(data, "left", 1)} end)

        step(:right, fn data ->
          if :persistent_term.get({__MODULE__, :broken}, false),
            do: {:error, "right broken"},
            else: {:ok, Map.put(data, "right", 2)}
        end)
      end

      step(:after, fn data ->
        {:ok,
         Map.put(
           data,
           "seen",
           parallel_results() |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
         )}
      end)
    end
  end

  defp get(id), do: TestRepo.get!(WorkflowExecution, id)

  # --------------------------------------------------------------------------
  # Keys
  # --------------------------------------------------------------------------

  test "run_again: a start after the holder ended, before the waiting run was claimed, still leaves one waiting run with the newest input" do
    holder = run_workflow(Rebuild, %{"v" => 1}, key: "k")
    assert holder.status == :waiting

    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "k")

    :ok = Durable.send_event(holder.id, "go", %{})
    assert drain(holder).status == :completed

    # The waiting run is claimable now but no poller got to it yet.
    {:ok, third} = Durable.start(Rebuild, %{"v" => 3}, key: "k")

    open =
      TestRepo.all(
        from(w in WorkflowExecution,
          where: w.key == "k" and w.status in [:pending, :running, :waiting],
          order_by: w.inserted_at,
          select: {w.id, w.input, w.holds_key, w.runs_after_id}
        )
      )

    assert [{^waiting, %{"v" => 3}, false, _holder}] = open

    # Run everything to the end and record the order the inputs were processed in.
    order = run_all_keyed("k", [])

    assert third == waiting, "a second run was created instead of refreshing the waiting one"
    assert List.last(order) == 3, "the newest input must be the last one processed"
  end

  # Runs what a poller would: a pending run only once the run it's behind has ended.
  defp run_all_keyed(key, order) do
    closed = [:completed, :failed, :cancelled, :compensated, :compensation_failed]

    claimable =
      TestRepo.all(
        from(w in WorkflowExecution,
          left_join: h in WorkflowExecution,
          on: h.id == w.runs_after_id,
          where: w.key == ^key and w.status == :pending,
          where: is_nil(w.runs_after_id) or h.status in ^closed,
          select: w.id
        )
      )

    Enum.each(claimable, &Durable.Executor.execute_workflow(&1, Config.get(Durable)))

    case TestRepo.all(
           from(w in WorkflowExecution,
             where: w.key == ^key and w.status == :waiting,
             order_by: w.inserted_at
           )
         ) do
      [] ->
        order

      [run | _] ->
        :ok = Durable.send_event(run.id, "go", %{})
        drain(run)
        run_all_keyed(key, order ++ [run.input["v"]])
    end
  end

  test "Testing.drain/2 leaves a run that waits behind an open holder alone" do
    holder = run_workflow(Rebuild, %{"v" => 1}, key: "t")
    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "t")

    assert drain(waiting).status == :pending
    assert get(holder.id).status == :waiting
  end

  test "debounce: a duplicate start doesn't pull a run scheduled for later forward" do
    tomorrow = DateTime.add(DateTime.utc_now(), 86_400, :second)

    {:ok, id} = Durable.start(Debounced, %{"v" => 1}, key: "d", scheduled_at: tomorrow)
    assert DateTime.diff(get(id).scheduled_at, tomorrow, :second) == 0

    # The same producer sends it again (still for tomorrow).
    {:ok, ^id} = Durable.start(Debounced, %{"v" => 2}, key: "d", scheduled_at: tomorrow)

    run = get(id)
    assert DateTime.diff(run.scheduled_at, tomorrow, :second) == 0
  end

  # --------------------------------------------------------------------------
  # Public API: cancel_all with a filter that Query ignores
  # --------------------------------------------------------------------------

  for {label, filters} <- [
        {"an empty tag", [tag: ""]},
        {"a nil tag", [tag: nil]},
        {"a nil key", [key: nil]},
        {"a misspelt filter name", [tags: "account:7"]},
        {"a nil workflow", [workflow_name: ""]}
      ] do
    test "cancel_all with #{label} doesn't cancel unrelated runs" do
      bystander = run_workflow(Waiter, %{}, tags: ["account:1"])
      assert bystander.status == :waiting

      result =
        try do
          Durable.cancel_all(unquote(filters), "account closed")
        rescue
          e -> {:raised, e.__struct__}
        end

      assert result in [{:ok, 0}, {:raised, ArgumentError}]
      assert get(bystander.id).status == :waiting
    end
  end

  # --------------------------------------------------------------------------
  # Query: values that can't match answer, they don't raise
  # --------------------------------------------------------------------------

  for {label, call} <- [
        {"list_executions(id: not-a-uuid)", quote(do: Durable.list_executions(id: "not-a-uuid"))},
        {"list_executions(parent_workflow_id: not-a-uuid)",
         quote(do: Durable.list_executions(parent_workflow_id: "not-a-uuid"))},
        {"list_executions(status: nil)", quote(do: Durable.list_executions(status: nil))},
        {"list_executions(status: :bogus)", quote(do: Durable.list_executions(status: :bogus))},
        {"list_executions(workflow_name: nil)",
         quote(do: Durable.list_executions(workflow_name: nil))},
        {"list_executions(limit: nil)", quote(do: Durable.list_executions(limit: nil))},
        {"count_by_status(status: nil)", quote(do: Durable.Query.count_by_status(status: nil))},
        {"get_step_executions(not-a-uuid)",
         quote(do: Durable.Query.get_step_executions("not-a-uuid"))},
        {"get_step_logs(not-a-uuid)",
         quote(do: Durable.Query.get_step_logs("not-a-uuid", :step))},
        {"child_counts([not-a-uuid])", quote(do: Durable.Query.child_counts(["not-a-uuid"]))},
        {"list_keys(limit: nil)", quote(do: Durable.Query.list_keys(limit: nil))}
      ] do
    test "query: #{label} doesn't raise" do
      result =
        try do
          {:returned, unquote(call)}
        rescue
          e -> {:raised, e.__struct__, Exception.message(e) |> String.slice(0, 120)}
        end

      assert match?({:returned, _}, result)
    end
  end

  # --------------------------------------------------------------------------
  # Context
  # --------------------------------------------------------------------------

  test "put_context/1 with a map saves the same thing put_context/2 does" do
    by_key = run_workflow(PutMap, %{"count" => 0}, workflow: "probe_put_key")
    by_map = run_workflow(PutMap, %{"count" => 0}, workflow: "probe_put_map")

    assert by_key.context["count"] == 5
    assert by_map.context["count"] == 5
  end

  # --------------------------------------------------------------------------
  # Orchestration
  # --------------------------------------------------------------------------

  test "a ref made at runtime doesn't mint atoms" do
    ref = "order-#{System.unique_integer([:positive])}"

    assert run_workflow(CallsByRef, %{"ref" => ref}).status == :completed

    for prefix <- ["__child:", "__child_done:", "__fire_forget:"] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(prefix <> ref) end
    end
  end

  test "a parent retried after its child was retried to success sees the child's result" do
    :persistent_term.put({FlakyChild, :broken}, true)
    on_exit(fn -> :persistent_term.erase({FlakyChild, :broken}) end)

    parent = run_workflow(CallsFlaky, %{})
    assert parent.status == :failed

    [child] = Durable.list_children(parent.id)
    assert child.status == :failed

    :persistent_term.put({FlakyChild, :broken}, false)

    {:ok, _} = Durable.retry(child.id)
    assert drain(child.id).status == :completed

    {:ok, _} = Durable.retry(parent.id)
    parent = drain(parent.id)

    assert parent.status == :completed
  end

  # --------------------------------------------------------------------------
  # Pruner
  # --------------------------------------------------------------------------

  test "pruning completed runs doesn't break a later retry of a failed parallel block" do
    :persistent_term.put({HalfBroken, :broken}, true)
    on_exit(fn -> :persistent_term.erase({HalfBroken, :broken}) end)

    parent = run_workflow(HalfBroken, %{})
    assert parent.status == :failed

    # Only completed runs are pruned: the failed parent is kept forever.
    Process.sleep(5)
    deleted = Durable.Pruner.prune(%{Config.get(Durable) | prune: [completed: 1]})
    assert deleted.completed == 0

    :persistent_term.put({HalfBroken, :broken}, false)
    {:ok, _} = Durable.retry(parent.id)
    parent = drain(parent.id)

    assert parent.status == :completed
    assert parent.context["seen"] == ["left", "right"]
  end

  test "control: the same retry without pruning sees both branches" do
    :persistent_term.put({HalfBroken, :broken}, true)
    on_exit(fn -> :persistent_term.erase({HalfBroken, :broken}) end)

    parent = run_workflow(HalfBroken, %{})
    assert parent.status == :failed

    :persistent_term.put({HalfBroken, :broken}, false)
    {:ok, _} = Durable.retry(parent.id)
    parent = drain(parent.id)

    assert parent.status == :completed
    assert parent.context["seen"] == ["left", "right"]
  end

  test "rerun keeps the run's tags" do
    run = run_workflow(Debounced, %{"v" => 1}, tags: ["account:7"])
    assert run.status == :completed

    {:ok, again} = Durable.rerun(run.id)
    assert get(again).tags == ["account:7"]
  end

  test "a waiting run whose holder was pruned takes the key" do
    holder = run_workflow(Rebuild, %{"v" => 1}, key: "p")
    {:ok, waiting} = Durable.start(Rebuild, %{"v" => 2}, key: "p")
    :ok = Durable.send_event(holder.id, "go", %{})
    assert drain(holder).status == :completed

    Process.sleep(5)
    assert %{completed: 1} = Durable.Pruner.prune(%{Config.get(Durable) | prune: [completed: 1]})

    run = drain(waiting)
    assert {run.status, run.holds_key, run.runs_after_id} == {:waiting, true, nil}
  end
end
