defmodule Durable.Integration.EngineRegressionsTest do
  @moduledoc "How fail_fast, waits, missing code, pruning and schedule updates behave at their edges."
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.LogCapture.Handler
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.ScheduledWorkflow
  alias Durable.Wait.TimeoutWorker

  defmodule Background do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_background" do
      step(:work, fn data ->
        Probe.note(:background)
        Probe.wait_for(:never)
        {:ok, data}
      end)
    end
  end

  defmodule FailFast do
    use Durable
    use Durable.Orchestration
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_fail_fast" do
      step(:start_background, fn data ->
        {:ok, _} = start_workflow(Background, %{}, ref: :background)
        {:ok, data}
      end)

      parallel do
        # Several to cancel, and new atoms, because a small map orders atom keys
        # by when each atom was made: a cancelled error has to come up first.
        step(:ff_cancelled_one, fn data ->
          Probe.note(:slow)
          Probe.wait_for(:never)
          {:ok, data}
        end)

        step(:ff_cancelled_two, fn data ->
          Probe.wait_for(:never)
          {:ok, data}
        end)

        step(:ff_cancelled_three, fn data ->
          Probe.wait_for(:never)
          {:ok, data}
        end)

        step(:ff_the_failure, fn _data ->
          Probe.wait_for(:fail_now)
          {:error, %{type: "card_declined", message: "no"}}
        end)
      end

      step(:after_block, fn data ->
        Probe.note(:after_block)
        {:ok, data}
      end)
    end
  end

  defmodule CompleteAll do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_complete_all" do
      parallel on_error: :complete_all do
        step(:bad, fn _data -> {:error, "nope"} end)

        step(:slow, fn data ->
          Probe.note(:slow)
          Probe.wait_for(:release)
          {:ok, data}
        end)
      end
    end
  end

  defmodule Into do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_into" do
      parallel into: fn data, _results -> {:ok, data} end do
        step(:bad, fn _data -> {:error, "nope"} end)

        step(:slow, fn data ->
          Probe.note(:slow)
          Probe.wait_for(:release)
          {:ok, data}
        end)
      end
    end
  end

  defmodule TwoWaits do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_two_waits" do
      step(:w, fn data ->
        Probe.note(:body)
        first = wait_for_any(["a", "b"], timeout: 50, timeout_value: :first_timed_out)
        second = wait_for_event("second")
        Probe.put(:got, {first, second})
        {:ok, data}
      end)
    end
  end

  defmodule CancelThenSleep do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_cancel_then_sleep" do
      step(:w, fn data ->
        Probe.put(:got, wait_for_event("go"))
        {:ok, data}
      end)

      step(:nap, fn data ->
        Probe.put(:nap_keys, Map.keys(data))
        sleep(:timer.hours(1))
        {:ok, data}
      end)
    end
  end

  defmodule EventEqualsData do
    use Durable
    use Durable.Wait
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_event_equals_data" do
      step(:w, fn data ->
        Probe.put(:got, wait_for_event("approved"))
        {:ok, data}
      end)
    end
  end

  defmodule Quick do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_quick" do
      step(:work, fn data ->
        Probe.note(:ran)
        {:ok, data}
      end)
    end
  end

  defmodule LongChild do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_long_child" do
      step(:work, fn data ->
        Probe.wait_for(:never)
        {:ok, data}
      end)
    end
  end

  defmodule CallsWithDefaultTimeout do
    use Durable
    use Durable.Orchestration
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_calls_default_timeout" do
      step(:call, fn data ->
        Probe.put(:result, call_workflow(LongChild, %{}, ref: :child, timeout: 50))
        {:ok, data}
      end)
    end
  end

  defmodule ChecksConsoleUnderLimit do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "eng_console_limit" do
      step(:work, [timeout: 5_000], fn data ->
        Probe.put(:line, Handler.console_filter(%{level: :info, meta: %{}}, []))
        {:ok, data}
      end)
    end
  end

  defp branches(id) do
    IntegrationRepo.all(
      from(w in WorkflowExecution,
        where: w.parent_workflow_id == ^id and w.workflow_name == "eng_fail_fast"
      )
    )
  end

  defp expire_waits!(id) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    IntegrationRepo.update_all(
      from(g in Durable.Storage.Schemas.WaitGroup, where: g.workflow_id == ^id),
      set: [timeout_at: past]
    )

    IntegrationRepo.update_all(
      from(e in Durable.Storage.Schemas.PendingEvent, where: e.workflow_id == ^id),
      set: [timeout_at: past]
    )

    TimeoutWorker.check_timeouts(Durable)
  end

  describe "fail_fast" do
    test "fails the run with the real error, stops the others, and leaves other children alone" do
      start_durable!(%{default: 5})

      {:ok, id} = Durable.start(FailFast, %{})
      assert_eventually(fn -> Probe.hits(:slow) == 1 end)
      assert_eventually(fn -> Probe.hits(:background) == 1 end)
      :ok = Probe.set(:fail_now)

      run = await_status(id, :failed)

      assert run.error["type"] == "card_declined"

      assert Enum.sort(Enum.map(branches(id), & &1.status)) == [
               :cancelled,
               :cancelled,
               :cancelled,
               :failed
             ]

      assert Probe.hits(:after_block) == 0

      background =
        IntegrationRepo.one(
          from(w in WorkflowExecution,
            where: w.parent_workflow_id == ^id and w.workflow_name == "eng_background"
          )
        )

      assert background.status == :running
    end

    for {mod, name} <- [{CompleteAll, "on_error: :complete_all"}, {Into, "into:"}] do
      @mod mod
      test "doesn't apply with #{name}" do
        start_durable!(%{default: 5})

        {:ok, id} = Durable.start(@mod, %{})
        assert_eventually(fn -> Probe.hits(:slow) == 1 end)
        Process.sleep(300)
        assert get(id).status == :waiting

        :ok = Probe.set(:release)
        assert_eventually(fn -> get(id).status in [:completed, :failed] end)
      end
    end
  end

  describe "waits" do
    test "a timed-out group wait still counts when a later wait in the step resumes it" do
      start_durable!(%{default: 2})

      {:ok, id} = Durable.start(TwoWaits, %{})
      await_status(id, :waiting)
      Process.sleep(100)
      expire_waits!(id)

      assert_eventually(fn ->
        Probe.hits(:body) == 2 and get(id).status == :waiting
      end)

      :ok = Durable.send_event(id, "second", "payload")
      await_status(id, :completed)

      assert Probe.fetch(:got) == {:first_timed_out, "payload"}
      assert Probe.hits(:body) == 3
    end

    test "cancel_wait answers the wait, keeps the user's data and doesn't skip later sleeps" do
      start_durable!(%{default: 2})

      {:ok, id} = Durable.start(CancelThenSleep, %{"reason" => "mine"})
      await_status(id, :waiting)

      :ok = Durable.Wait.cancel_wait(id, reason: "operator")
      assert_eventually(fn -> Probe.fetch_or(:nap_keys, nil) != nil end)
      await_status(id, :waiting)

      assert Probe.fetch(:got) == {:cancelled, "operator"}
      assert "reason" in Probe.fetch(:nap_keys) or :reason in Probe.fetch(:nap_keys)
      refute Enum.any?(Probe.fetch(:nap_keys), &(to_string(&1) == "__cancelled__"))
      assert get(id).context["reason"] == "mine"

      assert DateTime.after?(
               get(id).scheduled_at,
               DateTime.add(DateTime.utc_now(), 3_000, :second)
             )
    end

    test "an event named like a data key returns the event, once it has arrived" do
      start_durable!(%{default: 2})

      {:ok, id} = Durable.start(EventEqualsData, %{"approved" => false})
      await_status(id, :waiting)

      :ok = Durable.send_event(id, "approved", %{"by" => "ana"})
      await_status(id, :completed)

      assert Probe.fetch(:got) == %{"by" => "ana"}
    end

    test "a call_workflow timeout without a timeout_value returns :child_timeout" do
      start_durable!(%{default: 4})

      {:ok, id} = Durable.start(CallsWithDefaultTimeout, %{})
      await_status(id, :waiting)
      Process.sleep(100)
      expire_waits!(id)
      await_status(id, :completed)

      assert Probe.fetch(:result) == {:ok, :child_timeout}
    end
  end

  describe "a run whose code isn't on this node" do
    test "waits on its queue and runs once a node has the code" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Quick, %{})
      await_status(id, :completed)
      Probe.hits(:ran)

      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [workflow_module: "Elixir.NotDeployedYet", status: :pending, current_step: nil]
        )

      assert_eventually(fn -> get(id).scheduled_at != nil end)
      run = get(id)
      assert run.status == :pending
      assert run.locked_by == nil
      assert run.error == nil

      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [workflow_module: Atom.to_string(Quick), scheduled_at: nil]
        )

      assert_eventually(fn -> Probe.hits(:ran) == 2 end)
      await_status(id, :completed)
    end
  end

  describe "a module that isn't loaded here, though its name is known" do
    setup do
      _ = :"Elixir.DurableKnownNameOnly"
      start_durable!(%{default: 1})
      :ok
    end

    test "leaves a run on the queue" do
      {:ok, id} = Durable.start(Quick, %{})
      await_status(id, :completed)

      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [
            workflow_module: "Elixir.DurableKnownNameOnly",
            status: :pending,
            current_step: nil
          ]
        )

      assert_eventually(fn -> get(id).scheduled_at != nil end)
      assert get(id).status == :pending
    end

    test "leaves a schedule alone during the grace period, and fails it after" do
      {:ok, s} = API.schedule(Quick, "* * * * *", name: "gone_soon")

      make_overdue = fn seconds ->
        {1, _} =
          IntegrationRepo.update_all(from(x in ScheduledWorkflow, where: x.id == ^s.id),
            set: [
              workflow_module: "Elixir.DurableKnownNameOnly",
              next_run_at: DateTime.add(DateTime.utc_now(), -seconds, :second)
            ]
          )

        Durable.Scheduler.check_schedules(Durable)
        Durable.Scheduler.status(Durable)
        IntegrationRepo.get!(ScheduledWorkflow, s.id).consecutive_failures
      end

      assert make_overdue.(60) == 0
      assert make_overdue.(16 * 60) == 1
    end
  end

  describe "the pruner" do
    test "deletes a branch once its parent has finished too" do
      start_durable!(%{default: 2}, prune: [completed: :timer.hours(1)])

      {:ok, id} = Durable.start(Quick, %{})
      await_status(id, :completed)

      {:ok, child} =
        %WorkflowExecution{}
        |> WorkflowExecution.changeset(%{
          workflow_module: Atom.to_string(Quick),
          workflow_name: "eng_quick",
          status: :completed,
          queue: "default",
          input: %{},
          context: %{},
          parent_workflow_id: id,
          completed_at: DateTime.add(DateTime.utc_now(), -7_200, :second)
        })
        |> IntegrationRepo.insert()

      {1, _} =
        IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
          set: [completed_at: DateTime.add(DateTime.utc_now(), -7_200, :second)]
        )

      Durable.prune()

      refute IntegrationRepo.get(WorkflowExecution, child.id)
      refute IntegrationRepo.get(WorkflowExecution, id)
    end
  end

  describe "updating a schedule" do
    test "to enabled clears its failure record, like enable_schedule/2 does" do
      start_durable!(%{default: 1})
      {:ok, s} = API.schedule(Quick, "0 9 * * *", name: "up")

      {1, _} =
        IntegrationRepo.update_all(from(x in ScheduledWorkflow, where: x.id == ^s.id),
          set: [
            enabled: false,
            consecutive_failures: 5,
            auto_disabled_at: DateTime.utc_now(),
            last_error: "boom",
            last_error_at: DateTime.utc_now()
          ]
        )

      {:ok, updated} = API.update_schedule("up", enabled: true)

      assert %{
               enabled: true,
               consecutive_failures: 0,
               auto_disabled_at: nil,
               last_error: nil,
               last_error_at: nil
             } = updated
    end

    test "with an input it can't store is refused, or stored safely" do
      start_durable!(%{default: 1})
      {:ok, _} = API.schedule(Quick, "0 9 * * *", name: "inp")

      assert {:ok, %{input: %{"a" => [1, 2]}}} =
               with(
                 {:ok, s} <- API.update_schedule("inp", input: %{"a" => {1, 2}}),
                 do: {:ok, IntegrationRepo.get!(ScheduledWorkflow, s.id)}
               )
    end
  end

  describe "console: false" do
    @describetag capture_log: false

    test "holds back the lines of a step with a time limit" do
      previous = Application.get_env(:durable, :log_capture, [])
      Application.put_env(:durable, :log_capture, Keyword.put(previous, :console, false))

      on_exit(fn ->
        Application.put_env(:durable, :log_capture, previous)
        :logger.remove_handler_filter(:default, :durable_step_lines)
      end)

      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(ChecksConsoleUnderLimit, %{})
      await_status(id, :completed)

      assert Probe.fetch(:line) == :stop
    end
  end
end
