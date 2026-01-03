defmodule Durable.SchedulerTest do
  @moduledoc """
  Tests for the scheduler feature.

  Tests cover:
  - API: CRUD operations for schedules
  - GenServer: Polling and triggering due schedules
  - DSL: @schedule decorator
  - Edge cases: Invalid inputs, duplicate names, etc.
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.ScheduledWorkflow

  # ============================================================================
  # Test Workflows
  # ============================================================================

  defmodule SimpleWorkflow do
    use Durable
    use Durable.Context

    workflow "simple" do
      step :do_work do
        put_context(:executed, true)
        put_context(:executed_at, DateTime.utc_now())
      end
    end
  end

  defmodule MultiWorkflow do
    use Durable
    use Durable.Context

    workflow "workflow_a" do
      step :a do
        put_context(:workflow, "a")
      end
    end

    workflow "workflow_b" do
      step :b do
        put_context(:workflow, "b")
      end
    end
  end

  defmodule ScheduledWorkflowModule do
    use Durable
    use Durable.Context
    use Durable.Scheduler.DSL

    @schedule cron: "0 9 * * *", timezone: "UTC"
    workflow "daily_report" do
      step :generate do
        put_context(:generated, true)
      end
    end

    @schedule cron: "0 */6 * * *", queue: :reports
    workflow "periodic_report" do
      step :generate do
        put_context(:type, "periodic")
      end
    end

    workflow "unscheduled" do
      step :work do
        put_context(:unscheduled, true)
      end
    end
  end

  # ============================================================================
  # API Tests
  # ============================================================================

  describe "schedule/3" do
    test "creates schedule with valid cron" do
      {:ok, schedule} = Durable.schedule(SimpleWorkflow, "0 9 * * *")

      assert schedule.name == "simple"
      assert schedule.workflow_module == "Durable.SchedulerTest.SimpleWorkflow"
      assert schedule.workflow_name == "simple"
      assert schedule.cron_expression == "0 9 * * *"
      assert schedule.timezone == "UTC"
      assert schedule.enabled == true
      assert schedule.next_run_at != nil
    end

    test "creates schedule with custom name" do
      {:ok, schedule} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "my_schedule")

      assert schedule.name == "my_schedule"
    end

    test "creates schedule with specific workflow" do
      {:ok, schedule} =
        Durable.schedule(MultiWorkflow, "0 9 * * *",
          workflow: "workflow_b",
          name: "specific_workflow"
        )

      assert schedule.workflow_name == "workflow_b"
    end

    test "creates schedule with UTC timezone" do
      {:ok, schedule} =
        Durable.schedule(SimpleWorkflow, "0 9 * * *",
          name: "tz_schedule",
          timezone: "UTC"
        )

      assert schedule.timezone == "UTC"
    end

    test "returns error for unsupported timezone without tzdata" do
      # Without tzdata configured, non-UTC timezones will fail
      result =
        Durable.schedule(SimpleWorkflow, "0 9 * * *",
          name: "unsupported_tz_schedule",
          timezone: "America/New_York"
        )

      assert {:error, {:timezone_error, "America/New_York", _}} = result
    end

    test "creates schedule with input" do
      {:ok, schedule} =
        Durable.schedule(SimpleWorkflow, "0 9 * * *",
          name: "input_schedule",
          input: %{key: "value"}
        )

      assert schedule.input == %{"key" => "value"} || schedule.input == %{key: "value"}
    end

    test "creates schedule with queue" do
      {:ok, schedule} =
        Durable.schedule(SimpleWorkflow, "0 9 * * *",
          name: "queue_schedule",
          queue: :high_priority
        )

      assert schedule.queue == "high_priority"
    end

    test "creates disabled schedule" do
      {:ok, schedule} =
        Durable.schedule(SimpleWorkflow, "0 9 * * *",
          name: "disabled_schedule",
          enabled: false
        )

      assert schedule.enabled == false
    end

    test "returns error for invalid cron" do
      result = Durable.schedule(SimpleWorkflow, "invalid cron", name: "invalid_cron")

      assert {:error, {:invalid_cron, _}} = result
    end

    test "returns error for invalid module" do
      result = Durable.schedule(NonExistentModule, "0 9 * * *", name: "invalid_module")

      assert {:error, _} = result
    end

    test "returns error for invalid workflow name" do
      result =
        Durable.schedule(MultiWorkflow, "0 9 * * *",
          workflow: "nonexistent",
          name: "invalid_workflow"
        )

      assert {:error, _} = result
    end

    test "returns error for duplicate name" do
      {:ok, _} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "duplicate_test")

      result = Durable.schedule(SimpleWorkflow, "0 10 * * *", name: "duplicate_test")

      assert {:error, %Ecto.Changeset{}} = result
    end
  end

  describe "list_schedules/1" do
    setup do
      {:ok, s1} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "list_schedule_1")

      {:ok, s2} =
        Durable.schedule(SimpleWorkflow, "0 10 * * *",
          name: "list_schedule_2",
          enabled: false
        )

      {:ok, s3} =
        Durable.schedule(SimpleWorkflow, "0 11 * * *",
          name: "list_schedule_3",
          queue: :reports
        )

      %{schedules: [s1, s2, s3]}
    end

    test "lists all schedules" do
      schedules = Durable.list_schedules()

      assert length(schedules) >= 3
    end

    test "filters by enabled status" do
      schedules = Durable.list_schedules(enabled: true)

      refute Enum.any?(schedules, &(&1.name == "list_schedule_2"))
    end

    test "filters by queue" do
      schedules = Durable.list_schedules(queue: :reports)

      assert Enum.any?(schedules, &(&1.name == "list_schedule_3"))
      refute Enum.any?(schedules, &(&1.name == "list_schedule_1"))
    end

    test "respects limit" do
      schedules = Durable.list_schedules(limit: 1)

      assert length(schedules) == 1
    end
  end

  describe "get_schedule/1" do
    test "returns schedule by name" do
      {:ok, created} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "get_test")

      {:ok, schedule} = Durable.get_schedule("get_test")

      assert schedule.id == created.id
    end

    test "returns error for nonexistent name" do
      result = Durable.get_schedule("nonexistent")

      assert {:error, :not_found} = result
    end
  end

  describe "update_schedule/2" do
    test "updates cron expression" do
      {:ok, _} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "update_cron_test")

      {:ok, updated} = Durable.update_schedule("update_cron_test", cron_expression: "0 10 * * *")

      assert updated.cron_expression == "0 10 * * *"
    end

    test "updates timezone" do
      {:ok, _} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "update_tz_test")

      {:ok, updated} = Durable.update_schedule("update_tz_test", timezone: "Europe/London")

      assert updated.timezone == "Europe/London"
    end

    test "updates enabled status" do
      {:ok, _} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "update_enabled_test")

      {:ok, updated} = Durable.update_schedule("update_enabled_test", enabled: false)

      assert updated.enabled == false
    end

    test "recalculates next_run_at when cron changes" do
      {:ok, original} =
        Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "update_next_run_test")

      {:ok, updated} =
        Durable.update_schedule("update_next_run_test", cron_expression: "0 23 * * *")

      assert updated.next_run_at != original.next_run_at
    end

    test "returns error for nonexistent schedule" do
      result = Durable.update_schedule("nonexistent", cron_expression: "0 10 * * *")

      assert {:error, :not_found} = result
    end
  end

  describe "delete_schedule/1" do
    test "deletes existing schedule" do
      {:ok, _} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "delete_test")

      :ok = Durable.delete_schedule("delete_test")

      assert {:error, :not_found} = Durable.get_schedule("delete_test")
    end

    test "returns error for nonexistent schedule" do
      result = Durable.delete_schedule("nonexistent")

      assert {:error, :not_found} = result
    end
  end

  describe "enable_schedule/1 and disable_schedule/1" do
    test "enables a disabled schedule" do
      {:ok, _} =
        Durable.schedule(SimpleWorkflow, "0 9 * * *",
          name: "enable_test",
          enabled: false
        )

      {:ok, schedule} = Durable.enable_schedule("enable_test")

      assert schedule.enabled == true
      assert schedule.next_run_at != nil
    end

    test "disables an enabled schedule" do
      {:ok, _} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "disable_test")

      {:ok, schedule} = Durable.disable_schedule("disable_test")

      assert schedule.enabled == false
    end
  end

  describe "trigger_schedule/1" do
    test "starts workflow immediately" do
      {:ok, _} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "trigger_test")

      {:ok, workflow_id} = Durable.trigger_schedule("trigger_test")

      assert is_binary(workflow_id)

      {:ok, execution} = Durable.get_execution(workflow_id)
      assert execution.workflow_name == "simple"
    end

    test "uses override input when provided" do
      {:ok, _} =
        Durable.schedule(SimpleWorkflow, "0 9 * * *",
          name: "trigger_input_test",
          input: %{original: true}
        )

      {:ok, workflow_id} =
        Durable.trigger_schedule("trigger_input_test", input: %{override: true})

      {:ok, execution} = Durable.get_execution(workflow_id)
      assert execution.input["override"] == true
    end

    test "returns error for nonexistent schedule" do
      result = Durable.trigger_schedule("nonexistent")

      assert {:error, :not_found} = result
    end
  end

  # ============================================================================
  # DSL Tests
  # ============================================================================

  describe "@schedule decorator" do
    test "generates __schedules__/0 function" do
      assert function_exported?(ScheduledWorkflowModule, :__schedules__, 0)
    end

    test "captures schedule definitions" do
      schedules = ScheduledWorkflowModule.__schedules__()

      assert length(schedules) == 2
    end

    test "captures cron expression" do
      schedules = ScheduledWorkflowModule.__schedules__()
      daily = Enum.find(schedules, &(&1.workflow == "daily_report"))

      assert daily.cron == "0 9 * * *"
    end

    test "captures timezone" do
      schedules = ScheduledWorkflowModule.__schedules__()
      daily = Enum.find(schedules, &(&1.workflow == "daily_report"))

      assert daily.timezone == "UTC"
    end

    test "captures queue" do
      schedules = ScheduledWorkflowModule.__schedules__()
      periodic = Enum.find(schedules, &(&1.workflow == "periodic_report"))

      assert periodic.queue == :reports
    end

    test "unscheduled workflows are not included" do
      schedules = ScheduledWorkflowModule.__schedules__()

      refute Enum.any?(schedules, &(&1.workflow == "unscheduled"))
    end
  end

  describe "register/1" do
    test "registers module's @schedule attributes" do
      :ok = API.register(ScheduledWorkflowModule)

      {:ok, daily} = Durable.get_schedule("daily_report")
      assert daily.cron_expression == "0 9 * * *"
      assert daily.timezone == "UTC"

      {:ok, periodic} = Durable.get_schedule("periodic_report")
      assert periodic.cron_expression == "0 */6 * * *"
      assert periodic.queue == "reports"
    end

    test "upserts existing schedules preserving enabled status" do
      # First, disable a schedule
      :ok = API.register(ScheduledWorkflowModule)
      {:ok, _} = Durable.disable_schedule("daily_report")

      # Re-register (simulating app restart)
      :ok = API.register(ScheduledWorkflowModule)

      # Should still be disabled
      {:ok, daily} = Durable.get_schedule("daily_report")
      assert daily.enabled == false
    end

    test "updates cron on re-registration" do
      # Create a schedule with different cron
      {:ok, _} =
        Durable.schedule(ScheduledWorkflowModule, "0 8 * * *",
          name: "daily_report",
          workflow: "daily_report"
        )

      # Re-register from module
      :ok = API.register(ScheduledWorkflowModule)

      # Cron should be updated
      {:ok, daily} = Durable.get_schedule("daily_report")
      assert daily.cron_expression == "0 9 * * *"
    end

    test "ignores modules without __schedules__" do
      result = API.register(SimpleWorkflow)

      assert result == :ok
    end
  end

  describe "register_all/1" do
    test "registers multiple modules" do
      :ok = API.register_all([ScheduledWorkflowModule])

      {:ok, _} = Durable.get_schedule("daily_report")
      {:ok, _} = Durable.get_schedule("periodic_report")
    end
  end

  # ============================================================================
  # Scheduler GenServer Tests
  # ============================================================================

  describe "get_due_schedules/1" do
    test "returns schedules with next_run_at in the past" do
      config = Config.get(Durable)
      repo = config.repo

      # Create schedule with next_run_at in the past
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      attrs = %{
        name: "due_schedule",
        workflow_module: inspect(SimpleWorkflow),
        workflow_name: "simple",
        cron_expression: "0 9 * * *",
        timezone: "UTC",
        enabled: true,
        next_run_at: past
      }

      {:ok, _} =
        %ScheduledWorkflow{}
        |> ScheduledWorkflow.changeset(attrs)
        |> repo.insert()

      due = API.get_due_schedules(config)

      assert Enum.any?(due, &(&1.name == "due_schedule"))
    end

    test "excludes disabled schedules" do
      config = Config.get(Durable)
      repo = config.repo

      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      attrs = %{
        name: "disabled_due_schedule",
        workflow_module: inspect(SimpleWorkflow),
        workflow_name: "simple",
        cron_expression: "0 9 * * *",
        timezone: "UTC",
        enabled: false,
        next_run_at: past
      }

      {:ok, _} =
        %ScheduledWorkflow{}
        |> ScheduledWorkflow.changeset(attrs)
        |> repo.insert()

      due = API.get_due_schedules(config)

      refute Enum.any?(due, &(&1.name == "disabled_due_schedule"))
    end

    test "excludes schedules with next_run_at in the future" do
      config = Config.get(Durable)
      repo = config.repo

      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      attrs = %{
        name: "future_schedule",
        workflow_module: inspect(SimpleWorkflow),
        workflow_name: "simple",
        cron_expression: "0 9 * * *",
        timezone: "UTC",
        enabled: true,
        next_run_at: future
      }

      {:ok, _} =
        %ScheduledWorkflow{}
        |> ScheduledWorkflow.changeset(attrs)
        |> repo.insert()

      due = API.get_due_schedules(config)

      refute Enum.any?(due, &(&1.name == "future_schedule"))
    end
  end

  describe "mark_run/2" do
    test "updates last_run_at and sets next_run_at in future" do
      config = Config.get(Durable)

      {:ok, schedule} = Durable.schedule(SimpleWorkflow, "0 9 * * *", name: "mark_run_test")

      assert schedule.last_run_at == nil

      {:ok, updated} = API.mark_run(schedule, config)

      # last_run_at should be set to approximately now
      assert updated.last_run_at != nil
      diff = DateTime.diff(DateTime.utc_now(), updated.last_run_at, :second)
      assert diff >= 0 and diff < 5

      # next_run_at should be in the future relative to last_run_at
      assert DateTime.compare(updated.next_run_at, updated.last_run_at) == :gt
    end
  end
end
