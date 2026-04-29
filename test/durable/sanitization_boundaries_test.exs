defmodule Durable.SanitizationBoundariesTest do
  @moduledoc """
  Regression coverage for PR 2 — the "sanitization sweep" at every user-data
  write boundary. Each test pushes a pathological payload (tuples, PIDs,
  refs, functions, deeply-nested mixes) through one user-facing API and
  verifies the workflow / step / pending-input / pending-event row was
  persisted without a `Protocol.UndefinedError`.

  Boundaries covered in PR 2:
    H-1  Durable.Wait.provide_input/4   → PendingInput.response
    H-2  Durable.Wait.send_event/4      → PendingEvent.payload
    H-3  StepRunner.fail_step_execution → StepExecution.error
    H-4  StepRunner.serialize_output    → StepExecution.output
    H-7  Executor.resume_workflow/3     → WorkflowExecution.context

  See docs/bug-reports/2026-04-13-follow-up-audit.md for context.
  """

  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, StepExecution, WorkflowExecution}
  alias Durable.Wait

  import Ecto.Query

  defp config, do: Config.get(Durable)
  defp repo, do: config().repo

  defp pathological_payload do
    %{
      "string_key" => {:tuple, "value"},
      tagged: {:error, :timeout},
      nested: [{:ok, %{ref: make_ref()}}, {:error, self()}],
      func: &Enum.map/2,
      pid: self(),
      tuple_in_list: [{:a, 1}, {:b, 2}]
    }
  end

  # --------------------------------------------------------------------------

  describe "H-1 — Wait.provide_input/4 sanitizes user-supplied data" do
    test "accepts pathological data and stores a JSON-encodable response" do
      {:ok, execution} = start_workflow_waiting_for_input("manager_approval")

      assert :ok = Wait.provide_input(execution.id, "manager_approval", pathological_payload())

      pending = get_pending_input(execution.id, "manager_approval")
      assert pending.status == :completed
      # Round-trip via Jason — the assertion that matters: no encode crash.
      assert {:ok, _} = Jason.encode(pending.response)
      # Spot-check: tuples became lists.
      assert pending.response["tagged"] == ["error", "timeout"]
      assert is_binary(pending.response["pid"])
    end
  end

  # --------------------------------------------------------------------------

  describe "H-2 — Wait.send_event/4 sanitizes user-supplied payload" do
    test "accepts pathological payload and stores a JSON-encodable event" do
      {:ok, execution} = start_workflow_waiting_for_event("payment_confirmed")

      assert :ok = Wait.send_event(execution.id, "payment_confirmed", pathological_payload())

      pending = get_pending_event(execution.id, "payment_confirmed")
      assert pending.status == :received
      assert {:ok, _} = Jason.encode(pending.payload)
      assert pending.payload["tagged"] == ["error", "timeout"]
    end
  end

  # --------------------------------------------------------------------------

  describe "H-3 — StepRunner.fail_step_execution sanitizes errors" do
    test "step that fails with a tuple-bearing error map persists cleanly" do
      {:ok, execution} = start_workflow_module(FailingStepWorkflow, %{})

      # The workflow should reach :failed and the step's error must be JSON-safe.
      reloaded = repo().get!(WorkflowExecution, execution.id)
      assert reloaded.status == :failed

      step = repo().one(from(s in StepExecution, where: s.workflow_id == ^execution.id))
      assert step.status == :failed
      assert {:ok, _} = Jason.encode(step.error)
      # Tuples flattened
      assert step.error["details"] == ["error", "boom"]
    end
  end

  # --------------------------------------------------------------------------

  describe "H-4 — StepRunner.serialize_output sanitizes step outputs" do
    test "step that returns a map containing nested tuples persists cleanly" do
      {:ok, execution} = start_workflow_module(NestedTupleOutputWorkflow, %{})

      reloaded = repo().get!(WorkflowExecution, execution.id)
      assert reloaded.status == :completed

      step =
        repo().one(
          from(s in StepExecution,
            where: s.workflow_id == ^execution.id and s.step_name == "produce_tuples"
          )
        )

      assert {:ok, _} = Jason.encode(step.output)
      # The shallow old serializer left nested tuples — verify recursion now flattens them.
      assert step.output["nested"]["tag"] == ["ok", "deep"]
    end
  end

  # --------------------------------------------------------------------------

  describe "H-7 — Executor.resume_workflow/3 sanitizes additional_context" do
    test "resume with additional_context containing tuples doesn't crash" do
      {:ok, execution} = start_workflow_waiting_for_event("any_event")

      bad_ctx = %{"resumed_with" => {:ok, %{ref: make_ref()}}}
      assert {:ok, _} = Executor.resume_workflow(execution.id, bad_ctx)

      reloaded = repo().get!(WorkflowExecution, execution.id)
      assert {:ok, _} = Jason.encode(reloaded.context)
      assert is_list(reloaded.context["resumed_with"])
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp start_workflow_waiting_for_input(input_name) do
    workflow_module =
      case input_name do
        "manager_approval" -> InputWaitFixtureWorkflow
        _ -> raise "unknown input fixture: #{input_name}"
      end

    {:ok, execution} = start_workflow_module(workflow_module, %{})
    reloaded = repo().get!(WorkflowExecution, execution.id)
    assert reloaded.status == :waiting
    {:ok, reloaded}
  end

  defp start_workflow_waiting_for_event(event_name) do
    workflow_module =
      case event_name do
        "payment_confirmed" -> EventWaitFixtureWorkflow
        "any_event" -> AnyEventWaitFixtureWorkflow
        _ -> raise "unknown event fixture: #{event_name}"
      end

    {:ok, execution} = start_workflow_module(workflow_module, %{})
    reloaded = repo().get!(WorkflowExecution, execution.id)
    assert reloaded.status == :waiting
    {:ok, reloaded}
  end

  defp start_workflow_module(module, input) do
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
      |> repo().insert()

    Executor.execute_workflow(execution.id, config())
    {:ok, repo().get!(WorkflowExecution, execution.id)}
  end

  defp get_pending_input(workflow_id, name) do
    repo().one(
      from(p in PendingInput,
        where: p.workflow_id == ^workflow_id and p.input_name == ^name
      )
    )
  end

  defp get_pending_event(workflow_id, name) do
    repo().one(
      from(p in PendingEvent,
        where: p.workflow_id == ^workflow_id and p.event_name == ^name
      )
    )
  end
end

# ============================================================================
# Fixtures
# ============================================================================

defmodule InputWaitFixtureWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "input_wait_fixture" do
    step(:await, fn data ->
      result = wait_for_approval("manager_approval", prompt: "ok?")
      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule EventWaitFixtureWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "event_wait_fixture" do
    step(:await, fn data ->
      result = wait_for_event("payment_confirmed", timeout: hours(1))
      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule AnyEventWaitFixtureWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Wait

  workflow "any_event_wait_fixture" do
    step(:await, fn data ->
      result = wait_for_event("any_event", timeout: hours(1))
      {:ok, assign(data, :result, result)}
    end)
  end
end

defmodule FailingStepWorkflow do
  use Durable
  use Durable.Helpers

  workflow "failing_step" do
    step(:boom, fn _data ->
      # User returns a tuple-bearing error map — H-3 says this must persist.
      {:error,
       %{
         type: "test_failure",
         message: "intentional",
         details: {:error, :boom},
         worker: self(),
         ref: make_ref()
       }}
    end)
  end
end

defmodule NestedTupleOutputWorkflow do
  use Durable
  use Durable.Helpers

  workflow "nested_tuple_output" do
    step(:produce_tuples, fn _data ->
      # User returns a map whose nested values include raw tuples. The old
      # shallow serialize_output left these untouched — JSONB would crash.
      {:ok,
       %{
         status: "ok",
         nested: %{tag: {:ok, "deep"}, list: [{:a, 1}, {:b, 2}]}
       }}
    end)
  end
end
