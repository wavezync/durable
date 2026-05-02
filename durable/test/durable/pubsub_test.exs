defmodule Durable.PubSubTest do
  @moduledoc """
  Tests for `Durable.PubSub` lifecycle broadcasts.

  Subscribes to workflow and input topics, drives workflows inline via the
  executor, and asserts that the expected `{:durable_event, kind, payload}`
  messages arrive.
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Wait

  setup do
    config = Config.get(Durable)
    {:ok, config: config}
  end

  describe "subscribe/2" do
    test "returns :ok when pubsub is configured", %{config: config} do
      assert :ok = DurablePubSub.subscribe(config, DurablePubSub.workflows_topic(config))
    end

    test "returns {:error, :no_pubsub} when config has no pubsub", %{config: config} do
      nilled = %{config | pubsub: nil}
      assert {:error, :no_pubsub} = DurablePubSub.subscribe(nilled, "whatever")
    end
  end

  describe "workflow lifecycle broadcasts" do
    test "broadcasts :workflow_started on start_workflow", %{config: config} do
      :ok = DurablePubSub.subscribe(config, DurablePubSub.workflows_topic(config))

      {:ok, wf_id} = Executor.start_workflow(Durable.TestWorkflows.SimpleWorkflow, %{})

      assert_receive {:durable_event, :workflow_started, %{id: ^wf_id, status: :pending}}
    end

    test "broadcasts :workflow_resumed → :workflow_completed on inline execute", %{
      config: config
    } do
      :ok = DurablePubSub.subscribe(config, DurablePubSub.workflows_topic(config))

      {:ok, wf_id} = Executor.start_workflow(Durable.TestWorkflows.SimpleWorkflow, %{})
      Executor.execute_workflow(wf_id, config)

      assert_receive {:durable_event, :workflow_started, %{id: ^wf_id}}
      assert_receive {:durable_event, :workflow_resumed, %{id: ^wf_id, status: :running}}

      assert_receive {:durable_event, :workflow_completed, %{id: ^wf_id, status: :completed}}
    end

    test "broadcasts :workflow_cancelled on cancel", %{config: config} do
      :ok = DurablePubSub.subscribe(config, DurablePubSub.workflows_topic(config))

      {:ok, wf_id} = Executor.start_workflow(Durable.TestWorkflows.SimpleWorkflow, %{})
      # drain the start event
      assert_receive {:durable_event, :workflow_started, _}

      :ok = Executor.cancel_workflow(wf_id, "test")

      assert_receive {:durable_event, :workflow_cancelled, %{id: ^wf_id, status: :cancelled}}
    end

    test "per-workflow topic also receives events", %{config: config} do
      {:ok, wf_id} = Executor.start_workflow(Durable.TestWorkflows.SimpleWorkflow, %{})

      # Subscribe AFTER start — check completed event arrives via per-workflow topic
      :ok = DurablePubSub.subscribe(config, DurablePubSub.workflow_topic(config, wf_id))

      Executor.execute_workflow(wf_id, config)

      assert_receive {:durable_event, :workflow_completed, %{id: ^wf_id}}
    end
  end

  describe "step lifecycle broadcasts" do
    test "broadcasts :step_started and :step_completed", %{config: config} do
      {:ok, wf_id} = Executor.start_workflow(Durable.TestWorkflows.SimpleWorkflow, %{})
      :ok = DurablePubSub.subscribe(config, DurablePubSub.workflow_topic(config, wf_id))

      Executor.execute_workflow(wf_id, config)

      assert_receive {:durable_event, :step_started, %{step_name: "hello", status: :running}}

      assert_receive {:durable_event, :step_completed, %{step_name: "hello", status: :completed}}
    end
  end

  describe "input lifecycle broadcasts" do
    defmodule InputWorkflow do
      @moduledoc false
      use Durable
      use Durable.Wait

      workflow "approval" do
        step(:ask, fn _data ->
          approval = wait_for_input("approve", type: :approval, prompt: "OK?")
          {:ok, %{approval: approval}}
        end)
      end
    end

    test "broadcasts :input_requested when workflow waits for input", %{config: config} do
      :ok = DurablePubSub.subscribe(config, DurablePubSub.inputs_topic(config))

      {:ok, wf_id} = Executor.start_workflow(InputWorkflow, %{})
      Executor.execute_workflow(wf_id, config)

      assert_receive {:durable_event, :input_requested,
                      %{workflow_id: ^wf_id, input_name: "approve"}}
    end

    test "broadcasts :input_provided when input is supplied", %{config: config} do
      {:ok, wf_id} = Executor.start_workflow(InputWorkflow, %{})
      Executor.execute_workflow(wf_id, config)

      :ok = DurablePubSub.subscribe(config, DurablePubSub.inputs_topic(config))

      :ok = Wait.provide_input(wf_id, "approve", %{approved: true})

      assert_receive {:durable_event, :input_provided,
                      %{workflow_id: ^wf_id, input_name: "approve", status: :completed}}
    end
  end

  describe "topic naming" do
    test "workflows_topic is scoped by instance name", %{config: config} do
      assert DurablePubSub.workflows_topic(config) == "durable:Elixir.Durable:workflows"
    end

    test "workflow_topic includes workflow id", %{config: config} do
      assert DurablePubSub.workflow_topic(config, "abc-123") ==
               "durable:Elixir.Durable:workflow:abc-123"
    end

    test "inputs_topic is scoped by instance name", %{config: config} do
      assert DurablePubSub.inputs_topic(config) == "durable:Elixir.Durable:inputs"
    end
  end

  describe "no-pubsub fallback" do
    test "broadcast_workflow is a no-op when pubsub is nil" do
      config = %Config{name: :test, pubsub: nil}
      assert :ok = DurablePubSub.broadcast_workflow(config, :workflow_started, %{id: "x"})
    end
  end
end
