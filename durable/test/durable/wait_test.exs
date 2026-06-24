defmodule Durable.WaitTest do
  @moduledoc """
  Comprehensive tests for wait primitives.

  Tests cover:
  - Pause primitives (sleep, schedule_at)
  - Event waiting (wait_for_event, wait_for_any, wait_for_all)
  - Human input (wait_for_input and convenience wrappers)
  - External API (provide_input, send_event, cancel_wait)
  - TimeoutWorker behavior
  - Time helpers
  - Query API
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WaitGroup, WorkflowExecution}
  alias Durable.Wait

  import Ecto.Query

  # The SleepWaker keys off `scheduled_at <= clock_timestamp()` (real wall
  # clock). A `sleep(1)` schedules only 1ms out, which races the
  # immediately-following wake in a warm full-suite run and makes these tests
  # flaky (sometimes `woken == 0`). Back-dating the row's scheduled_at makes
  # the elapsed condition deterministically true without changing what the
  # test exercises (the wake -> resume mechanism).
  defp force_sleep_elapsed!(repo, workflow_id) do
    repo.update_all(
      from(w in WorkflowExecution, where: w.id == ^workflow_id and w.status == :waiting),
      set: [scheduled_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    :ok
  end

  # ============================================================================
  # Pause Primitives Tests
  # ============================================================================

  describe "sleep/1" do
    test "suspends workflow with duration_ms" do
      {:ok, execution} = create_and_execute_workflow(SleepTestWorkflow, %{})

      assert execution.status == :waiting
      assert execution.context["before"] == true
    end

    test "sets scheduled_at to correct future time" do
      config = Config.get(Durable)
      repo = config.repo
      before = DateTime.utc_now()

      {:ok, execution} = create_and_execute_workflow(SleepTestWorkflow, %{})

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.scheduled_at != nil

      # scheduled_at should be ~30 seconds in the future (30_000 ms from seconds(30))
      diff_ms = DateTime.diff(execution.scheduled_at, before, :millisecond)
      assert diff_ms >= 29_000 and diff_ms <= 31_000
    end

    test "clears the lock when suspending" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(SleepTestWorkflow, %{})

      execution = repo.get!(WorkflowExecution, execution.id)
      # The waker depends on a clear lock — without this guarantee a
      # stale `locked_by` from the worker that suspended the row would
      # keep it invisible to fetch_jobs after the wake.
      assert execution.locked_by == nil
      assert execution.locked_at == nil
    end
  end

  describe "schedule_at/1" do
    test "suspends workflow until specific datetime" do
      {:ok, execution} = create_and_execute_workflow(ScheduleAtTestWorkflow, %{})

      assert execution.status == :waiting
      assert execution.context["before"] == true
    end

    test "sets scheduled_at to the provided datetime" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(ScheduleAtTestWorkflow, %{})

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.scheduled_at != nil

      # The workflow schedules for next_business_day at hour 9
      assert execution.scheduled_at.hour == 9
      assert execution.scheduled_at.minute == 0
    end
  end

  # ============================================================================
  # Sleep wake-up (full lifecycle: suspend -> waker -> resume -> complete)
  # ============================================================================

  describe "sleep + waker resumption" do
    alias Durable.Queue.Adapter
    alias Durable.Wait.SleepWaker

    test "sweeper flips elapsed sleep back to :pending and writes marker" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(ShortSleepWorkflow, %{})
      assert execution.status == :waiting
      force_sleep_elapsed!(repo, execution.id)

      adapter = Adapter.default_adapter()
      {:ok, woken} = adapter.wake_sleeping_workflows(config, 100)
      assert woken == 1

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :pending
      assert execution.locked_by == nil
      assert execution.locked_at == nil
      assert execution.context["__sleep_satisfied__"] == "sleep_step"
    end

    test "resuming after wake completes the workflow past the sleep" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(ShortSleepWorkflow, %{})
      assert execution.status == :waiting
      force_sleep_elapsed!(repo, execution.id)

      Adapter.default_adapter().wake_sleeping_workflows(config, 100)

      # Drive the resumed workflow synchronously, the way the queue
      # poller would after fetch_jobs claims the now-:pending row.
      Durable.Executor.execute_workflow(execution.id, config)

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :completed
      assert execution.context["before"] == true
      assert execution.context["slept"] == true
      assert execution.context["completed"] == true
    end

    test "schedule_at resumes the same way as sleep" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(ShortScheduleAtWorkflow, %{})
      assert execution.status == :waiting

      Adapter.default_adapter().wake_sleeping_workflows(config, 100)
      Durable.Executor.execute_workflow(execution.id, config)

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :completed
      assert execution.context["scheduled"] == true
    end

    test "two sequential sleep steps both wake correctly" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(TwoSleepWorkflow, %{})
      assert execution.status == :waiting
      force_sleep_elapsed!(repo, execution.id)

      Adapter.default_adapter().wake_sleeping_workflows(config, 100)
      Durable.Executor.execute_workflow(execution.id, config)
      execution = repo.get!(WorkflowExecution, execution.id)
      # Suspended again at the second sleep. The first sleep's marker was
      # dropped the moment :first_sleep completed (one-shot), so it does not
      # linger into the second suspension.
      assert execution.status == :waiting
      assert execution.context["first_done"] == true
      assert execution.context["__sleep_satisfied__"] == nil

      force_sleep_elapsed!(repo, execution.id)
      Adapter.default_adapter().wake_sleeping_workflows(config, 100)
      Durable.Executor.execute_workflow(execution.id, config)

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :completed
      assert execution.context["second_done"] == true
      # One-shot marker: once its consuming step completes the marker is
      # removed, so the finished workflow carries no `__sleep_satisfied__`.
      # (A lingering marker would make a loop/`each` re-entry of the same
      # sleep step skip its sleep.)
      assert execution.context["__sleep_satisfied__"] == nil
    end

    test "the sweep is a no-op when no rows are eligible" do
      config = Config.get(Durable)
      adapter = Adapter.default_adapter()

      assert {:ok, 0} = adapter.wake_sleeping_workflows(config, 100)
    end

    test "a sleep followed by an event-wait is NOT prematurely re-woken (scheduled_at cleared)" do
      # Regression for the critical bug: scheduled_at was never cleared once a
      # sleep woke, so when the *next* step suspended on an event the stale
      # scheduled_at matched the SleepWaker query and the row was flipped
      # :waiting -> :pending every tick, churning status and piling up
      # duplicate PendingEvent rows.
      config = Config.get(Durable)
      repo = config.repo
      adapter = Adapter.default_adapter()

      {:ok, execution} = create_and_execute_workflow(SleepThenEventWorkflow, %{})
      assert execution.status == :waiting
      assert execution.scheduled_at != nil
      force_sleep_elapsed!(repo, execution.id)

      # Wake the sleep and resume — the workflow runs :nap, then suspends on
      # the "go" event in :await.
      assert {:ok, 1} = adapter.wake_sleeping_workflows(config, 100)
      Durable.Executor.execute_workflow(execution.id, config)

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :waiting
      assert execution.context["napped"] == true
      # The event-wait suspension must clear scheduled_at so the SleepWaker
      # leaves the row alone.
      assert execution.scheduled_at == nil

      pending_count = fn ->
        repo.aggregate(
          from(p in PendingEvent, where: p.workflow_id == ^execution.id and p.status == :pending),
          :count
        )
      end

      assert pending_count.() == 1

      # The waker must now be a no-op for this row, no matter how many ticks
      # fire. Before the fix each call woke it and duplicated the pending event.
      assert {:ok, 0} = adapter.wake_sleeping_workflows(config, 100)
      assert {:ok, 0} = adapter.wake_sleeping_workflows(config, 100)

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :waiting
      assert pending_count.() == 1

      # And the event still resumes the workflow to completion.
      :ok = Wait.send_event(execution.id, "go", %{ok: true})
      Durable.Executor.execute_workflow(execution.id, config)

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :completed
      assert execution.context["result"]["ok"] == true
    end

    test "wake_now/1 dispatches via the named SleepWaker" do
      # The DataCase default boots Durable with `queue_enabled: false`, so the
      # SleepWaker isn't running. Start one manually and verify wake_now/1
      # routes to the *named* GenServer and returns a sweep result. The actual
      # waking of an elapsed row is covered deterministically by the
      # adapter-level tests above (which call wake_sleeping_workflows directly
      # on the test connection); this test isolates the named-dispatch path,
      # which would otherwise be entangled with cross-process sandbox
      # visibility under the shared-mode harness.
      config = Config.get(Durable)
      pid = start_supervised!({SleepWaker, config: config, interval: 60_000})
      assert is_pid(pid)
      assert Process.whereis(SleepWaker.worker_name(Durable)) == pid

      assert {:ok, count} = SleepWaker.wake_now(Durable)
      assert is_integer(count) and count >= 0
    end
  end

  # ============================================================================
  # Event Waiting Tests
  # ============================================================================

  describe "wait_for_event/2" do
    test "suspends workflow waiting for event" do
      {:ok, execution} = create_and_execute_workflow(EventWaitTestWorkflow, %{})

      assert execution.status == :waiting
    end

    test "creates PendingEvent record with correct attributes" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(EventWaitTestWorkflow, %{})

      pending = get_pending_event(repo, execution.id, "payment_confirmed")
      assert pending != nil
      assert pending.event_name == "payment_confirmed"
      assert pending.status == :pending
      assert pending.wait_type == :single
    end

    test "with timeout option sets timeout_at" do
      config = Config.get(Durable)
      repo = config.repo
      before = DateTime.utc_now()

      {:ok, execution} = create_and_execute_workflow(EventWaitTestWorkflow, %{})

      pending = get_pending_event(repo, execution.id, "payment_confirmed")
      assert pending.timeout_at != nil

      # Timeout should be ~1 hour in the future (hours(1))
      diff_ms = DateTime.diff(pending.timeout_at, before, :millisecond)
      assert diff_ms >= 3_500_000 and diff_ms <= 3_700_000
    end

    test "resumes when event is sent via send_event/4" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(EventWaitTestWorkflow, %{})
      assert execution.status == :waiting

      # Send the event - this also triggers resume internally
      :ok = Wait.send_event(execution.id, "payment_confirmed", %{"amount" => 99.99})

      # The workflow should now be pending (ready for queue to pick up)
      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :pending

      # Execute again to complete
      Executor.execute_workflow(execution.id, config)

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :completed
      assert execution.context["result"] == %{"amount" => 99.99}
    end
  end

  describe "wait_for_event/2 timeout_value sanitization (Bug C-2 regression)" do
    test "accepts a tagged tuple as timeout_value without crashing JSONB insert" do
      # Before the fix, `timeout_value: {:error, :timeout}` crashed at PendingEvent
      # insertion because Postgrex/Jason can't encode raw tuples.
      {:ok, execution} = create_and_execute_workflow(TupleTimeoutValueWorkflow, %{})

      assert execution.status == :waiting

      pending = get_pending_event(Durable.Config.get(Durable).repo, execution.id, "evt")
      assert pending != nil
      # Sanitized: tuple becomes a list
      assert pending.timeout_value == %{"__value__" => ["error", "timeout"]}
    end

    test "accepts a deeply nested map with tuples as timeout_value" do
      {:ok, execution} = create_and_execute_workflow(NestedTupleTimeoutValueWorkflow, %{})

      assert execution.status == :waiting

      pending = get_pending_event(Durable.Config.get(Durable).repo, execution.id, "evt")
      assert pending != nil
      # The map path also goes through sanitize_for_json now.
      timeout_value = pending.timeout_value
      assert is_map(timeout_value)
      # Nested tuple flattened to a list inside the map
      assert get_in(timeout_value, ["nested", "tag"]) == ["err", "boom"]
    end
  end

  describe "wait_for_any/2" do
    test "creates WaitGroup with wait_type :any" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(WaitAnyTestWorkflow, %{})

      wait_group = get_wait_group(repo, execution.id)
      assert wait_group != nil
      assert wait_group.wait_type == :any
      assert wait_group.event_names == ["success", "failure"]
    end

    test "creates PendingEvent for each event name" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(WaitAnyTestWorkflow, %{})

      pending_success = get_pending_event(repo, execution.id, "success")
      pending_failure = get_pending_event(repo, execution.id, "failure")

      assert pending_success != nil
      assert pending_failure != nil
      assert pending_success.wait_type == :any
      assert pending_failure.wait_type == :any
    end

    test "resumes when any event is received" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(WaitAnyTestWorkflow, %{})
      assert execution.status == :waiting

      # Send just one event
      :ok = Wait.send_event(execution.id, "success", %{"status" => "ok"})

      # Check wait group is completed
      wait_group = get_wait_group(repo, execution.id)
      assert wait_group.status == :completed

      # Workflow should now be pending
      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :pending

      # Execute again to complete
      Executor.execute_workflow(execution.id, config)

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :completed
    end
  end

  describe "wait_for_all/2" do
    test "creates WaitGroup with wait_type :all" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(WaitAllTestWorkflow, %{})

      wait_group = get_wait_group(repo, execution.id)
      assert wait_group != nil
      assert wait_group.wait_type == :all
      assert wait_group.event_names == ["approval_a", "approval_b"]
    end

    test "creates PendingEvent for each event name" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(WaitAllTestWorkflow, %{})

      pending_a = get_pending_event(repo, execution.id, "approval_a")
      pending_b = get_pending_event(repo, execution.id, "approval_b")

      assert pending_a != nil
      assert pending_b != nil
      assert pending_a.wait_type == :all
      assert pending_b.wait_type == :all
    end

    test "does not resume until all events received" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(WaitAllTestWorkflow, %{})
      assert execution.status == :waiting

      # Send first event
      :ok = Wait.send_event(execution.id, "approval_a", %{"approved" => true})

      # Wait group should still be pending
      wait_group = get_wait_group(repo, execution.id)
      assert wait_group.status == :pending
      assert wait_group.received_events == %{"approval_a" => %{"approved" => true}}

      # Workflow should still be waiting
      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :waiting

      # Send second event
      :ok = Wait.send_event(execution.id, "approval_b", %{"approved" => true})

      # Wait group should now be completed
      wait_group = get_wait_group(repo, execution.id)
      assert wait_group.status == :completed
    end

    test "returns map of event_name => payload after all events" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(WaitAllTestWorkflow, %{})

      # Send both events
      :ok = Wait.send_event(execution.id, "approval_a", %{"approved" => true, "by" => "alice"})
      :ok = Wait.send_event(execution.id, "approval_b", %{"approved" => true, "by" => "bob"})

      # Workflow should now be pending
      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :pending

      # Execute again to complete
      Executor.execute_workflow(execution.id, config)

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :completed
      assert execution.context["results"]["approval_a"]["by"] == "alice"
      assert execution.context["results"]["approval_b"]["by"] == "bob"
    end
  end

  # ============================================================================
  # Human Input Tests
  # ============================================================================

  describe "wait_for_input/2" do
    test "suspends workflow waiting for input" do
      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})

      assert execution.status == :waiting
    end

    test "creates PendingInput record with correct attributes" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})

      pending = get_pending_input(repo, execution.id, "manager_approval")
      assert pending != nil
      assert pending.input_name == "manager_approval"
      assert pending.status == :pending
      assert pending.input_type == :approval
      assert pending.prompt == "Approve?"
      assert pending.metadata == %{"amount" => 100}
    end

    test "resumes when input is provided via provide_input/4" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})
      assert execution.status == :waiting

      # Provide the input - this also triggers resume
      :ok = Wait.provide_input(execution.id, "manager_approval", %{"decision" => "approved"})

      # Workflow should now be pending
      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :pending

      # Execute again to complete
      Executor.execute_workflow(execution.id, config)

      execution = repo.get!(WorkflowExecution, execution.id)
      assert execution.status == :completed
    end

    test "with timeout option sets timeout_at" do
      config = Config.get(Durable)
      repo = config.repo
      before = DateTime.utc_now()

      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})

      pending = get_pending_input(repo, execution.id, "manager_approval")
      assert pending.timeout_at != nil

      # Timeout should be ~1 day in the future (days(1))
      diff_ms = DateTime.diff(pending.timeout_at, before, :millisecond)
      assert diff_ms >= 86_000_000 and diff_ms <= 87_000_000
    end
  end

  describe "wait_for_approval/2" do
    test "creates PendingInput with type :approval" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(ApprovalTestWorkflow, %{})

      pending = get_pending_input(repo, execution.id, "expense_approval")
      assert pending.input_type == :approval
    end
  end

  describe "wait_for_choice/2" do
    test "creates PendingInput with type :single_choice" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(ChoiceTestWorkflow, %{})

      pending = get_pending_input(repo, execution.id, "shipping_method")
      assert pending.input_type == :single_choice
    end

    test "stores choices in fields" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(ChoiceTestWorkflow, %{})

      pending = get_pending_input(repo, execution.id, "shipping_method")
      assert pending.fields != nil
      assert length(pending.fields) == 2
    end
  end

  describe "wait_for_text/2" do
    test "creates PendingInput with type :free_text" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(TextTestWorkflow, %{})

      pending = get_pending_input(repo, execution.id, "feedback")
      assert pending.input_type == :free_text
    end
  end

  describe "wait_for_form/2" do
    test "creates PendingInput with type :form" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(FormTestWorkflow, %{})

      pending = get_pending_input(repo, execution.id, "equipment_request")
      assert pending.input_type == :form
    end

    test "stores field definitions" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(FormTestWorkflow, %{})

      pending = get_pending_input(repo, execution.id, "equipment_request")
      assert pending.fields != nil
      assert length(pending.fields) == 2
    end
  end

  # ============================================================================
  # External API Tests
  # ============================================================================

  describe "provide_input/4" do
    test "finds pending input and completes it" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})

      :ok = Wait.provide_input(execution.id, "manager_approval", %{"approved" => true})

      pending = get_pending_input(repo, execution.id, "manager_approval")
      assert pending.status == :completed
      assert pending.response == %{"approved" => true}
    end

    test "returns {:error, :not_found} if no pending input" do
      # Use a valid but non-existent UUID
      fake_uuid = Ecto.UUID.generate()
      result = Wait.provide_input(fake_uuid, "unknown", %{})
      assert result == {:error, :not_found}
    end

    test "accepts a plain string response (single_choice / text / approval)" do
      # Regression: dashboard's SingleChoiceForm submits just the raw choice
      # string (e.g. "morning"). PendingInput.response is typed :map, so
      # without the wrap the cast silently fails and the workflow never
      # resumes. This test locks in that non-map responses are accepted.
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})

      assert :ok = Wait.provide_input(execution.id, "manager_approval", "approved")

      pending = get_pending_input(repo, execution.id, "manager_approval")
      assert pending.status == :completed
      assert pending.response == %{"value" => "approved"}
    end

    test "accepts an atom response (e.g. :approved)" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})

      assert :ok = Wait.provide_input(execution.id, "manager_approval", :approved)

      pending = get_pending_input(repo, execution.id, "manager_approval")
      assert pending.status == :completed
      # sanitize_for_json leaves atoms alone; complete_pending_input wraps
      # them under "value" because the column type is :map. JSONB then
      # stores the atom as its string form.
      assert pending.response == %{"value" => "approved"}
    end
  end

  describe "send_event/4" do
    test "finds pending event and receives it" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(EventWaitTestWorkflow, %{})

      :ok = Wait.send_event(execution.id, "payment_confirmed", %{"amount" => 50})

      pending = get_pending_event(repo, execution.id, "payment_confirmed")
      assert pending.status == :received
      assert pending.payload == %{"amount" => 50}
    end

    test "accepts a plain string payload" do
      # Same wrap pattern as provide_input/4: send_event("foo", "bar")
      # should succeed and store %{"value" => "bar"} in payload.
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(EventWaitTestWorkflow, %{})

      assert :ok = Wait.send_event(execution.id, "payment_confirmed", "done")

      pending = get_pending_event(repo, execution.id, "payment_confirmed")
      assert pending.status == :received
      assert pending.payload == %{"value" => "done"}
    end

    test "updates WaitGroup for grouped events" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(WaitAllTestWorkflow, %{})

      :ok = Wait.send_event(execution.id, "approval_a", %{"ok" => true})

      wait_group = get_wait_group(repo, execution.id)
      assert wait_group.received_events["approval_a"] == %{"ok" => true}
    end

    test "returns {:error, :not_found} if no pending event" do
      # Use a valid but non-existent UUID
      fake_uuid = Ecto.UUID.generate()
      result = Wait.send_event(fake_uuid, "unknown", %{})
      assert result == {:error, :not_found}
    end
  end

  describe "cancel_wait/2" do
    test "cancels all pending waits for workflow" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})

      :ok = Wait.cancel_wait(execution.id, reason: "user cancelled")

      pending = get_pending_input(repo, execution.id, "manager_approval")
      assert pending.status == :cancelled
    end

    test "returns {:error, :not_waiting} if workflow not waiting" do
      {:ok, execution} = create_and_execute_workflow(SimpleCompletingWorkflow, %{})

      result = Wait.cancel_wait(execution.id)
      assert result == {:error, :not_waiting}
    end
  end

  # ============================================================================
  # TimeoutWorker Tests
  # ============================================================================

  # Note: TimeoutWorker is not started when queue_enabled: false (test mode)
  # These tests would require starting Durable with queue_enabled: true
  # or manually starting the TimeoutWorker
  #
  # The TimeoutWorker functionality is tested indirectly through integration tests
  # when the full queue system is running

  # ============================================================================
  # Time Helpers Tests
  # ============================================================================

  describe "next_business_day/1" do
    test "returns next Mon-Fri at default hour 9" do
      result = Wait.next_business_day()

      assert result.hour == 9
      assert result.minute == 0
      assert result.second == 0

      # Should not be a weekend
      day = Date.day_of_week(DateTime.to_date(result))
      assert day in 1..5
    end

    test "skips weekends" do
      # This test is deterministic - next_business_day should never return Sat/Sun
      result = Wait.next_business_day()
      day = Date.day_of_week(DateTime.to_date(result))
      refute day in [6, 7]
    end

    test "respects :hour option" do
      result = Wait.next_business_day(hour: 17)
      assert result.hour == 17
    end
  end

  describe "next_weekday/2" do
    test "returns next occurrence of specified weekday" do
      result = Wait.next_weekday(:monday)
      day = Date.day_of_week(DateTime.to_date(result))
      assert day == 1
    end

    test "respects :hour option" do
      result = Wait.next_weekday(:friday, hour: 15)
      assert result.hour == 15
    end
  end

  describe "end_of_day/1" do
    test "returns 23:59:59 of current day" do
      result = Wait.end_of_day()
      today = Date.utc_today()

      assert DateTime.to_date(result) == today
      assert result.hour == 23
      assert result.minute == 59
      assert result.second == 59
    end
  end

  describe "zero timeout behavior" do
    test "zero timeout sets timeout_at to essentially now" do
      config = Config.get(Durable)
      repo = config.repo
      before = DateTime.utc_now()

      {:ok, execution} = create_and_execute_workflow(ZeroTimeoutEventWorkflow, %{})

      # Should still be waiting (timeout_at is set, but TimeoutWorker not running in test mode)
      assert execution.status == :waiting

      pending = get_pending_event(repo, execution.id, "quick_event")
      assert pending.timeout_at != nil

      # Zero timeout should result in timeout_at very close to creation time
      diff_ms = DateTime.diff(pending.timeout_at, before, :millisecond)
      # Should be within a small window (essentially immediate)
      assert diff_ms >= 0 and diff_ms <= 1000
    end
  end

  # ============================================================================
  # Edge Case Tests
  # ============================================================================

  describe "wait_for_event - edge cases" do
    test "duplicate event sends to same event name overwrites payload" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(EventWaitTestWorkflow, %{})
      assert execution.status == :waiting

      # Send first event
      :ok = Wait.send_event(execution.id, "payment_confirmed", %{"first" => true})

      # The pending event should now be received
      pending = get_pending_event(repo, execution.id, "payment_confirmed")
      assert pending.status == :received
      assert pending.payload == %{"first" => true}

      # Try to send a second event - should return not_found since event was already received
      result = Wait.send_event(execution.id, "payment_confirmed", %{"second" => true})
      assert result == {:error, :not_found}
    end

    test "event name with special characters handles correctly" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(SpecialCharEventWorkflow, %{})
      assert execution.status == :waiting

      # Check the pending event with special characters was created
      pending = get_pending_event(repo, execution.id, "event-with_special.chars:123")
      assert pending != nil
      assert pending.status == :pending

      # Send event with special chars
      :ok = Wait.send_event(execution.id, "event-with_special.chars:123", %{"data" => "test"})

      pending = get_pending_event(repo, execution.id, "event-with_special.chars:123")
      assert pending.status == :received
    end

    test "event name with unicode characters" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(UnicodeEventWorkflow, %{})
      assert execution.status == :waiting

      # Check the pending event with unicode was created
      pending = get_pending_event(repo, execution.id, "событие_イベント")
      assert pending != nil
      assert pending.status == :pending
    end
  end

  describe "wait_for_all - edge cases" do
    test "sending same event twice to wait_for_all updates payload" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(WaitAllTestWorkflow, %{})
      assert execution.status == :waiting

      # Send first event
      :ok = Wait.send_event(execution.id, "approval_a", %{"first" => true})

      # Check wait group received the event
      wait_group = get_wait_group(repo, execution.id)
      assert wait_group.received_events["approval_a"] == %{"first" => true}

      # Sending approval_a again should fail (already received)
      result = Wait.send_event(execution.id, "approval_a", %{"second" => true})
      assert result == {:error, :not_found}

      # Wait group should still have original payload
      wait_group = get_wait_group(repo, execution.id)
      assert wait_group.received_events["approval_a"] == %{"first" => true}
    end
  end

  describe "wait_for_any - edge cases" do
    test "wait_for_any resumes on first event only" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(WaitAnyTestWorkflow, %{})
      assert execution.status == :waiting

      # Send first event
      :ok = Wait.send_event(execution.id, "success", %{"status" => "ok"})

      # Wait group should be completed
      wait_group = get_wait_group(repo, execution.id)
      assert wait_group.status == :completed

      # A late event for a wait group that has already :completed is a
      # silent no-op — the wait_group's received_events does NOT grow,
      # and the workflow does not resume a second time. This is the
      # intentional contract: late arrivals are idempotent rather than
      # error-returning, because non-atomic implementations of
      # send_event used to leak inconsistent states (event :received
      # but wait group not updated) and tests can't rely on the error
      # type that previously surfaced.
      :ok = Wait.send_event(execution.id, "failure", %{"status" => "error"})

      wait_group = get_wait_group(repo, execution.id)
      assert wait_group.status == :completed
      refute Map.has_key?(wait_group.received_events, "failure")
    end
  end

  # ============================================================================
  # Query API Tests
  # ============================================================================

  describe "list_pending_inputs/1" do
    test "returns pending inputs with default filters" do
      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})

      inputs = Wait.list_pending_inputs()

      assert inputs != []
      assert Enum.any?(inputs, fn i -> i.workflow_id == execution.id end)
    end

    test "filters by status" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})

      # Complete the input
      pending = get_pending_input(repo, execution.id, "manager_approval")

      pending
      |> PendingInput.complete_changeset(%{})
      |> repo.update!()

      # Should not appear in pending list
      inputs = Wait.list_pending_inputs(status: :pending)
      refute Enum.any?(inputs, fn i -> i.workflow_id == execution.id end)

      # Should appear in completed list
      inputs = Wait.list_pending_inputs(status: :completed)
      assert Enum.any?(inputs, fn i -> i.workflow_id == execution.id end)
    end
  end

  describe "list_pending_events/1" do
    test "returns pending events with default filters" do
      {:ok, execution} = create_and_execute_workflow(EventWaitTestWorkflow, %{})

      events = Wait.list_pending_events()

      assert events != []
      assert Enum.any?(events, fn e -> e.workflow_id == execution.id end)
    end

    test "filters by event_name" do
      {:ok, execution} = create_and_execute_workflow(EventWaitTestWorkflow, %{})

      events = Wait.list_pending_events(event_name: "payment_confirmed")
      assert Enum.any?(events, fn e -> e.workflow_id == execution.id end)

      events = Wait.list_pending_events(event_name: "other_event")
      refute Enum.any?(events, fn e -> e.workflow_id == execution.id end)
    end
  end

  # ============================================================================
  # Resumability Tests
  # ============================================================================

  describe "resumability" do
    test "context is preserved across wait/resume cycle" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, exec} = create_and_execute_workflow(ContextPreservationWorkflow, %{})
      assert exec.status == :waiting
      assert exec.context["before_wait"] == "preserved"
      assert exec.context["counter"] == 1

      :ok = Wait.send_event(exec.id, "continue", %{"data" => "test"})
      Executor.execute_workflow(exec.id, config)

      exec = repo.get!(WorkflowExecution, exec.id)
      assert exec.status == :completed
      # Context from before wait is still there
      assert exec.context["before_wait"] == "preserved"
      # Code after wait verified and accessed the preserved context
      assert exec.context["verified_before"] == "preserved"
      # Event data was received correctly
      assert exec.context["after_wait"] == %{"data" => "test"}
    end

    test "steps after wait execute correctly" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, exec} = create_and_execute_workflow(MultiStepResumeWorkflow, %{})
      assert exec.status == :waiting
      # Step 1 ran before wait
      assert exec.context["step1"] == true

      :ok = Wait.send_event(exec.id, "trigger", %{"value" => 42})
      Executor.execute_workflow(exec.id, config)

      exec = repo.get!(WorkflowExecution, exec.id)
      assert exec.status == :completed
      # Step 1 context preserved
      assert exec.context["step1"] == true
      # Wait result stored
      assert exec.context["wait_result"] == %{"value" => 42}
      # Step 3 (after wait) executed
      assert exec.context["step3"] == true
      # Final step combined data from before and after wait
      assert exec.context["final"] != nil
    end

    test "sequential waits work correctly" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, exec} = create_and_execute_workflow(SequentialWaitsWorkflow, %{})
      assert exec.status == :waiting

      # First event
      :ok = Wait.send_event(exec.id, "event1", %{"a" => 1})
      Executor.execute_workflow(exec.id, config)

      exec = repo.get!(WorkflowExecution, exec.id)
      # Should be waiting again for event2
      assert exec.status == :waiting
      assert exec.context["result1"] == %{"a" => 1}

      # Second event
      :ok = Wait.send_event(exec.id, "event2", %{"b" => 2})
      Executor.execute_workflow(exec.id, config)

      exec = repo.get!(WorkflowExecution, exec.id)
      assert exec.status == :completed
      assert exec.context["result2"] == %{"b" => 2}
      assert exec.context["combined"]["first"] == %{"a" => 1}
      assert exec.context["combined"]["second"] == %{"b" => 2}
    end

    test "code after wait_for_input executes" do
      config = Config.get(Durable)
      repo = config.repo

      {:ok, exec} = create_and_execute_workflow(InputWaitTestWorkflow, %{})
      assert exec.status == :waiting

      :ok = Wait.provide_input(exec.id, "manager_approval", %{"approved" => true})
      Executor.execute_workflow(exec.id, config)

      exec = repo.get!(WorkflowExecution, exec.id)
      assert exec.status == :completed
      # assign after wait_for_approval ran
      assert exec.context["approval"] == %{"approved" => true}
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp create_and_execute_workflow(module, input) do
    config = Config.get(Durable)
    repo = config.repo
    {:ok, workflow_def} = module.__default_workflow__()

    attrs = %{
      workflow_module: Atom.to_string(module),
      workflow_name: workflow_def.name,
      status: :pending,
      queue: "default",
      priority: 0,
      input: input,
      context: %{}
    }

    {:ok, execution} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(attrs)
      |> repo.insert()

    Executor.execute_workflow(execution.id, config)
    {:ok, repo.get!(WorkflowExecution, execution.id)}
  end

  defp get_pending_input(repo, workflow_id, input_name) do
    repo.one(
      from(p in PendingInput,
        where: p.workflow_id == ^workflow_id and p.input_name == ^input_name
      )
    )
  end

  defp get_pending_event(repo, workflow_id, event_name) do
    repo.one(
      from(p in PendingEvent,
        where: p.workflow_id == ^workflow_id and p.event_name == ^event_name
      )
    )
  end

  defp get_wait_group(repo, workflow_id) do
    repo.one(
      from(w in WaitGroup,
        where: w.workflow_id == ^workflow_id
      )
    )
  end
end

# ============================================================================
# Test Workflow Modules
# ============================================================================

defmodule SleepTestWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "sleep_test" do
    step(:before_sleep, fn data ->
      {:ok, assign(data, :before, true)}
    end)

    step(:sleep_step, fn data ->
      sleep(seconds(30))
      {:ok, assign(data, :after_sleep, true)}
    end)

    step(:after_sleep, fn data ->
      {:ok, assign(data, :completed, true)}
    end)
  end
end

defmodule ScheduleAtTestWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "schedule_at_test" do
    step(:before_schedule, fn data ->
      {:ok, assign(data, :before, true)}
    end)

    step(:schedule_step, fn data ->
      schedule_at(next_business_day(hour: 9))
      {:ok, assign(data, :after_schedule, true)}
    end)
  end
end

# Short-duration workflows for the wake-up integration tests. The 1ms
# sleep / past-DateTime is essentially "wake immediately on next sweep,"
# which is what the tests need to drive the full lifecycle without
# slowing the suite down.

defmodule ShortSleepWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "short_sleep" do
    step(:before_step, fn data -> {:ok, assign(data, :before, true)} end)

    step(:sleep_step, fn data ->
      sleep(1)
      {:ok, assign(data, :slept, true)}
    end)

    step(:after_step, fn data -> {:ok, assign(data, :completed, true)} end)
  end
end

defmodule ShortScheduleAtWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "short_schedule_at" do
    step(:schedule_step, fn data ->
      schedule_at(DateTime.add(DateTime.utc_now(), -1, :second))
      {:ok, assign(data, :scheduled, true)}
    end)
  end
end

defmodule TwoSleepWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "two_sleep" do
    step(:first_sleep, fn data ->
      sleep(1)
      {:ok, assign(data, :first_done, true)}
    end)

    step(:second_sleep, fn data ->
      sleep(1)
      {:ok, assign(data, :second_done, true)}
    end)
  end
end

defmodule SleepThenEventWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  # A sleep step immediately followed by an event-wait step. This is the
  # shape that exposed the `scheduled_at` premature-wake bug: after the sleep
  # woke and completed, the row's stale scheduled_at made the SleepWaker
  # repeatedly flip the event-waiting row back to :pending.
  workflow "sleep_then_event" do
    step(:nap, fn data ->
      sleep(1)
      {:ok, assign(data, :napped, true)}
    end)

    step(:await, fn data ->
      result = wait_for_event("go")
      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule EventWaitTestWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "event_wait_test" do
    step(:wait_step, fn data ->
      result =
        wait_for_event("payment_confirmed",
          timeout: hours(1),
          timeout_value: :timed_out
        )

      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule WaitAnyTestWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "wait_any_test" do
    step(:wait_step, fn data ->
      {event_name, payload} = wait_for_any(["success", "failure"])

      data =
        data
        |> assign(:received_event, event_name)
        |> assign(:payload, payload)

      {:ok, data}
    end)
  end
end

defmodule WaitAllTestWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "wait_all_test" do
    step(:wait_step, fn data ->
      results = wait_for_all(["approval_a", "approval_b"])
      {:ok, assign(data, :results, results)}
    end)
  end
end

defmodule InputWaitTestWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "input_wait_test" do
    step(:wait_step, fn data ->
      result =
        wait_for_approval("manager_approval",
          prompt: "Approve?",
          metadata: %{amount: 100},
          timeout: days(1),
          timeout_value: :auto_approved
        )

      {:ok, assign(data, :approval, result)}
    end)
  end
end

defmodule ApprovalTestWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "approval_test" do
    step(:wait_step, fn data ->
      result = wait_for_approval("expense_approval", prompt: "Approve expense?")
      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule ChoiceTestWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "choice_test" do
    step(:wait_step, fn data ->
      result =
        wait_for_choice("shipping_method",
          prompt: "Select shipping:",
          choices: [
            %{value: :express, label: "Express"},
            %{value: :standard, label: "Standard"}
          ]
        )

      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule TextTestWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "text_test" do
    step(:wait_step, fn data ->
      result = wait_for_text("feedback", prompt: "Enter feedback:")
      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule FormTestWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "form_test" do
    step(:wait_step, fn data ->
      result =
        wait_for_form("equipment_request",
          prompt: "Select equipment:",
          fields: [
            %{name: :laptop, type: :select, options: ["MacBook", "ThinkPad"]},
            %{name: :notes, type: :text}
          ]
        )

      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule ShortTimeoutInputWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "short_timeout_input" do
    step(:wait_step, fn data ->
      result =
        wait_for_input("quick_input",
          timeout: seconds(1),
          timeout_value: :timed_out
        )

      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule ShortTimeoutEventWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "short_timeout_event" do
    step(:wait_step, fn data ->
      result =
        wait_for_event("quick_event",
          timeout: seconds(1),
          timeout_value: :timed_out
        )

      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule SimpleCompletingWorkflow do
  use Durable
  use Durable.Helpers

  workflow "simple_completing" do
    step(:complete, fn data ->
      {:ok, assign(data, :done, true)}
    end)
  end
end

# ============================================================================
# Resumability Test Workflows
# ============================================================================

defmodule ContextPreservationWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "context_preservation" do
    step(:setup, fn data ->
      data =
        data
        |> assign(:before_wait, "preserved")
        |> assign(:counter, 1)

      {:ok, data}
    end)

    step(:wait_and_check, fn data ->
      result = wait_for_event("continue")
      # These should still be accessible after resume
      before = data[:before_wait]

      data =
        data
        |> assign(:after_wait, result)
        |> assign(:verified_before, before)

      {:ok, data}
    end)
  end
end

defmodule MultiStepResumeWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "multi_step_resume" do
    step(:first, fn data ->
      {:ok, assign(data, :step1, true)}
    end)

    step(:wait_step, fn data ->
      result = wait_for_event("trigger")
      {:ok, assign(data, :wait_result, result)}
    end)

    step(:after_wait, fn data ->
      data =
        data
        |> assign(:step3, true)
        |> assign(:final, data[:step1] && data[:wait_result])

      {:ok, data}
    end)
  end
end

defmodule SequentialWaitsWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "sequential_waits" do
    step(:first_wait, fn data ->
      result1 = wait_for_event("event1")
      {:ok, assign(data, :result1, result1)}
    end)

    step(:second_wait, fn data ->
      result2 = wait_for_event("event2")
      {:ok, assign(data, :result2, result2)}
    end)

    step(:combine, fn data ->
      r1 = data[:result1]
      r2 = data[:result2]
      {:ok, assign(data, :combined, %{first: r1, second: r2})}
    end)
  end
end

defmodule ZeroTimeoutEventWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "zero_timeout_event" do
    step(:wait_step, fn data ->
      result =
        wait_for_event("quick_event",
          timeout: 0,
          timeout_value: :immediate_timeout
        )

      {:ok, assign(data, :result, result)}
    end)
  end
end

# Edge case test workflows

defmodule SpecialCharEventWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "special_char_event" do
    step(:wait_step, fn data ->
      result = wait_for_event("event-with_special.chars:123")
      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule UnicodeEventWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "unicode_event" do
    step(:wait_step, fn data ->
      result = wait_for_event("событие_イベント")
      {:ok, assign(data, :result, result)}
    end)
  end
end

# ============================================================================
# Bug C-2 regression fixtures — timeout_value with raw tuples / nested terms
# ============================================================================

defmodule TupleTimeoutValueWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "tuple_timeout" do
    step(:wait_step, fn data ->
      # Idiomatic Elixir tuple — would crash JSONB insert before fix.
      result = wait_for_event("evt", timeout: hours(1), timeout_value: {:error, :timeout})
      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule NestedTupleTimeoutValueWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "nested_tuple_timeout" do
    step(:wait_step, fn data ->
      result =
        wait_for_event("evt",
          timeout: hours(1),
          timeout_value: %{"nested" => %{"tag" => {:err, :boom}}}
        )

      {:ok, assign(data, :result, result)}
    end)
  end
end
