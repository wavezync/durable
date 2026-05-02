defmodule Durable.Executor.CrashModesTest do
  @moduledoc """
  Resilience matrix — every shape of step-body crash should produce a workflow
  in `:failed` with a serializable error payload, locks cleared, and a
  `:workflow_failed` PubSub broadcast. Mirrors oban's "safely executing jobs
  with any type of exit" test.

  TASK_CRASH (`Process.exit(self(), :kill)`) is intentionally NOT in this
  matrix — in inline mode `self()` is the test process, so killing it would
  abort the test. That path is exercised in the supervised Worker test.
  """

  use Durable.DataCase, async: false

  import Durable.DataCase, only: [create_and_execute_workflow: 2, pid_to_bin: 0]

  alias Durable.Config
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.WorkflowExecution
  alias Durable.TestWorkflows.SinkWorkflow

  @crash_actions [
    {"ERROR", "sink_error"},
    {"RAISE", "RuntimeError"},
    {"EXIT", "exit"}
  ]

  describe "step-body crash modes" do
    for {action, expected_type} <- @crash_actions do
      test "#{action} produces :failed with error.type=#{expected_type} and clears the lock" do
        action = unquote(action)
        expected_type = unquote(expected_type)

        config = Config.get(Durable)
        repo = config.repo

        :ok = DurablePubSub.subscribe(config, DurablePubSub.workflows_topic(config))

        ref = "ref-#{action}"

        input = %{
          "action" => action,
          "ref" => ref,
          "bin_pid" => pid_to_bin()
        }

        {:ok, exec} = create_and_execute_workflow(SinkWorkflow, input)

        assert exec.status == :failed, "expected #{action} → :failed, got #{exec.status}"
        assert exec.error["type"] == expected_type
        assert is_binary(exec.error["message"])
        assert exec.error["message"] != ""
        assert {:ok, _} = Jason.encode(exec.error)

        # Lock cleared on failure
        assert exec.locked_by == nil
        assert exec.locked_at == nil

        # Workflow row reloads identical (eliminates "is the in-memory copy
        # different from what's persisted?" doubt).
        reloaded = repo.get!(WorkflowExecution, exec.id)
        assert reloaded.status == :failed
        assert reloaded.locked_by == nil

        # PubSub broadcast happened
        wf_id = exec.id
        assert_receive {:durable_event, :workflow_failed, %{id: ^wf_id, status: :failed}}, 200
      end
    end
  end

  describe "non-crashing actions sanity (smoke)" do
    test "OK action completes cleanly" do
      ref = "ref-OK"
      input = %{"action" => "OK", "ref" => ref, "bin_pid" => pid_to_bin()}

      {:ok, exec} = create_and_execute_workflow(SinkWorkflow, input)

      assert exec.status == :completed
      assert_receive {:done, ^ref}
    end
  end
end
