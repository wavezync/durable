defmodule Durable.CompensationTest do
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.StepExecution
  alias Durable.Storage.Schemas.WorkflowExecution

  # A workflow that books a trip - compensation test example
  defmodule BookTripWorkflow do
    use Durable
    use Durable.Helpers

    workflow "book_trip" do
      step(:book_flight, [compensate: :cancel_flight], fn data ->
        {:ok,
         data
         |> assign(:flight_booked, true)
         |> assign(:flight_id, "FL-123")}
      end)

      step(:book_hotel, [compensate: :cancel_hotel], fn data ->
        {:ok,
         data
         |> assign(:hotel_booked, true)
         |> assign(:hotel_id, "HT-456")}
      end)

      step(:charge_payment, fn _data ->
        # This step fails, triggering compensations
        raise "Payment failed"
      end)

      compensate(:cancel_flight, fn data ->
        {:ok, assign(data, :flight_cancelled, true)}
      end)

      compensate(:cancel_hotel, fn data ->
        {:ok, assign(data, :hotel_cancelled, true)}
      end)
    end
  end

  # Workflow where compensation also fails
  defmodule FailingCompensationWorkflow do
    use Durable
    use Durable.Helpers

    workflow "failing_compensation" do
      step(:do_work, [compensate: :undo_work], fn data ->
        {:ok, assign(data, :work_done, true)}
      end)

      step(:fail_step, fn _data ->
        raise "Step failed"
      end)

      compensate(:undo_work, fn _data ->
        raise "Compensation failed too"
      end)
    end
  end

  # Workflow with no compensations
  defmodule NoCompensationWorkflow do
    use Durable
    use Durable.Helpers

    workflow "no_compensation" do
      step(:step_one, fn data ->
        {:ok, assign(data, :one, true)}
      end)

      step(:step_two, fn _data ->
        raise "No compensation here"
      end)
    end
  end

  # Workflow that succeeds (no compensations needed)
  defmodule SuccessfulWorkflow do
    use Durable
    use Durable.Helpers

    workflow "successful" do
      step(:step_one, [compensate: :undo_one], fn data ->
        {:ok, assign(data, :one, true)}
      end)

      step(:step_two, fn data ->
        {:ok, assign(data, :two, true)}
      end)

      compensate(:undo_one, fn data ->
        {:ok, assign(data, :one_undone, true)}
      end)
    end
  end

  describe "compensation DSL" do
    test "compensate macro creates compensation definition" do
      {:ok, workflow_def} = BookTripWorkflow.__workflow_definition__("book_trip")

      assert Map.has_key?(workflow_def.compensations, :cancel_flight)
      assert Map.has_key?(workflow_def.compensations, :cancel_hotel)

      cancel_flight = workflow_def.compensations[:cancel_flight]
      assert cancel_flight.name == :cancel_flight
      assert cancel_flight.module == BookTripWorkflow
    end

    test "step links to compensation via :compensate option" do
      {:ok, workflow_def} = BookTripWorkflow.__workflow_definition__("book_trip")

      book_flight = Enum.find(workflow_def.steps, &(&1.name == :book_flight))
      assert book_flight.opts[:compensate] == :cancel_flight

      book_hotel = Enum.find(workflow_def.steps, &(&1.name == :book_hotel))
      assert book_hotel.opts[:compensate] == :cancel_hotel
    end
  end

  describe "compensation execution" do
    test "compensations execute in reverse order on step failure" do
      {:ok, execution} = create_and_execute_workflow(BookTripWorkflow, %{})
      workflow_id = execution.id

      # Workflow should be in compensated state
      assert execution.status == :compensated

      # Check compensation results
      results = execution.compensation_results
      assert length(results) == 2

      # First compensation should be for hotel (reverse order)
      [hotel_comp, flight_comp] = results
      assert hotel_comp["step"] == "book_hotel"
      assert hotel_comp["compensation"] == "cancel_hotel"
      assert hotel_comp["result"]["status"] == "completed"

      assert flight_comp["step"] == "book_flight"
      assert flight_comp["compensation"] == "cancel_flight"
      assert flight_comp["result"]["status"] == "completed"

      # Compensation step executions should be recorded
      compensation_steps =
        Durable.TestRepo.all(
          from(s in StepExecution,
            where: s.workflow_id == ^workflow_id,
            where: s.is_compensation == true,
            order_by: [asc: s.completed_at]
          )
        )

      assert length(compensation_steps) == 2
      assert Enum.all?(compensation_steps, &(&1.status == :completed))
    end

    test "workflow marked as compensation_failed when compensation fails" do
      {:ok, execution} = create_and_execute_workflow(FailingCompensationWorkflow, %{})

      assert execution.status == :compensation_failed

      # Should have the original error
      assert execution.error["message"] == "Step failed"

      # Compensation results should show failure
      [result] = execution.compensation_results
      assert result["result"]["status"] == "failed"
    end

    test "workflow marked as failed when no compensations defined" do
      {:ok, execution} = create_and_execute_workflow(NoCompensationWorkflow, %{})

      # Should be plain failed (no compensations to run)
      assert execution.status == :failed
      assert execution.compensation_results == []
    end

    test "successful workflow does not run compensations" do
      {:ok, execution} = create_and_execute_workflow(SuccessfulWorkflow, %{})
      workflow_id = execution.id

      assert execution.status == :completed
      assert execution.compensation_results == []

      # No compensation steps should exist
      compensation_steps =
        Durable.TestRepo.all(
          from(s in StepExecution,
            where: s.workflow_id == ^workflow_id,
            where: s.is_compensation == true
          )
        )

      assert compensation_steps == []
    end
  end

  # Helper function to create and execute workflow
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
end
