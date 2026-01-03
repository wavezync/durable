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

    # Note: Resume for sleep is complex as the step re-runs from beginning
    # This would require tracking sleep state at the step level
    # For now, we just test that sleep correctly suspends the workflow
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

  # ============================================================================
  # Query API Tests
  # ============================================================================

  describe "list_pending_inputs/1" do
    test "returns pending inputs with default filters" do
      {:ok, execution} = create_and_execute_workflow(InputWaitTestWorkflow, %{})

      inputs = Wait.list_pending_inputs()

      assert length(inputs) >= 1
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

      assert length(events) >= 1
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
      # put_context after wait_for_approval ran
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
  use Durable.Context
  use Durable.Wait

  workflow "sleep_test" do
    step :before_sleep do
      put_context(:before, true)
    end

    step :sleep_step do
      sleep(seconds(30))
      put_context(:after_sleep, true)
    end

    step :after_sleep do
      put_context(:completed, true)
    end
  end
end

defmodule ScheduleAtTestWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "schedule_at_test" do
    step :before_schedule do
      put_context(:before, true)
    end

    step :schedule_step do
      schedule_at(next_business_day(hour: 9))
      put_context(:after_schedule, true)
    end
  end
end

defmodule EventWaitTestWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "event_wait_test" do
    step :wait_step do
      result =
        wait_for_event("payment_confirmed",
          timeout: hours(1),
          timeout_value: :timed_out
        )

      put_context(:result, result)
    end
  end
end

defmodule WaitAnyTestWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "wait_any_test" do
    step :wait_step do
      {event_name, payload} = wait_for_any(["success", "failure"])
      put_context(:received_event, event_name)
      put_context(:payload, payload)
    end
  end
end

defmodule WaitAllTestWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "wait_all_test" do
    step :wait_step do
      results = wait_for_all(["approval_a", "approval_b"])
      put_context(:results, results)
    end
  end
end

defmodule InputWaitTestWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "input_wait_test" do
    step :wait_step do
      result =
        wait_for_approval("manager_approval",
          prompt: "Approve?",
          metadata: %{amount: 100},
          timeout: days(1),
          timeout_value: :auto_approved
        )

      put_context(:approval, result)
    end
  end
end

defmodule ApprovalTestWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "approval_test" do
    step :wait_step do
      result = wait_for_approval("expense_approval", prompt: "Approve expense?")
      put_context(:result, result)
    end
  end
end

defmodule ChoiceTestWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "choice_test" do
    step :wait_step do
      result =
        wait_for_choice("shipping_method",
          prompt: "Select shipping:",
          choices: [
            %{value: :express, label: "Express"},
            %{value: :standard, label: "Standard"}
          ]
        )

      put_context(:result, result)
    end
  end
end

defmodule TextTestWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "text_test" do
    step :wait_step do
      result = wait_for_text("feedback", prompt: "Enter feedback:")
      put_context(:result, result)
    end
  end
end

defmodule FormTestWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "form_test" do
    step :wait_step do
      result =
        wait_for_form("equipment_request",
          prompt: "Select equipment:",
          fields: [
            %{name: :laptop, type: :select, options: ["MacBook", "ThinkPad"]},
            %{name: :notes, type: :text}
          ]
        )

      put_context(:result, result)
    end
  end
end

defmodule ShortTimeoutInputWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "short_timeout_input" do
    step :wait_step do
      result =
        wait_for_input("quick_input",
          timeout: seconds(1),
          timeout_value: :timed_out
        )

      put_context(:result, result)
    end
  end
end

defmodule ShortTimeoutEventWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "short_timeout_event" do
    step :wait_step do
      result =
        wait_for_event("quick_event",
          timeout: seconds(1),
          timeout_value: :timed_out
        )

      put_context(:result, result)
    end
  end
end

defmodule SimpleCompletingWorkflow do
  use Durable
  use Durable.Context

  workflow "simple_completing" do
    step :complete do
      put_context(:done, true)
    end
  end
end

# ============================================================================
# Resumability Test Workflows
# ============================================================================

defmodule ContextPreservationWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "context_preservation" do
    step :setup do
      put_context(:before_wait, "preserved")
      put_context(:counter, 1)
    end

    step :wait_and_check do
      result = wait_for_event("continue")
      # These should still be accessible after resume
      before = get_context(:before_wait)
      put_context(:after_wait, result)
      put_context(:verified_before, before)
    end
  end
end

defmodule MultiStepResumeWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "multi_step_resume" do
    step :first do
      put_context(:step1, true)
    end

    step :wait_step do
      result = wait_for_event("trigger")
      put_context(:wait_result, result)
    end

    step :after_wait do
      put_context(:step3, true)
      put_context(:final, get_context(:step1) && get_context(:wait_result))
    end
  end
end

defmodule SequentialWaitsWorkflow do
  use Durable
  use Durable.Context
  use Durable.Wait

  workflow "sequential_waits" do
    step :first_wait do
      result1 = wait_for_event("event1")
      put_context(:result1, result1)
    end

    step :second_wait do
      result2 = wait_for_event("event2")
      put_context(:result2, result2)
    end

    step :combine do
      r1 = get_context(:result1)
      r2 = get_context(:result2)
      put_context(:combined, %{first: r1, second: r2})
    end
  end
end
