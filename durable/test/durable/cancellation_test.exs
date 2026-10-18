defmodule Durable.CancellationTest do
  @moduledoc """
  A cancel must stick. When it lands while a run is executing, the run stops at
  the next step boundary, and nothing the executor writes afterwards
  (completion, failure, waiting) may overwrite `:cancelled`.
  """
  use Durable.DataCase, async: false
  use ExUnitProperties

  alias Durable.{Config, Executor}
  alias Durable.Storage.Schemas.WorkflowExecution

  import Durable.DataCase, only: [create_and_execute_workflow: 2, get_step_executions: 1]

  defmodule FiveSteps do
    @moduledoc false
    use Durable

    # Input knobs (string or atom keys — data round-trips through JSONB):
    #   "cancel_at" — the step that cancels its own run, as a concurrent
    #                 operator would, mid-step
    #   "fail_at"   — the step that raises
    #   "sleep_ms"  — how long every step takes
    def act(i, data) do
      if ms = knob(data, :sleep_ms), do: Process.sleep(ms)
      if knob(data, :cancel_at) == i, do: Durable.cancel(Durable.Context.workflow_id())
      if knob(data, :fail_at) == i, do: raise("boom at step #{i}")
      {:ok, data}
    end

    defp knob(data, key), do: Map.get(data, key) || Map.get(data, Atom.to_string(key))

    workflow "five_steps" do
      step(:s1, fn data -> __MODULE__.act(1, data) end)
      step(:s2, fn data -> __MODULE__.act(2, data) end)
      step(:s3, fn data -> __MODULE__.act(3, data) end)
      step(:s4, fn data -> __MODULE__.act(4, data) end)
      step(:s5, fn data -> __MODULE__.act(5, data) end)
    end
  end

  defmodule WaitsForGo do
    @moduledoc false
    use Durable
    use Durable.Wait

    workflow "waits_for_go" do
      step(:ask, fn data ->
        _ = wait_for_input("go")
        {:ok, data}
      end)

      step(:done, fn data -> {:ok, data} end)
    end
  end

  defp status(id), do: Config.get(Durable).repo.get!(WorkflowExecution, id).status

  defp steps_started(id) do
    id
    |> get_step_executions()
    |> Enum.map(fn s -> s.step_name |> String.trim_leading("s") |> String.to_integer() end)
    |> Enum.uniq()
  end

  describe "cancel landing mid-run" do
    test "stops the run before the next step" do
      {:ok, exec} = create_and_execute_workflow(FiveSteps, %{"cancel_at" => 2})

      assert exec.status == :cancelled
      assert steps_started(exec.id) == [1, 2]
    end

    test "is not overwritten when the last step completes" do
      {:ok, exec} = create_and_execute_workflow(FiveSteps, %{"cancel_at" => 5})

      assert exec.status == :cancelled
    end

    test "is not overwritten when the same step then fails" do
      {:ok, exec} = create_and_execute_workflow(FiveSteps, %{"cancel_at" => 3, "fail_at" => 3})

      assert exec.status == :cancelled
      assert steps_started(exec.id) == [1, 2, 3]
    end
  end

  test "cancelling a finished run is rejected and leaves it finished" do
    {:ok, exec} = create_and_execute_workflow(FiveSteps, %{})

    assert Durable.cancel(exec.id) == {:error, :already_completed}
    assert status(exec.id) == :completed
  end

  property "any mix of cancel and failure points: the earlier one decides, nothing runs after it" do
    check all(
            cancel_at <- one_of([constant(nil), integer(1..5)]),
            fail_at <- one_of([constant(nil), integer(1..5)]),
            max_runs: 60
          ) do
      {:ok, exec} =
        create_and_execute_workflow(FiveSteps, %{"cancel_at" => cancel_at, "fail_at" => fail_at})

      stop_at = Enum.min([cancel_at || 6, fail_at || 6, 5])

      expected =
        cond do
          cancel_at && cancel_at <= (fail_at || 6) -> :cancelled
          fail_at -> :failed
          true -> :completed
        end

      assert exec.status == expected
      assert steps_started(exec.id) == Enum.to_list(1..stop_at)
    end
  end

  property "a concurrent cancel either wins or is rejected — never reports success and loses" do
    check all(
            cancel_after_ms <- integer(0..25),
            step_ms <- integer(0..6),
            max_runs: 40
          ) do
      {:ok, id} = Durable.start(FiveSteps, %{"sleep_ms" => step_ms})
      run = Task.async(fn -> Executor.execute_workflow(id, Config.get(Durable)) end)

      Process.sleep(cancel_after_ms)
      cancel_result = Durable.cancel(id)
      Task.await(run, 5_000)

      case cancel_result do
        :ok -> assert status(id) == :cancelled
        {:error, :already_completed} -> assert status(id) == :completed
      end
    end
  end

  property "cancel racing provide_input on a waiting run: the cancel always sticks" do
    check all(
            input_first? <- boolean(),
            jitter_ms <- integer(0..3),
            max_runs: 80
          ) do
      {:ok, exec} = create_and_execute_workflow(WaitsForGo, %{})
      assert exec.status == :waiting

      cancel = fn -> Durable.cancel(exec.id) end
      answer = fn -> Durable.provide_input(exec.id, "go", %{"ok" => true}) end
      {first, second} = if input_first?, do: {answer, cancel}, else: {cancel, answer}

      t1 = Task.async(first)
      Process.sleep(jitter_ms)
      t2 = Task.async(second)
      Task.await_many([t1, t2], 5_000)

      # Waiting and pending runs are both cancellable, so whichever lands
      # first, the run must end cancelled — a resume may never undo it.
      assert status(exec.id) == :cancelled
    end
  end
end
