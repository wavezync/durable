defmodule Durable.Integration.ParallelRegressionsTest do
  @moduledoc "Lost notices from children, fail_fast, and the helpers that read a parallel block's results."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 60_000

  alias Durable.Queue.StaleJobRecovery
  alias Durable.Wait.TimeoutWorker

  defmodule Child do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_g_child" do
      step(:w, fn data ->
        Probe.note(:child)
        Probe.wait_for(:release_child)
        {:ok, Map.put(data, "done", true)}
      end)
    end
  end

  defmodule Parent do
    use Durable
    use Durable.Orchestration
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_g_parent" do
      step(:call, fn data ->
        Probe.note(:parent)
        result = call_workflow(Child, %{})
        {:ok, Map.put(data, "result", inspect(result))}
      end)
    end
  end

  defmodule ParallelParent do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_g_parallel" do
      parallel do
        step(:only, fn data ->
          Probe.note(:child)
          Probe.wait_for(:release_child)
          {:ok, data}
        end)
      end

      step(:after, fn data -> {:ok, data} end)
    end
  end

  defmodule FailFast do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_g_fail_fast" do
      parallel on_error: :fail_fast do
        step(:bad, fn _data -> {:error, "boom"} end)

        step(:slow, fn data ->
          Probe.note(:slow)
          Probe.wait_for(:release_slow)
          Probe.note(:slow_finished)
          {:ok, data}
        end)
      end
    end
  end

  defmodule ReadsResults do
    use Durable
    use Durable.Context
    alias Durable.IntegrationProbe, as: Probe

    workflow "r_g_reads_results" do
      parallel do
        step(:payment, fn data -> {:ok, Map.put(data, :id, 123)} end)
      end

      step(:handle, fn ctx ->
        Probe.put(:all, parallel_results())
        Probe.put(:ok?, parallel_ok?(:payment))

        case parallel_result(:payment) do
          {:ok, _payment} -> {:ok, ctx}
          {:error, _} -> {:error, "failed"}
        end
      end)
    end
  end

  defp blocked_backend(pattern) do
    Enum.find_value(1..300, fn _ ->
      case IntegrationRepo.query!(
             "SELECT pid FROM pg_stat_activity WHERE datname = current_database() " <>
               "AND wait_event_type = 'Lock' AND query ILIKE $1",
             [pattern]
           ).rows do
        [[pid] | _] ->
          pid

        [] ->
          Process.sleep(20)
          nil
      end
    end)
  end

  # Holds the parent's row, so the child's notice blocks on it, then kills that
  # one backend: the child has committed :completed and nobody tells the parent.
  defp lose_the_notice(parent_id) do
    test = self()

    holder =
      Task.async(fn ->
        IntegrationRepo.transaction(fn ->
          IntegrationRepo.query!(
            "SELECT 1 FROM durable.workflow_executions WHERE id = $1 FOR UPDATE",
            [Ecto.UUID.dump!(parent_id)]
          )

          send(test, :locked)

          receive do
            :let_go -> :ok
          end
        end)
      end)

    assert_receive :locked, 2_000
    :ok = Probe.set(:release_child)
    pid = blocked_backend("%FOR UPDATE%")
    assert is_integer(pid), "the child's notice never blocked"
    IntegrationRepo.query!("SELECT pg_terminate_backend($1)", [pid])
    Process.sleep(300)
    send(holder.pid, :let_go)
    Task.await(holder)
  end

  for {mod, name} <- [{Parent, "call_workflow"}, {ParallelParent, "parallel"}] do
    @mod mod
    test "a child's lost notice doesn't strand a #{name} parent" do
      start_durable!(%{default: 4}, stale_lock_timeout: 1)
      {:ok, id} = Durable.start(@mod, %{})
      assert_eventually(fn -> Probe.hits(:child) == 1 end)
      assert_eventually(fn -> get(id).status == :waiting end)

      [child] =
        IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^id))

      lose_the_notice(id)

      Process.sleep(1_200)

      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [updated_at: DateTime.add(DateTime.utc_now(), -3_600, :second)]
        )

      StaleJobRecovery.recover_now(Durable)
      TimeoutWorker.check_timeouts(Durable)
      Process.sleep(1_000)

      refute get(child.id).status == :completed and get(id).status == :waiting
    end
  end

  test "fail_fast stops on the first error, as the guide says" do
    start_durable!(%{default: 3})
    {:ok, id} = Durable.start(FailFast, %{})
    assert_eventually(fn -> Probe.hits(:slow) == 1 end)
    Process.sleep(1_000)
    run = get(id)

    branches =
      IntegrationRepo.all(
        from(w in WorkflowExecution,
          where: w.parent_workflow_id == ^id,
          select: {w.current_step, w.status}
        )
      )

    :ok = Probe.set(:release_slow)
    assert run.status != :waiting
  end

  test "parallel_results/0, parallel_result/1 and parallel_ok?/1 read what a branch returned" do
    start_durable!(%{default: 3})
    {:ok, id} = Durable.start(ReadsResults, %{})

    await_status(id, :completed)

    assert %{payment: {:ok, %{"id" => 123}}} = Probe.fetch(:all)
    assert Probe.fetch(:ok?) == true
  end
end
