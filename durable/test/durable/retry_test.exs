defmodule Durable.RetryTest do
  @moduledoc """
  Retry semantics, with emphasis on the *durable* budget: a step's retry
  count must survive a worker crash / stale-lock recovery rather than
  restarting at attempt 1 and re-running side effects past max_attempts.
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  import Durable.DataCase, only: [create_and_execute_workflow: 2]
  import Ecto.Query

  defp failed_attempts(repo, workflow_id) do
    repo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^workflow_id and s.status == :failed,
        order_by: [asc: s.attempt],
        select: s.attempt
      )
    )
  end

  defp seed_failed_attempt!(repo, workflow_id, step_name, attempt) do
    %StepExecution{}
    |> Ecto.Changeset.change(%{
      workflow_id: workflow_id,
      step_name: step_name,
      step_type: "step",
      attempt: attempt,
      status: :failed,
      error: %{"type" => "error", "message" => "prior crash"}
    })
    |> repo.insert!()
  end

  test "the in-process retry loop still drives a flaky step to success" do
    config = Config.get(Durable)
    repo = config.repo

    {:ok, execution} = create_and_execute_workflow(FlakyOnceWorkflow, %{"fail_times" => 2})

    assert execution.status == :completed

    # 2 failed attempts + 1 completed = 3 rows; attempts 1,2 failed, 3 ok.
    assert failed_attempts(repo, execution.id) == [1, 2]
  end

  test "retry budget is durable: resume continues at the next attempt, not 1" do
    config = Config.get(Durable)
    repo = config.repo

    # A run that crashed mid-retry: 2 failed attempts already recorded, and
    # current_step still points at the failing step.
    {:ok, execution} =
      %WorkflowExecution{}
      |> Ecto.Changeset.change(%{
        workflow_module: Atom.to_string(AlwaysFailsWorkflow),
        workflow_name: "always_fails_wf",
        status: :pending,
        queue: "default",
        priority: 0,
        input: %{},
        context: %{},
        current_step: "always_fails"
      })
      |> repo.insert()

    seed_failed_attempt!(repo, execution.id, "always_fails", 1)
    seed_failed_attempt!(repo, execution.id, "always_fails", 2)

    Durable.Executor.execute_workflow(execution.id, config)

    # max_attempts is 3. With the budget seeded from the 2 prior failures the
    # resume runs ONLY attempt 3 and then terminally fails — it does NOT
    # restart at 1 and burn attempts 1,2,3 again (which the old behaviour did,
    # yielding [1,2,1,2,3] and 5 total invocations).
    assert failed_attempts(repo, execution.id) == [1, 2, 3]

    execution = repo.get!(WorkflowExecution, execution.id)
    assert execution.status == :failed
  end
end

defmodule FlakyOnceWorkflow do
  use Durable
  use Durable.Helpers
  use Durable.Context

  # Fails the first `fail_times` attempts (tracked per-attempt via the durable
  # step_executions row count), then succeeds — exercises the in-process loop.
  workflow "flaky_once_wf" do
    step(:flaky, [retry: [max_attempts: 5, backoff: :constant, base: 1]], fn data ->
      fail_times = data["fail_times"] || 0
      attempt = Durable.RetryTestHelper.attempt_for(:flaky)

      if attempt <= fail_times do
        {:error, %{reason: "transient", attempt: attempt}}
      else
        {:ok, assign(data, :done, true)}
      end
    end)
  end
end

defmodule AlwaysFailsWorkflow do
  use Durable
  use Durable.Helpers

  workflow "always_fails_wf" do
    step(:always_fails, [retry: [max_attempts: 3, backoff: :constant, base: 1]], fn _data ->
      {:error, %{reason: "permanent"}}
    end)
  end
end

defmodule Durable.RetryTestHelper do
  @moduledoc false
  # Per-step in-memory attempt counter for FlakyOnceWorkflow. The workflow
  # body can't see the runner's attempt number directly, so we count calls.
  def attempt_for(step) do
    key = {__MODULE__, step}
    n = (Process.get(key) || 0) + 1
    Process.put(key, n)
    n
  end
end
