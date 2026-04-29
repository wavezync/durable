defmodule Durable.RetryContextTest do
  @moduledoc """
  Regression coverage for PR 3 / H-5 — `put_context/2` writes made during a
  failed retry attempt must remain visible to subsequent attempts. Before
  the fix, `Process.put(:durable_context, data)` at the top of every retry
  attempt overwrote prior writes.
  """

  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.WorkflowExecution

  test "put_context writes survive across retry attempts" do
    config = Config.get(Durable)
    repo = config.repo

    {:ok, workflow_def} = RetryAccumulator.__default_workflow__()

    {:ok, exec} =
      %WorkflowExecution{}
      |> WorkflowExecution.changeset(%{
        workflow_module: Atom.to_string(RetryAccumulator),
        workflow_name: workflow_def.name,
        status: :pending,
        queue: "default",
        priority: 0,
        input: %{},
        context: %{}
      })
      |> repo.insert()

    Executor.execute_workflow(exec.id, config)

    reloaded = repo.get!(WorkflowExecution, exec.id)
    assert reloaded.status == :completed

    # The step succeeds on attempt #3 only; if put_context was preserved
    # across attempts, :seen_attempts will be 3.
    assert reloaded.context["seen_attempts"] == 3
  end
end

defmodule RetryAccumulator do
  use Durable
  use Durable.Helpers
  use Durable.Context

  workflow "retry_accumulator" do
    step(
      :flaky,
      [retry: [max_attempts: 3, backoff: :linear]],
      fn _data ->
        # Increment a counter via put_context — this should accumulate
        # across retries. Before H-5's fix, it always read nil and reset
        # to 1 on every attempt.
        prior = get_context(:seen_attempts) || 0
        current = prior + 1
        put_context(:seen_attempts, current)

        if current < 3 do
          {:error, %{type: "transient", message: "retry me"}}
        else
          # Don't bother returning :seen_attempts in the map — the C-1 fix
          # ensures put_context writes persist regardless.
          {:ok, %{done: true}}
        end
      end
    )
  end
end
