defmodule Durable.Integration.DeploysAndKeysRegressionsTest do
  @moduledoc "Nodes without a workflow's code, every log level being saved, keyed schedules, and a sweep racing a live compensation."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log
  @moduletag timeout: 90_000

  alias Durable.Queue.StaleJobRecovery
  alias Durable.Scheduler
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.ScheduledWorkflow

  require Logger

  # Defined in this file, so a peer node hasn't got this code: the shape of an
  # old node in a rolling deploy.
  defmodule NewOnThisNode do
    use Durable

    workflow "r_new_on_this_node" do
      step(:work, [retry: [max_attempts: 3]], fn data -> {:ok, data} end)
    end
  end

  defp idle_durable! do
    Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)
  end

  defp step_rows(id) do
    IntegrationRepo.all(
      from(s in StepExecution, where: s.workflow_id == ^id, order_by: s.inserted_at)
    )
  end

  describe "a node that hasn't got the code" do
    test "leaves a run it can't execute to a node that can" do
      idle_durable!()
      _old = start_node!(:old_a, %{default: 2})

      {:ok, id} = Durable.start(NewOnThisNode, %{})

      assert_eventually(fn -> get(id).scheduled_at != nil end, 5_000)
      run = get(id)

      refute run.status == :failed
    end

    test "doesn't burn a schedule's fire and turn it off" do
      idle_durable!()
      old = start_node!(:old_b, %{default: 1})
      {:ok, s} = API.schedule(NewOnThisNode, "* * * * *", name: "new_sched")

      make_due = fn ->
        {1, _} =
          IntegrationRepo.update_all(from(x in ScheduledWorkflow, where: x.id == ^s.id),
            set: [next_run_at: DateTime.add(DateTime.utc_now(), -5, :second)]
          )
      end

      for _ <- 1..5 do
        make_due.()
        :ok = :erpc.call(old, Scheduler, :check_schedules, [Durable])
        _ = :erpc.call(old, Scheduler, :status, [Durable])
      end

      row = IntegrationRepo.get!(ScheduledWorkflow, s.id)

      runs =
        IntegrationRepo.aggregate(
          from(w in WorkflowExecution, where: w.workflow_name == "r_new_on_this_node"),
          :count
        )

      assert row.enabled
      assert runs == 0
    end
  end

  describe "levels" do
    defmodule LogsEveryLevel do
      use Durable
      require Logger

      workflow "r_levels" do
        step(:w, fn data ->
          Logger.debug("d")
          Logger.info("i")
          Logger.notice("n")
          Logger.warning("w")
          Logger.error("e")
          Logger.critical("c")
          Logger.alert("a")
          Logger.emergency("em")
          {:ok, data}
        end)
      end
    end

    test "every level is saved by default, as the production guide says" do
      previous = Application.get_env(:durable, :log_capture, [])
      Application.put_env(:durable, :log_capture, Keyword.delete(previous, :levels))
      on_exit(fn -> Application.put_env(:durable, :log_capture, previous) end)

      prev_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(LogsEveryLevel, %{})
      await_status(id, :completed)
      [row] = step_rows(id)
      saved = Enum.map(row.logs, & &1["level"])
      assert "critical" in saved and "notice" in saved
    end
  end

  describe "a keyed schedule" do
    defmodule Keyed do
      use Durable
      alias Durable.IntegrationProbe, as: Probe

      workflow "r_keyed" do
        step(:work, fn data ->
          Probe.note(:keyed)
          Probe.wait_for(:never)
          {:ok, data}
        end)
      end
    end

    test "that started nothing isn't reported as triggered" do
      test = self()
      h = "sched-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        h,
        [:durable, :schedule, :trigger],
        fn _, _, meta, _ -> send(test, {:triggered, meta.workflow_id}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(h) end)

      start_durable!(%{default: 2})
      {:ok, s} = API.schedule(Keyed, "* * * * *", name: "keyed", key: "only")

      for _ <- 1..2 do
        {1, _} =
          IntegrationRepo.update_all(from(x in ScheduledWorkflow, where: x.id == ^s.id),
            set: [next_run_at: DateTime.add(DateTime.utc_now(), -5, :second)]
          )

        Scheduler.check_schedules(Durable)
        Scheduler.status(Durable)
      end

      runs =
        IntegrationRepo.aggregate(
          from(w in WorkflowExecution, where: w.workflow_name == "r_keyed"),
          :count
        )

      assert runs == 1
      assert_receive {:triggered, _}, 500

      triggered_again =
        receive do
          {:triggered, _} -> true
        after
          300 -> false
        end

      refute triggered_again
    end
  end

  describe "a zombie sweep racing a live compensation" do
    defmodule TwoCompensations do
      use Durable
      alias Durable.IntegrationProbe, as: Probe

      workflow "r_two_comp" do
        step(:a, [compensate: :undo_a], fn d -> {:ok, d} end)
        step(:b, [compensate: :undo_b], fn d -> {:ok, d} end)
        step(:boom, fn _ -> {:fail, "no"} end)

        compensate(:undo_a, fn d ->
          Probe.note(:undo_a)
          {:ok, d}
        end)

        compensate(:undo_b, fn d ->
          Probe.note(:undo_b)
          {:ok, d}
        end)
      end
    end

    test "can't be overwritten by the worker the sweep gave up on" do
      start_durable!(%{default: 2}, stale_lock_timeout: 1, heartbeat_interval: 60_000)
      h = "pause-comp-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        h,
        [:durable, :compensation, :stop],
        fn _, _, meta, _ ->
          if meta.compensation == :undo_b do
            Probe.set(:comp_paused)
            Probe.wait_for(:comp_resume)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(h) end)

      {:ok, id} = Durable.start(TwoCompensations, %{})
      assert_eventually(fn -> Probe.set?(:comp_paused) end)

      # The row for undo_b is closed, undo_a's isn't open yet.
      Process.sleep(1_200)

      # What the sweep needs: the run hasn't been written to for a while.
      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [updated_at: DateTime.add(DateTime.utc_now(), -5, :second)]
        )

      StaleJobRecovery.recover_now(Durable)
      failed = await_status(id, :failed, 3_000)
      assert failed.error["type"] == "zombie_detected"

      :ok = Probe.set(:comp_resume)
      Process.sleep(500)

      run = get(id)

      assert run.status == :failed
    end
  end
end
