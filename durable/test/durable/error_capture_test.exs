defmodule Durable.ErrorCaptureTest do
  @moduledoc """
  A failed step keeps what went wrong — the exception's type, a readable
  message and the stack, file and line per frame — however it failed.
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}

  defmodule Failing do
    use Durable
    use Durable.Helpers

    workflow "raises" do
      step(:boom, fn _data -> raise ArgumentError, "bad amount" end)
    end

    workflow "exits" do
      step(:call, fn _data -> exit({:timeout, {GenServer, :call, [:payments, :charge, 5000]}}) end)
    end

    workflow "branch_raises" do
      step(:start, fn data -> {:ok, data} end)

      branch on: fn _data -> raise KeyError, key: :tier, term: %{} end do
        :gold -> step(:gold, fn data -> {:ok, data} end)
      end
    end

    workflow "compensation_raises" do
      step(:reserve, [compensate: :release], fn data -> {:ok, data} end)
      step(:charge, fn _data -> raise "card declined" end)
      compensate(:release, fn _data -> raise RuntimeError, "release failed" end)
    end
  end

  defp repo, do: Config.get(Durable).repo
  defp run(id), do: repo().get!(WorkflowExecution, id)

  defp step_error(id, name) do
    repo().one!(
      from(s in StepExecution,
        where: s.workflow_id == ^id and s.step_name == ^name,
        order_by: [desc: s.inserted_at],
        limit: 1,
        select: s.error
      )
    )
  end

  defp start(name) do
    {:ok, definition} = Failing.__workflow_definition__(name)
    {:ok, id} = Executor.start_workflow(Failing, %{}, inline: true, workflow: definition.name)
    id
  end

  test "a raised exception keeps its type, message and a stack with file and line" do
    id = start("raises")

    assert %{"type" => "ArgumentError", "message" => "bad amount", "stacktrace" => stack} =
             step_error(id, "boom")

    assert stack =~ ~r"test/durable/error_capture_test\.exs:\d+"
    assert %{"stacktrace" => ^stack} = run(id).error
  end

  test "an exit is stored readably, with its stack" do
    id = start("exits")

    assert %{"type" => "exit", "message" => message, "stacktrace" => stack} =
             step_error(id, "call")

    assert message =~ "GenServer.call(:payments, :charge, 5000)"
    assert message =~ "time out"
    assert stack =~ "error_capture_test.exs"
  end

  test "a branch's on: function that raises keeps the exception and its stack" do
    id = start("branch_raises")

    assert %{"type" => "KeyError", "message" => message, "stacktrace" => stack} = run(id).error
    assert message =~ ":tier"
    assert stack =~ "error_capture_test.exs"
  end

  test "a compensation that raises keeps its stack too" do
    id = start("compensation_raises")

    assert %{"type" => "RuntimeError", "message" => "release failed", "stacktrace" => stack} =
             step_error(id, "compensate_release")

    assert stack =~ "error_capture_test.exs"
  end
end
