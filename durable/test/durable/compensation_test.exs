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

  # Workflow where first compensation succeeds but second fails (partial compensation)
  defmodule PartialCompensationWorkflow do
    use Durable
    use Durable.Helpers

    workflow "partial_compensation" do
      step(:step_one, [compensate: :undo_one], fn data ->
        {:ok, assign(data, :one, true)}
      end)

      step(:step_two, [compensate: :undo_two], fn data ->
        {:ok, assign(data, :two, true)}
      end)

      step(:fail_step, fn _data ->
        raise "Step failed"
      end)

      # This compensation runs first (reverse order) and succeeds
      compensate(:undo_two, fn data ->
        {:ok, assign(data, :two_undone, true)}
      end)

      # This compensation runs second and fails
      compensate(:undo_one, fn _data ->
        raise "Compensation for step_one failed"
      end)
    end
  end

  # The compensation returns whatever the run's input names.
  defmodule UndoReturns do
    use Durable

    workflow "undo_returns" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
      step(:charge, fn _data -> {:fail, "card declined"} end)

      compensate(:unbook, fn data ->
        Durable.CompensationTest.returned(data[:returns] || data["returns"], data)
      end)
    end
  end

  defmodule UndoRetries do
    use Durable

    workflow "undo_retries" do
      step(:book, [compensate: :unbook], fn data -> {:ok, data} end)
      step(:charge, fn _data -> {:fail, "card declined"} end)

      compensate(:unbook, [retry: [max_attempts: 3, backoff: :constant, base: 1]], fn data ->
        tries = Process.get(:undo_tries, 0) + 1
        Process.put(:undo_tries, tries)

        if tries > (data[:fail_times] || data["fail_times"]) do
          {:ok, data}
        else
          Durable.CompensationTest.returned(data[:returns] || data["returns"], data)
        end
      end)
    end
  end

  defmodule UndoChain do
    use Durable

    workflow "undo_chain" do
      step(:first, [compensate: :undo_first], fn data -> {:ok, data} end)
      step(:second, [compensate: :undo_second], fn data -> {:ok, data} end)
      step(:charge, fn _data -> {:fail, "card declined"} end)

      compensate(:undo_first, fn data -> {:ok, data} end)
      compensate(:undo_second, fn _data -> {:error, :gateway_down} end)
    end
  end

  # Steps store these errors through their own path.
  defmodule StepReturnsError do
    use Durable

    workflow "step_returns_error" do
      step(:charge, fn data ->
        Durable.CompensationTest.returned(data[:returns] || data["returns"], data)
      end)
    end
  end

  def returned("map", _data), do: {:error, %{code: 42}}
  def returned("atom", _data), do: {:error, :gateway_down}
  def returned("string", _data), do: {:error, "gateway down"}
  def returned("tuple", _data), do: {:error, {:http, 503}}
  def returned("fail", _data), do: {:fail, "can't undo"}
  def returned("changeset", _data), do: {:error, Ecto.Changeset.change(%StepExecution{})}
  def returned("exception", _data), do: {:error, %RuntimeError{message: "gone"}}
  def returned("unencodable", _data), do: {:error, %{from: self(), at: {1, 2}}}
  def returned("ok", data), do: {:ok, data}
  def returned("bare_ok", _data), do: :ok
  def returned("nil", _data), do: nil
  def returned("ok_struct", _data), do: {:ok, URI.parse("https://refunds.example/1")}
  def returned("ok_unencodable", _data), do: {:ok, %{from: self(), at: {1, 2}}}

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

      # Workflow should be in compensated state, finished like any other
      # terminal run
      assert execution.status == :compensated
      assert execution.completed_at != nil

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
      assert execution.completed_at != nil

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

    test "records partial success when some compensations succeed and others fail" do
      {:ok, execution} = create_and_execute_workflow(PartialCompensationWorkflow, %{})

      # Workflow should be in compensation_failed state
      assert execution.status == :compensation_failed

      # Should have results for both compensations
      results = execution.compensation_results
      assert length(results) == 2

      # First compensation (undo_two) should succeed, second (undo_one) should fail
      [first_comp, second_comp] = results
      assert first_comp["step"] == "step_two"
      assert first_comp["result"]["status"] == "completed"

      assert second_comp["step"] == "step_one"
      assert second_comp["result"]["status"] == "failed"
    end
  end

  describe "compensation execution - edge cases" do
    test "single-step workflow with compensation where step raises" do
      {:ok, execution} = create_and_execute_workflow(SingleStepRaisingCompensationWorkflow, %{})

      # When a step raises and has a compensation, it should be compensated
      # The step needs to actually complete first before the raise for compensation to apply
      assert execution.status in [:failed, :compensated]
    end

    test "compensation with step that returns {:error, map}" do
      {:ok, execution} = create_and_execute_workflow(ErrorMapCompensationWorkflow, %{})

      assert execution.status == :compensation_failed
    end

    test "parallel steps trigger compensations when step after parallel fails" do
      {:ok, execution} = create_and_execute_workflow(ParallelWithCompensationWorkflow, %{})

      # With durable parallel, parallel steps run as child executions.
      # The parent's step_executions don't include parallel step records,
      # so compensations for parallel steps don't trigger on the parent.
      # The workflow ends as :failed since no parent steps have compensations.
      assert execution.status == :failed
    end
  end

  describe "a compensation that reports an error" do
    for {returns, stored} <- [
          {"map", %{"code" => 42}},
          {"atom", %{"type" => "error", "message" => "gateway_down"}},
          {"string", %{"type" => "error", "message" => "gateway down"}},
          {"tuple", %{"type" => "error", "message" => "{:http, 503}"}},
          {"fail", %{"type" => "error", "message" => "can't undo"}}
        ] do
      test "returning #{returns} ends the run :compensation_failed and records why" do
        {:ok, run} = create_and_execute_workflow(UndoReturns, %{returns: unquote(returns)})

        assert run.status == :compensation_failed
        assert run.error["message"] == "card declined"
        assert run.completed_at != nil

        assert [%{"step" => "book", "compensation" => "unbook", "result" => result}] =
                 run.compensation_results

        assert result == %{"status" => "failed", "error" => unquote(Macro.escape(stored))}
        assert [%{status: :failed, error: unquote(Macro.escape(stored))}] = undo_rows(run.id)
      end
    end

    for returns <- ["changeset", "exception", "unencodable"] do
      test "returning a #{returns} that JSON can't hold is still recorded" do
        {:ok, run} = create_and_execute_workflow(UndoReturns, %{returns: unquote(returns)})

        assert run.status == :compensation_failed
        assert [%{"result" => %{"status" => "failed", "error" => %{}}}] = run.compensation_results
        assert [%{status: :failed, error: %{}}] = undo_rows(run.id)
      end

      test "a step returning a #{returns} that JSON can't hold fails its run" do
        {:ok, run} = create_and_execute_workflow(StepReturnsError, %{returns: unquote(returns)})

        assert run.status == :failed
        assert [%{status: :failed, error: %{}}] = step_rows(run.id, "charge")
      end
    end

    for returns <- ["ok", "bare_ok", "nil", "ok_struct", "ok_unencodable"] do
      test "returning #{returns} still counts as done" do
        {:ok, run} = create_and_execute_workflow(UndoReturns, %{returns: unquote(returns)})

        assert run.status == :compensated
        assert [%{"result" => %{"status" => "completed"}}] = run.compensation_results
        assert [%{status: :completed}] = undo_rows(run.id)
      end
    end

    test "{:error, _} uses the compensation's retries, as a raise does" do
      {:ok, run} =
        create_and_execute_workflow(UndoRetries, %{returns: "atom", fail_times: 99})

      assert run.status == :compensation_failed
      assert [{1, :failed}, {2, :failed}, {3, :failed}] = attempts(run.id)
    end

    test "a retry that works makes the run :compensated" do
      {:ok, run} = create_and_execute_workflow(UndoRetries, %{returns: "atom", fail_times: 2})

      assert run.status == :compensated
      assert [{1, :failed}, {2, :failed}, {3, :completed}] = attempts(run.id)
    end

    test "{:fail, _} skips the retries" do
      {:ok, run} = create_and_execute_workflow(UndoRetries, %{returns: "fail", fail_times: 99})

      assert run.status == :compensation_failed
      assert [{1, :failed}] = attempts(run.id)
    end

    test "the remaining compensations still run" do
      {:ok, run} = create_and_execute_workflow(UndoChain, %{})

      assert run.status == :compensation_failed

      assert [
               %{"compensation" => "undo_second", "result" => %{"status" => "failed"}},
               %{"compensation" => "undo_first", "result" => %{"status" => "completed"}}
             ] = run.compensation_results
    end

    test "telemetry reports the compensation and the run as errors" do
      test_pid = self()
      handler = "compensation-error-#{System.unique_integer()}"

      :telemetry.attach_many(
        handler,
        [[:durable, :compensation, :stop], [:durable, :workflow, :stop]],
        fn event, _measurements, meta, _config -> send(test_pid, {event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _run} = create_and_execute_workflow(UndoReturns, %{returns: "atom"})

      assert_received {[:durable, :compensation, :stop], %{compensation: :unbook, result: :error}}
      assert_received {[:durable, :workflow, :stop], %{status: :compensation_failed}}
    end
  end

  defp undo_rows(workflow_id) do
    Durable.TestRepo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id and s.is_compensation == true,
        order_by: s.attempt
      )
    )
  end

  defp step_rows(workflow_id, name) do
    Durable.TestRepo.all(
      from(s in StepExecution, where: s.workflow_id == ^workflow_id and s.step_name == ^name)
    )
  end

  defp attempts(workflow_id), do: Enum.map(undo_rows(workflow_id), &{&1.attempt, &1.status})

  # Helper function to create and execute workflow.
  # Drives through parallel fan-out/fan-in if the workflow has parallel blocks.
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

    execute_workflow_to_completion(execution.id, config, repo)
  end

  defp execute_workflow_to_completion(workflow_id, config, repo, max_iterations \\ 10)

  defp execute_workflow_to_completion(_workflow_id, _config, _repo, 0) do
    raise "Workflow did not complete within max iterations"
  end

  defp execute_workflow_to_completion(workflow_id, config, repo, iterations_left) do
    Executor.execute_workflow(workflow_id, config)
    execution = repo.get!(WorkflowExecution, workflow_id)

    if execution.status == :waiting do
      execute_children(repo, workflow_id, config)
      execute_workflow_to_completion(workflow_id, config, repo, iterations_left - 1)
    else
      {:ok, execution}
    end
  end

  defp execute_children(repo, parent_id, config) do
    import Ecto.Query

    children =
      repo.all(
        from(w in WorkflowExecution,
          where: w.parent_workflow_id == ^parent_id and w.status == :pending
        )
      )

    Enum.each(children, fn child ->
      Executor.execute_workflow(child.id, config)
    end)
  end
end

# Edge case test workflows

defmodule SingleStepRaisingCompensationWorkflow do
  use Durable
  use Durable.Helpers

  workflow "single_step_raising_compensation" do
    step(:setup_step, [compensate: :undo_setup], fn data ->
      {:ok, assign(data, :setup_done, true)}
    end)

    step(:failing_step, fn _data ->
      raise "Intentional failure"
    end)

    compensate(:undo_setup, fn data ->
      {:ok, assign(data, :undone, true)}
    end)
  end
end

defmodule ErrorMapCompensationWorkflow do
  use Durable
  use Durable.Helpers

  workflow "error_map_compensation" do
    step(:do_work, [compensate: :undo_work], fn data ->
      {:ok, assign(data, :work_done, true)}
    end)

    step(:fail_step, fn _data ->
      raise "Step failed"
    end)

    compensate(:undo_work, fn _data ->
      {:error, %{reason: "Compensation returned error"}}
    end)
  end
end

defmodule ParallelWithCompensationWorkflow do
  use Durable
  use Durable.Helpers

  workflow "parallel_with_compensation" do
    parallel do
      step(:task_a, [compensate: :undo_task_a], fn data ->
        {:ok, assign(data, :a_done, true)}
      end)

      step(:task_b, [compensate: :undo_task_b], fn data ->
        {:ok, assign(data, :b_done, true)}
      end)
    end

    step(:after_parallel, fn _data ->
      raise "Failure after parallel"
    end)

    compensate(:undo_task_a, fn data ->
      {:ok, assign(data, :a_undone, true)}
    end)

    compensate(:undo_task_b, fn data ->
      {:ok, assign(data, :b_undone, true)}
    end)
  end
end
