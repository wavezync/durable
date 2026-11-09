defmodule Durable.Integration.RunControlTest do
  @moduledoc """
  Parking, stopping, starting and waking, with live pollers and the real clock.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Queue.Poller
  alias Durable.Wait.{SleepWaker, TimeoutWorker}

  alias Durable.Storage.Schemas.ScheduledWorkflow

  defmodule Quick do
    use Durable

    workflow "rc_quick" do
      step(:a, fn data ->
        Probe.here(:quick)
        {:ok, data}
      end)
    end
  end

  defmodule Flaky do
    use Durable

    workflow "rc_flaky" do
      step(:call, [retry: [max_attempts: 2, backoff: :constant, base: 1_500]], fn data ->
        if Probe.here(:flaky) == 1, do: {:error, :down}, else: {:ok, data}
      end)
    end
  end

  defmodule Attempts do
    use Durable
    use Durable.Context

    workflow "rc_attempts" do
      step(:call, [retry: [max_attempts: 3, backoff: :constant, base: 50]], fn data ->
        Probe.here({attempt(), max_attempts(), last_attempt?()})
        if last_attempt?(), do: {:ok, data}, else: {:error, :down}
      end)
    end
  end

  defmodule KeepsWrites do
    use Durable
    use Durable.Context
    use Durable.Helpers

    workflow "rc_keeps_writes" do
      step(:call, [retry: [max_attempts: 2, backoff: :constant, base: 50]], fn data ->
        Probe.here({:input, data["x"]})
        tries = (get_context(:tries) || 0) + 1
        put_context(:tries, tries)
        if tries == 1, do: {:error, :down}, else: {:ok, assign(data, :tries, tries)}
      end)
    end
  end

  defmodule RunsOutOfRetries do
    use Durable

    workflow "rc_runs_out_of_retries" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)

      step(:call, [retry: [max_attempts: 2, backoff: :constant, base: 50]], fn _data ->
        Probe.here(:call)
        {:error, :down}
      end)

      compensate(:unbook, fn data ->
        Probe.here(:unbook)
        {:ok, data}
      end)
    end
  end

  defmodule SnoozeIsFree do
    use Durable

    workflow "rc_snooze_is_free" do
      step(:call, [retry: [max_attempts: 1]], fn data ->
        if Probe.here(:snoozer) < 3, do: {:snooze, 20}, else: {:ok, data}
      end)
    end
  end

  defmodule SnoozesTooLong do
    use Durable

    workflow "rc_snoozes_too_long", timeout: 300 do
      step(:call, fn _data ->
        Probe.here(:too_long)
        {:snooze, :timer.hours(1)}
      end)
    end
  end

  defmodule Fails do
    use Durable

    workflow "rc_fails" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)

      step(:call, [retry: [max_attempts: 5]], fn _data ->
        Probe.here(:call)
        {:fail, "the file is gone"}
      end)

      compensate(:unbook, fn data ->
        Probe.here(:unbook)
        {:ok, data}
      end)
    end
  end

  defmodule Cancels do
    use Durable

    workflow "rc_cancels" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)

      step(:call, [retry: [max_attempts: 5]], fn _data ->
        Probe.here(:call)
        {:cancel, "record deleted"}
      end)

      step(:never, fn data ->
        Probe.here(:never)
        {:ok, data}
      end)

      compensate(:unbook, fn data ->
        Probe.here(:unbook)
        {:ok, data}
      end)
    end
  end

  defmodule CancelsWorkflowFromBranch do
    use Durable
    use Durable.Wait

    workflow "rc_cancels_workflow_from_branch" do
      parallel do
        step(:stops, fn _data -> {:cancel, "order withdrawn"} end)

        step(:waits, fn data ->
          wait_for_event("never")
          {:ok, data}
        end)
      end
    end
  end

  defmodule CancelsOneBranch do
    use Durable
    use Durable.Helpers

    workflow "rc_cancels_one_branch" do
      parallel on_error: :complete_all do
        step(:skipped, fn _data -> {:cancel, "nothing to send", scope: :run} end)
        step(:sent, fn data -> {:ok, assign(data, :sent, true)} end)
      end
    end
  end

  defmodule CancelsRoot do
    use Durable

    workflow "rc_cancels_root" do
      step(:work, fn _data -> {:cancel, "account closed", scope: :root} end)
    end
  end

  defmodule CallsCancelsRoot do
    use Durable
    use Durable.Orchestration

    workflow "rc_calls_cancels_root" do
      step(:call, fn data ->
        call_workflow(CancelsRoot, %{}, ref: :child)
        {:ok, data}
      end)
    end
  end

  defmodule ChildWaits do
    use Durable
    use Durable.Wait

    workflow "rc_child_waits" do
      step(:work, fn data ->
        wait_for_event("never")
        {:ok, data}
      end)
    end
  end

  defmodule CallsChildWaits do
    use Durable
    use Durable.Helpers
    use Durable.Orchestration

    workflow "rc_calls_child_waits" do
      step(:call, fn data ->
        case call_workflow(ChildWaits, %{}, ref: :child) do
          {:ok, _} -> {:ok, data}
          {:error, error} -> {:ok, assign(data, :child_error, error)}
        end
      end)
    end
  end

  defmodule Waits do
    use Durable
    use Durable.Wait

    workflow "rc_waits" do
      step(:a, fn data ->
        wait_for_event("go")
        {:ok, data}
      end)
    end
  end

  defmodule Asks do
    use Durable
    use Durable.Wait

    workflow "rc_asks" do
      step(:a, fn data ->
        wait_for_input("approve")
        {:ok, data}
      end)
    end
  end

  defmodule SleepingBranch do
    use Durable
    use Durable.Wait

    workflow "rc_sleeping_branch" do
      parallel do
        step(:sleeper, fn data ->
          sleep(1)
          Probe.here(:branch_done)
          {:ok, data}
        end)

        step(:quick, fn data ->
          Probe.here(:quick)
          {:ok, data}
        end)
      end

      step(:after_block, fn data ->
        Probe.here(:after_block)
        {:ok, data}
      end)
    end
  end

  defmodule SleepsBeforeSleepingBranch do
    use Durable
    use Durable.Wait

    workflow "rc_sleeps_before_branch" do
      step(:first, fn data ->
        sleep(1)
        {:ok, data}
      end)

      parallel do
        step(:sleeper, fn data ->
          sleep(1)
          Probe.here(:branch_done)
          {:ok, data}
        end)
      end

      step(:after_block, fn data ->
        Probe.here(:after_block)
        {:ok, data}
      end)
    end
  end

  defmodule WaitingBranch do
    use Durable
    use Durable.Wait

    workflow "rc_waiting_branch" do
      parallel do
        step(:waiter, fn data ->
          wait_for_event("go")
          Probe.here(:branch_done)
          {:ok, data}
        end)
      end

      step(:after_block, fn data ->
        Probe.here(:after_block)
        {:ok, data}
      end)
    end
  end

  defmodule ChildSleeps do
    use Durable
    use Durable.Wait

    workflow "rc_child_sleeps" do
      step(:nap, fn data ->
        sleep(1)
        {:ok, data}
      end)
    end
  end

  defmodule BranchCallsChildThatSleeps do
    use Durable
    use Durable.Orchestration

    workflow "rc_branch_calls_sleeper" do
      parallel do
        step(:caller, fn data ->
          {:ok, _result} = call_workflow(ChildSleeps, %{}, ref: :nap)
          Probe.here(:branch_done)
          {:ok, data}
        end)
      end

      step(:after_block, fn data ->
        Probe.here(:after_block)
        {:ok, data}
      end)
    end
  end

  defmodule UndoAfterBranchFails do
    use Durable

    workflow "rc_undo_after_branch_fails" do
      step(:book, [compensate: :unbook], fn data -> {:ok, Map.put(data, "booking", "B1")} end)

      parallel do
        step(:charge, fn _data -> {:fail, "declined"} end)
      end

      compensate(:unbook, fn data ->
        Probe.put(:undone_with, data["booking"] || data[:booking])
        {:ok, data}
      end)
    end
  end

  defmodule UndoAfterInputTimesOut do
    use Durable
    use Durable.Wait

    workflow "rc_undo_after_input_times_out" do
      step(:book, [compensate: :unbook], fn data -> {:ok, Map.put(data, "booking", "B1")} end)

      step(:approve, fn data ->
        wait_for_input("approve", timeout: 1, on_timeout: :fail)
        {:ok, data}
      end)

      compensate(:unbook, fn data ->
        Probe.put(:undone_with, data["booking"] || data[:booking])
        {:ok, data}
      end)
    end
  end

  defmodule UndoAfterDeadline do
    use Durable

    workflow "rc_undo_after_deadline", timeout: 100 do
      step(:book, [compensate: :unbook], fn data -> {:ok, Map.put(data, "booking", "B1")} end)
      step(:charge, [queue: :nobody], fn data -> {:ok, data} end)

      compensate(:unbook, fn data ->
        Probe.put(:undone_with, data["booking"] || data[:booking])
        {:ok, data}
      end)
    end
  end

  defmodule WaitsForAny do
    use Durable
    use Durable.Wait

    workflow "rc_waits_for_any" do
      step(:a, fn data ->
        wait_for_any(["yes", "no"])
        {:ok, data}
      end)
    end
  end

  defmodule WaitsForAll do
    use Durable
    use Durable.Wait

    workflow "rc_waits_for_all" do
      step(:a, fn data ->
        wait_for_all(["one", "two"])
        {:ok, data}
      end)
    end
  end

  defmodule FailsUntilAllowed do
    use Durable

    workflow "rc_fails_until_allowed" do
      step(:a, fn data ->
        if Probe.set?(:allow), do: {:ok, data}, else: {:error, :down}
      end)
    end
  end

  defmodule CallsQuick do
    use Durable
    use Durable.Context
    use Durable.Orchestration

    workflow "rc_calls_quick" do
      step(:call, fn data ->
        Probe.here({:parent, workflow_id()})
        call_workflow(Quick, %{}, ref: :child)
        {:ok, data}
      end)
    end
  end

  defmodule FansOut do
    use Durable

    workflow "rc_fans_out" do
      parallel do
        step(:one, fn data -> {:ok, data} end)
        step(:two, fn data -> {:ok, data} end)
      end
    end
  end

  defmodule WideFanOut do
    use Durable

    workflow "rc_wide_fan_out" do
      parallel do
        step(:b01, fn data -> {:ok, data} end)
        step(:b02, fn data -> {:ok, data} end)
        step(:b03, fn data -> {:ok, data} end)
        step(:b04, fn data -> {:ok, data} end)
        step(:b05, fn data -> {:ok, data} end)
        step(:b06, fn data -> {:ok, data} end)
        step(:b07, fn data -> {:ok, data} end)
        step(:b08, fn data -> {:ok, data} end)
        step(:b09, fn data -> {:ok, data} end)
        step(:b10, fn data -> {:ok, data} end)
        step(:b11, fn data -> {:ok, data} end)
        step(:b12, fn data -> {:ok, data} end)
      end

      step(:after_fan, fn data ->
        Probe.here(:after_fan)
        {:ok, data}
      end)
    end
  end

  defmodule ChildFails do
    use Durable

    workflow "rc_child_fails" do
      step(:work, fn _data -> {:fail, "no good"} end)
    end
  end

  defmodule ChildCancels do
    use Durable

    workflow "rc_child_cancels" do
      step(:work, fn _data -> {:cancel, "not needed"} end)
    end
  end

  defmodule ChildCompensates do
    use Durable

    workflow "rc_child_compensates" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
      step(:charge, fn _data -> {:fail, "card declined"} end)
      compensate(:unbook, fn data -> {:ok, data} end)
    end
  end

  defmodule ChildCompensationFails do
    use Durable

    workflow "rc_child_compensation_fails" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
      step(:charge, fn _data -> {:fail, "card declined"} end)
      compensate(:unbook, fn _data -> raise "still booked" end)
    end
  end

  defmodule ChildCompensationErrors do
    use Durable

    workflow "rc_child_compensation_errors" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
      step(:charge, fn _data -> {:fail, "card declined"} end)

      compensate(:unbook, [retry: [max_attempts: 2, backoff: :constant, base: 1]], fn _data ->
        {:error, {:still_booked, self()}}
      end)
    end
  end

  defmodule Holds do
    @moduledoc false
    # Locks the parent's row from before the child exists until the test says
    # so: the parent can't start waiting, and the child finishes first.

    def parent_row(id) do
      me = self()

      spawn(fn ->
        IntegrationRepo.transaction(fn ->
          IntegrationRepo.query!(
            "SELECT 1 FROM durable.workflow_executions WHERE id = $1 FOR NO KEY UPDATE",
            [Ecto.UUID.dump!(id)]
          )

          send(me, :row_locked)
          Probe.wait_for(:parent_released)
        end)
      end)

      receive do
        :row_locked -> :ok
      end
    end
  end

  defmodule ParentHeldUp do
    use Durable
    use Durable.Context
    use Durable.Helpers
    use Durable.Orchestration

    workflow "rc_parent_held_up" do
      step(:call, fn data ->
        unless Probe.set?(:parent_released), do: Holds.parent_row(workflow_id())

        case call_workflow(String.to_existing_atom(data[:child] || data["child"]), %{},
               ref: :child
             ) do
          {:ok, _} -> {:ok, assign(data, :child_ok, true)}
          {:error, error} -> {:ok, assign(data, :child_error, error)}
        end
      end)
    end
  end

  defmodule CallsChild do
    use Durable
    use Durable.Helpers
    use Durable.Orchestration

    workflow "rc_calls_child" do
      step(:call, fn data ->
        case call_workflow(String.to_existing_atom(data[:child] || data["child"]), %{},
               ref: :child
             ) do
          {:ok, _} -> {:ok, assign(data, :child_ok, true)}
          {:error, error} -> {:ok, assign(data, :child_error, error)}
        end
      end)
    end
  end

  defmodule FiresAndForgets do
    use Durable
    use Durable.Orchestration

    workflow "rc_fires_and_forgets" do
      step(:fire, fn data ->
        {:ok, _child} = start_workflow(Quick, %{}, ref: :fired)
        {:ok, data}
      end)
    end
  end

  defmodule ParkedInBranch do
    use Durable
    use Durable.Helpers

    workflow "rc_parked_in_branch" do
      parallel do
        step(:flaky, [retry: [max_attempts: 2, backoff: :constant, base: 100]], fn data ->
          if Probe.here(:branch_flaky) == 1, do: {:error, :down}, else: {:ok, data}
        end)

        step(:steady, fn data -> {:ok, data} end)
      end

      step(:after_block, fn data ->
        Probe.here(:after_block)
        {:ok, data}
      end)
    end
  end

  defmodule LongRetry do
    use Durable

    workflow "rc_long_retry" do
      step(:call, [retry: [max_attempts: 2, backoff: :constant, base: :timer.hours(1)]], fn _ ->
        Probe.here(:long_retry)
        {:error, :down}
      end)
    end
  end

  defmodule Held do
    use Durable

    workflow "rc_held" do
      step(:a, fn data ->
        Probe.here(:held)
        Probe.wait_for({:go, Probe.hits(:held)})
        {:ok, data}
      end)
    end
  end

  # Holds every run for half a second as it becomes :waiting.
  defp slow_wait! do
    IntegrationRepo.query!("""
    CREATE FUNCTION durable.slow_wait() RETURNS trigger AS $$
    BEGIN PERFORM pg_sleep(0.5); RETURN NEW; END;
    $$ LANGUAGE plpgsql
    """)

    IntegrationRepo.query!("""
    CREATE TRIGGER slow_wait BEFORE UPDATE ON durable.workflow_executions
    FOR EACH ROW WHEN (OLD.status = 'running' AND NEW.status = 'waiting')
    EXECUTE FUNCTION durable.slow_wait()
    """)

    on_exit(fn -> IntegrationRepo.query!("DROP FUNCTION durable.slow_wait() CASCADE") end)
  end

  # Runs `fun` in a transaction that stays open a while after it, so a wake
  # sent from inside has every chance to arrive before the commit.
  defp in_slow_transaction(fun) do
    IntegrationRepo.transaction(fn ->
      result = fun.()
      Process.sleep(200)
      result
    end)
  end

  defp start!(workflow, input \\ %{}, opts \\ []) do
    {:ok, id} = Durable.start(workflow, input, opts)
    id
  end

  defp children_of(id) do
    IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^id))
  end

  defp attempts_of(id) do
    IntegrationRepo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^id,
        order_by: [asc: s.inserted_at],
        select: {s.attempt, s.status}
      )
    )
  end

  describe "parking with the real clock" do
    setup do
      start_durable!(%{default: 1})
      :ok
    end

    test "a retry's backoff leaves the slot free for another run" do
      flaky = start!(Flaky)
      assert_eventually(fn -> Probe.hits(:flaky) == 1 end)
      quick = start!(Quick)

      # Sooner than the backoff can end (1.5 s, less 25% jitter).
      await_status(quick, :completed, 800)
      assert Probe.hits(:flaky) == 1
      assert get(flaky).status == :pending

      await_status(flaky, :completed)
      assert Enum.map(Probe.trail(), &elem(&1, 0)) == [:flaky, :quick, :flaky]
    end

    test "attempts count up across workers" do
      id = start!(Attempts)

      await_status(id, :completed)

      assert Enum.map(Probe.trail(), &elem(&1, 0)) == [
               {1, 3, false},
               {2, 3, false},
               {3, 3, true}
             ]
    end

    test "a retry keeps the first step's input keys and put_context writes" do
      id = start!(KeepsWrites, %{"x" => 7})

      run = await_status(id, :completed)

      assert Enum.map(Probe.trail(), &elem(&1, 0)) == [{:input, 7}, {:input, 7}]
      assert run.context["tries"] == 2
    end

    test "running out of retries fails the step and compensates" do
      id = start!(RunsOutOfRetries)

      await_status(id, :compensated)
      assert Probe.hits(:call) == 2
      assert Probe.hits(:unbook) == 1
    end

    test "a snooze doesn't use an attempt" do
      id = start!(SnoozeIsFree)

      await_status(id, :completed)
      assert Probe.hits(:snoozer) == 3
      assert attempts_of(id) == [{1, :snoozed}, {1, :snoozed}, {1, :completed}]
    end

    test "a snooze past the workflow's timeout comes back at the deadline and fails" do
      id = start!(SnoozesTooLong)

      run = await_status(id, :failed, 5_000)
      assert run.error["type"] == "timeout"
      assert Probe.hits(:too_long) == 1
    end

    test "a parked retry in a parallel branch comes back, and the block finishes" do
      id = start!(ParkedInBranch)

      await_status(id, :completed)
      assert Probe.hits(:branch_flaky) == 2
      assert Probe.hits(:after_block) == 1
    end
  end

  describe "stopping from a step" do
    setup do
      start_durable!(%{default: 5})
      :ok
    end

    test "{:fail, reason} skips the retries and compensates" do
      id = start!(Fails)

      run = await_status(id, :compensated)
      assert run.error["message"] == "the file is gone"
      assert Probe.hits(:call) == 1
      assert Probe.hits(:unbook) == 1
    end

    test "{:cancel, reason} skips the retries, the next steps and compensations" do
      id = start!(Cancels)

      run = await_status(id, :cancelled)
      assert run.error["message"] == "record deleted"
      assert Probe.hits(:call) == 1
      assert Probe.hits(:never) == 0
      assert Probe.hits(:unbook) == 0
    end

    test "{:cancel, reason} in a parallel step cancels the workflow and its other branches" do
      id = start!(CancelsWorkflowFromBranch)

      await_status(id, :cancelled)
      assert_eventually(fn -> Enum.all?(children_of(id), &(&1.status == :cancelled)) end)
    end

    test "scope: :run cancels only that branch" do
      id = start!(CancelsOneBranch)

      run = await_status(id, :completed)
      assert %{"skipped" => ["error", _], "sent" => ["ok", _]} = run.context["__results__"]
    end

    test "scope: :root cancels the top of the tree from a child" do
      id = start!(CallsCancelsRoot)

      run = await_status(id, :cancelled)
      assert run.error["message"] == "account closed"
      assert_eventually(fn -> Enum.all?(children_of(id), &(&1.status == :cancelled)) end)
    end

    test "cancelling a child hands the waiting parent an error" do
      id = start!(CallsChildWaits)
      assert_eventually(fn -> match?([%{status: :waiting}], children_of(id)) end)

      [child] = children_of(id)
      :ok = Durable.cancel(child.id, "not needed")

      run = await_status(id, :completed)
      assert run.context["child_error"]["message"] == "not needed"
    end

    test "cancel_all by tag stops running, parked and waiting runs, and parked ones stay stopped" do
      parked = start!(LongRetry, %{}, tags: ["account:7"])
      assert_eventually(fn -> get(parked).status == :pending and Probe.hits(:long_retry) == 1 end)

      waiting = start!(Waits, %{}, tags: ["account:7"])
      assert_eventually(fn -> get(waiting).status == :waiting end)

      other = start!(Waits, %{}, tags: ["account:8"])
      assert_eventually(fn -> get(other).status == :waiting end)

      assert {:ok, 2} = Durable.cancel_all([tag: "account:7"], "closing the account")

      assert get(parked).status == :cancelled
      assert get(waiting).status == :cancelled
      assert get(other).status == :waiting

      Process.sleep(150)
      assert Probe.hits(:long_retry) == 1
    end
  end

  describe "starting" do
    setup do
      start_durable!(%{default: 5})
      :ok
    end

    test "Durable.start/3 rolls back with the transaction around it" do
      {:error, :nope} =
        IntegrationRepo.transaction(fn ->
          {:ok, _id} = Durable.start(Quick, %{})
          IntegrationRepo.rollback(:nope)
        end)

      Process.sleep(200)
      assert IntegrationRepo.aggregate(WorkflowExecution, :count) == 0
      assert Probe.hits(:quick) == 0
    end

    test "Durable.start/3 in a transaction runs only once it commits" do
      test_pid = self()

      committer =
        Task.async(fn ->
          IntegrationRepo.transaction(fn ->
            {:ok, id} = Durable.start(Quick, %{})
            send(test_pid, {:started, id})
            Process.sleep(300)
          end)
        end)

      assert_receive {:started, id}, 2_000
      Process.sleep(150)
      assert Probe.hits(:quick) == 0

      Task.await(committer)
      await_status(id, :completed)
      assert Probe.hits(:quick) == 1
    end

    test "start_many/2 starts every run" do
      results = Durable.start_many([{Quick, %{}}, {Quick, %{}}, {Quick, %{}}])

      for {:ok, id} <- results, do: await_status(id, :completed)
      assert length(results) == 3
      assert Probe.hits(:quick) == 3
    end

    test "start_many/2 is all or nothing when one item blows up" do
      assert_raise FunctionClauseError, fn ->
        Durable.start_many([{Quick, %{}}, :not_an_item])
      end

      Process.sleep(200)
      assert IntegrationRepo.aggregate(WorkflowExecution, :count) == 0
      assert Probe.hits(:quick) == 0
    end
  end

  describe "with a poll interval too long to help" do
    setup do
      start_durable!(%{default: 5}, poll_interval: :timer.hours(1))

      # Let the first poll, at start, go by.
      Process.sleep(150)
      :ok
    end

    test "a start is claimed at once" do
      id = start!(Quick)
      await_status(id, :completed, 3_000)
    end

    test "start_many/2 is claimed at once" do
      [{:ok, one}, {:ok, two}] = Durable.start_many([{Quick, %{}}, {Quick, %{}}])

      await_status(one, :completed, 3_000)
      await_status(two, :completed, 3_000)
    end

    test "start_many/2 wakes the pollers after its commit, however slow the commit is" do
      IntegrationRepo.query!("""
      CREATE FUNCTION durable.slow_commit() RETURNS trigger AS $$
      BEGIN PERFORM pg_sleep(0.3); RETURN NULL; END;
      $$ LANGUAGE plpgsql
      """)

      IntegrationRepo.query!("""
      CREATE CONSTRAINT TRIGGER slow_commit AFTER INSERT ON durable.workflow_executions
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION durable.slow_commit()
      """)

      on_exit(fn -> IntegrationRepo.query!("DROP FUNCTION durable.slow_commit() CASCADE") end)

      [{:ok, one}, {:ok, two}] = Durable.start_many([{Quick, %{}}, {Quick, %{}}])

      await_status(one, :completed, 3_000)
      await_status(two, :completed, 3_000)
    end

    test "a start inside a transaction is claimed when it commits" do
      {:ok, id} = in_slow_transaction(fn -> start!(Quick) end)
      await_status(id, :completed, 3_000)
    end

    test "start_many/2 inside a transaction is claimed when it commits" do
      {:ok, [{:ok, one}, {:ok, two}]} =
        in_slow_transaction(fn -> Durable.start_many([{Quick, %{}}, {Quick, %{}}]) end)

      await_status(one, :completed, 3_000)
      await_status(two, :completed, 3_000)
    end

    test "an event sent inside a transaction resumes the run when it commits" do
      id = start!(Waits)
      assert_eventually(fn -> get(id).status == :waiting end)

      {:ok, :ok} = in_slow_transaction(fn -> Durable.send_event(id, "go", %{}) end)
      await_status(id, :completed, 3_000)
    end

    test "input given inside a transaction resumes the run when it commits" do
      id = start!(Asks)
      assert_eventually(fn -> get(id).status == :waiting end)

      {:ok, :ok} = in_slow_transaction(fn -> Durable.provide_input(id, "approve", %{}) end)
      await_status(id, :completed, 3_000)
    end

    test "a buffered event wakes the pollers after its commit, however slow the commit is" do
      id = start!(Waits)
      assert_eventually(fn -> get(id).status == :waiting end)

      IntegrationRepo.query!("""
      CREATE FUNCTION durable.slow_commit() RETURNS trigger AS $$
      BEGIN PERFORM pg_sleep(0.3); RETURN NULL; END;
      $$ LANGUAGE plpgsql
      """)

      IntegrationRepo.query!("""
      CREATE CONSTRAINT TRIGGER slow_commit AFTER UPDATE ON durable.workflow_executions
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.status = 'pending')
      EXECUTE FUNCTION durable.slow_commit()
      """)

      on_exit(fn -> IntegrationRepo.query!("DROP FUNCTION durable.slow_commit() CASCADE") end)

      :ok = Durable.send_event(id, "go", %{}, buffer: true)
      await_status(id, :completed, 3_000)
    end

    test "a transaction that rolls back wakes nobody" do
      test_pid = self()
      handler = "rollback-wake-#{System.unique_integer()}"

      :telemetry.attach(
        handler,
        [:durable, :queue, :poll],
        fn _event, _measurements, _meta, _config -> send(test_pid, :polled) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:error, :changed_my_mind} =
        IntegrationRepo.transaction(fn ->
          start!(Quick)
          IntegrationRepo.rollback(:changed_my_mind)
        end)

      refute_receive :polled, 300
      assert Probe.hits(:quick) == 0
    end

    test "an event resumes a waiting run at once" do
      id = start!(Waits)
      assert_eventually(fn -> get(id).status == :waiting end)

      :ok = Durable.send_event(id, "go", %{})
      await_status(id, :completed, 3_000)
    end

    test "an input resumes a waiting run at once" do
      id = start!(Asks)
      assert_eventually(fn -> get(id).status == :waiting end)

      :ok = Durable.provide_input(id, "approve", %{})
      await_status(id, :completed, 3_000)
    end

    test "Durable.retry/2 is claimed at once" do
      id = start!(FailsUntilAllowed)
      await_status(id, :failed, 3_000)

      :ok = Probe.set(:allow)
      {:ok, ^id} = Durable.retry(id)
      await_status(id, :completed, 3_000)
    end

    test "a finished child resumes its parent at once" do
      id = start!(CallsQuick)
      await_status(id, :completed, 3_000)
    end

    test "a fire-and-forget child is claimed at once" do
      id = start!(FiresAndForgets)
      await_status(id, :completed, 3_000)
      assert_eventually(fn -> Probe.hits(:quick) == 1 end, 3_000)
    end

    test "the last branch of a parallel block resumes its parent at once" do
      id = start!(FansOut)
      await_status(id, :completed, 3_000)
    end
  end

  describe "a child that finishes as fast as it's claimed" do
    setup do
      start_durable!(%{default: 20}, poll_interval: 1)
      :ok
    end

    defp assert_all_completed(ids) do
      assert_eventually(
        fn ->
          IntegrationRepo.aggregate(
            from(w in WorkflowExecution, where: w.id in ^ids and w.status == :completed),
            :count
          ) == length(ids)
        end,
        20_000,
        50
      )
    end

    test "is never missed by the parent calling it" do
      ids = for _ <- 1..60, do: start!(CallsQuick)
      assert_all_completed(ids)

      # Once to call, once with the result: resumed one time, whichever of the
      # child's notice and the parent's own check got there first.
      for id <- ids, do: assert(Probe.hits({:parent, id}) == 2)
    end

    test "is not missed when it ends between its parent's event and its waiting" do
      slow_wait!()

      id = start!(CallsQuick)
      await_status(id, :completed, 5_000)
    end

    test "is never missed by a parallel block" do
      ids = for _ <- 1..60, do: start!(FansOut)
      assert_all_completed(ids)
    end

    test "is never missed by a wide parallel block, however early it finishes" do
      ids = for _ <- 1..20, do: start!(WideFanOut)
      assert_all_completed(ids)
      assert Probe.hits(:after_fan) == 20
    end

    for {child, status, check} <- [
          {Quick, :completed, :ok},
          {ChildFails, :failed, "no good"},
          {ChildCancels, :cancelled, "not needed"},
          {ChildCompensates, :compensated, "card declined"},
          {ChildCompensationFails, :compensation_failed, "card declined"}
        ] do
      test "ending #{status} before its parent has started waiting isn't missed" do
        child = to_string(unquote(child))
        id = start!(ParentHeldUp, %{"child" => child})

        assert_eventually(fn -> match?([%{status: unquote(status)}], children_of(id)) end)
        assert get(id).status == :running
        :ok = Probe.set(:parent_released)

        run = await_status(id, :completed)

        case unquote(check) do
          :ok -> assert run.context["child_ok"] == true
          message -> assert run.context["child_error"]["message"] == message
        end
      end
    end

    for {child, status, message} <- [
          {ChildFails, :failed, "no good"},
          {ChildCancels, :cancelled, "not needed"},
          {ChildCompensates, :compensated, "card declined"},
          {ChildCompensationFails, :compensation_failed, "card declined"}
        ] do
      test "ending #{status} hands the waiting parent an error" do
        id = start!(CallsChild, %{"child" => to_string(unquote(child))})

        run = await_status(id, :completed)
        assert [%{status: unquote(status)}] = children_of(id)
        assert run.context["child_error"]["message"] == unquote(message)
      end
    end

    test "a compensation that returns an error fails the child, and the parent hears the first error" do
      id = start!(CallsChild, %{"child" => to_string(ChildCompensationErrors)})

      run = await_status(id, :completed)
      assert [child] = children_of(id)
      assert child.status == :compensation_failed

      assert [%{"result" => %{"status" => "failed", "error" => %{"message" => message}}}] =
               child.compensation_results

      assert message =~ ":still_booked"
      assert run.context["child_error"]["message"] == "card declined"
    end
  end

  describe "the listener behind commit-time wakes" do
    defmodule DownRepo do
      @moduledoc false
      use Ecto.Repo, otp_app: :durable, adapter: Ecto.Adapters.Postgres
    end

    test "doesn't stop Durable booting while Postgres is down" do
      Application.put_env(:durable, DownRepo,
        hostname: "localhost",
        port: 1,
        username: "postgres",
        password: "postgres",
        database: "nope",
        pool_size: 1
      )

      start_supervised!(DownRepo)

      assert {:ok, _} =
               start_supervised(
                 {Durable, repo: DownRepo, name: DownInstance, queues: queue_opts(%{default: 1})}
               )

      listener = Process.whereis(DownInstance.Queue.Notifications)
      poller = Process.whereis(DownInstance.Queue.Poller.Default)

      # Long enough for many polls and a failed reconnect.
      Process.sleep(2_500)

      assert Process.whereis(DownInstance.Queue.Notifications) == listener
      assert Process.whereis(DownInstance.Queue.Poller.Default) == poller
    end

    test "comes back after Postgres drops its connection" do
      start_durable!(%{default: 5}, poll_interval: :timer.hours(1))
      Process.sleep(150)

      [[old_pid]] = listener_pids()
      IntegrationRepo.query!("SELECT pg_terminate_backend($1)", [old_pid])
      assert_eventually(fn -> match?([[pid]] when pid != old_pid, listener_pids()) end, 8_000, 50)

      {:ok, id} = in_slow_transaction(fn -> start!(Quick) end)
      await_status(id, :completed, 3_000)
    end

    defp listener_pids do
      IntegrationRepo.query!("""
      SELECT pid FROM pg_stat_activity
      WHERE datname = current_database() AND query LIKE '%LISTEN "%' AND pid <> pg_backend_pid()
      """).rows
    end

    test "gone for good, leaves the run to the next poll" do
      start_durable!(%{default: 5}, poll_interval: 300)

      :ok =
        Supervisor.terminate_child(Durable.Queue.Manager, Postgrex.Notifications)

      {:ok, id} = in_slow_transaction(fn -> start!(Quick) end)
      await_status(id, :completed, 3_000)
    end

    test "fits a queue name longer than a Postgres channel can be" do
      long = String.duplicate("q", 100)
      start_durable!(%{String.to_atom(long) => 2}, poll_interval: :timer.hours(1))
      Process.sleep(150)

      {:ok, id} = in_slow_transaction(fn -> start!(Quick, %{}, queue: long) end)
      await_status(id, :completed, 3_000)
    end

    test "uses a channel per queue and per prefix" do
      config = Durable.Config.get(Durable)
      channel = &Durable.PubSub.wake_channel/2

      assert channel.(config, "a") != channel.(config, "b")
      assert channel.(config, "a") != channel.(%{config | prefix: "other"}, "a")
    end
  end

  describe "with no PubSub and a poll interval too long to help" do
    setup do
      start_durable!(%{default: 5}, poll_interval: :timer.hours(1), pubsub: nil)
      Process.sleep(150)
      :ok
    end

    test "a start inside a transaction is still claimed when it commits" do
      {:ok, id} = in_slow_transaction(fn -> start!(Quick) end)
      await_status(id, :completed, 3_000)
    end
  end

  describe "two things answering the same wait" do
    setup do
      start_durable!(%{default: 5})
      :ok
    end

    test "don't deadlock when one holds the run's row and is about to touch the event" do
      id = start!(Waits)
      assert_eventually(fn -> get(id).status == :waiting end)

      holder =
        Task.async(fn ->
          IntegrationRepo.transaction(fn ->
            IntegrationRepo.one(
              from(w in WorkflowExecution, where: w.id == ^id, lock: "FOR UPDATE", select: w.id)
            )

            Process.sleep(300)
            IntegrationRepo.update_all(Durable.Storage.Schemas.PendingEvent, set: [payload: %{}])
          end)
        end)

      Process.sleep(100)
      assert Durable.send_event(id, "go", %{}) == :ok
      assert {:ok, _} = Task.await(holder)
      await_status(id, :completed, 3_000)
    end
  end

  describe "a poller's slots" do
    test "aren't freed for a run claimed again before its last worker reported" do
      start_durable!(%{default: 2}, poll_interval: :timer.hours(1))
      poller = Process.whereis(Durable.Queue.Poller.Default)

      id = start!(Held)
      assert_eventually(fn -> Probe.hits(:held) == 1 end)

      earlier = spawn(fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(earlier)

      :sys.replace_state(poller, fn state ->
        put_in(state.workers[earlier], %{ref: ref, job_id: id, token: nil})
      end)

      assert Poller.status(poller).active_jobs == 2

      send(poller, {:job_complete, earlier, id, :waiting, 1})

      assert Poller.status(poller).active_jobs == 1
      :ok = Probe.set({:go, 1})
      await_status(id, :completed, 3_000)
    end
  end

  describe "a parallel branch that waits" do
    setup do
      start_durable!(%{default: 5})
      :ok
    end

    defp finish_with_waker(id) do
      assert_eventually(
        fn ->
          SleepWaker.wake_now(Durable)
          get(id).status == :completed
        end,
        8_000,
        20
      )
    end

    test "that sleeps runs only its own step, and what follows runs once" do
      id = start!(SleepingBranch)
      finish_with_waker(id)

      assert Probe.hits(:branch_done) == 1
      assert Probe.hits(:quick) == 1
      assert Probe.hits(:after_block) == 1
    end

    test "that sleeps after an earlier step slept finishes" do
      id = start!(SleepsBeforeSleepingBranch)
      finish_with_waker(id)

      assert Probe.hits(:branch_done) == 1
      assert Probe.hits(:after_block) == 1
    end

    test "that waits for an event gets it, and what follows runs once" do
      id = start!(WaitingBranch)
      assert_eventually(fn -> match?([%{status: :waiting}], children_of(id)) end)

      [branch] = children_of(id)
      assert Durable.send_event(branch.id, "go", %{}) == :ok
      await_status(id, :completed, 5_000)

      assert Probe.hits(:branch_done) == 1
      assert Probe.hits(:after_block) == 1
    end

    test "that calls a child which sleeps finishes" do
      id = start!(BranchCallsChildThatSleeps)
      finish_with_waker(id)

      assert Probe.hits(:branch_done) == 1
      assert Probe.hits(:after_block) == 1
    end
  end

  describe "a compensation after a run fails as it resumes" do
    setup do
      start_durable!(%{default: 5})
      :ok
    end

    test "has the run's data when a parallel branch failed" do
      id = start!(UndoAfterBranchFails)
      await_status(id, :compensated, 5_000)
      assert Probe.fetch(:undone_with) == "B1"
    end

    test "has the run's data when an input timed out" do
      id = start!(UndoAfterInputTimesOut)
      assert_eventually(fn -> get(id).status == :waiting end)
      Process.sleep(5)
      TimeoutWorker.check_timeouts(Durable)

      await_status(id, :compensated, 5_000)
      assert Probe.fetch(:undone_with) == "B1"
    end

    test "has the run's data when it ran out of time" do
      id = start!(UndoAfterDeadline)
      assert_eventually(fn -> get(id).queue == "nobody" end)
      Process.sleep(150)
      TimeoutWorker.check_timeouts(Durable)

      await_status(id, :compensated, 5_000)
      assert Probe.fetch(:undone_with) == "B1"
    end
  end

  describe "going into a wait" do
    setup do
      start_durable!(%{default: 5})
      slow_wait!()
      :ok
    end

    # Refused while the run isn't waiting yet, accepted once it is.
    defp until_accepted(send), do: assert_eventually(fn -> send.() == :ok end, 5_000, 10)

    test "an event sent meanwhile is refused or delivered, never swallowed" do
      id = start!(Waits)
      until_accepted(fn -> Durable.send_event(id, "go", %{}) end)
      await_status(id, :completed, 5_000)
    end

    test "an input given meanwhile is refused or delivered, never swallowed" do
      id = start!(Asks)
      until_accepted(fn -> Durable.provide_input(id, "approve", %{}) end)
      await_status(id, :completed, 5_000)
    end

    test "wait_for_any gets an event sent meanwhile" do
      id = start!(WaitsForAny)
      until_accepted(fn -> Durable.send_event(id, "yes", %{}) end)
      await_status(id, :completed, 5_000)
    end

    test "wait_for_all gets events sent meanwhile" do
      id = start!(WaitsForAll)
      until_accepted(fn -> Durable.send_event(id, "one", %{}) end)
      until_accepted(fn -> Durable.send_event(id, "two", %{}) end)
      await_status(id, :completed, 5_000)
    end

    test "a buffered event sent meanwhile is delivered" do
      id = start!(Waits)
      Process.sleep(100)
      assert :ok = Durable.send_event(id, "go", %{}, buffer: true)
      await_status(id, :completed, 5_000)
    end
  end

  describe "cron with a key" do
    setup do
      start_durable!(%{default: 5}, scheduler_interval: 50)
      :ok
    end

    defp due_now(name) do
      past = DateTime.add(DateTime.utc_now(), -5, :second)

      {1, _} =
        IntegrationRepo.update_all(
          from(s in ScheduledWorkflow, where: s.name == ^name),
          set: [next_run_at: past]
        )
    end

    test "a fire while the last run is going starts nothing, and the next one runs" do
      {:ok, _} = Durable.schedule(Held, "* * * * *", name: "only_one", key: "only-one")

      due_now("only_one")
      assert_eventually(fn -> Probe.hits(:held) == 1 end)
      [first] = IntegrationRepo.all(WorkflowExecution)

      due_now("only_one")

      assert_eventually(fn ->
        IntegrationRepo.one(from(s in ScheduledWorkflow, select: s.next_run_at))
        |> DateTime.after?(DateTime.utc_now())
      end)

      Process.sleep(100)
      assert IntegrationRepo.aggregate(WorkflowExecution, :count) == 1

      :ok = Probe.set({:go, 1})
      await_status(first.id, :completed)

      due_now("only_one")
      assert_eventually(fn -> Probe.hits(:held) == 2 end)
      :ok = Probe.set({:go, 2})

      assert_eventually(fn ->
        IntegrationRepo.aggregate(
          from(w in WorkflowExecution, where: w.status == :completed),
          :count
        ) == 2
      end)
    end
  end
end
