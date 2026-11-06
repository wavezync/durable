defmodule Durable.StepStopTest do
  @moduledoc """
  A step returning `{:fail, reason}` or `{:cancel, reason}` stops the run at
  once, whatever retry attempts are left.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Storage.Schemas.StepExecution

  defmodule FailNow do
    use Durable
    use Durable.Helpers

    workflow "fail_now" do
      step(:book, [compensate: :unbook], fn data -> {:ok, assign(data, :booked, true)} end)

      step(:fetch, [retry: [max_attempts: 5, backoff: :constant, base: 1]], fn _data ->
        {:fail, %{type: "gone", message: "410"}}
      end)

      step(:after, fn data -> {:ok, assign(data, :after, true)} end)

      compensate(:unbook, fn data -> {:ok, data} end)
    end
  end

  defmodule CancelNow do
    use Durable
    use Durable.Helpers

    workflow "cancel_now" do
      step(:book, [compensate: :unbook], fn data -> {:ok, assign(data, :booked, true)} end)

      step(:fetch, [retry: [max_attempts: 5, backoff: :constant, base: 1]], fn _data ->
        {:cancel, "record deleted"}
      end)

      step(:after, fn data -> {:ok, assign(data, :after, true)} end)

      compensate(:unbook, fn data -> {:ok, data} end)
    end
  end

  defmodule CancellingChild do
    use Durable

    workflow "cancelling_child" do
      step(:work, fn _data -> {:cancel, :not_needed} end)
    end
  end

  defmodule CallsCancellingChild do
    use Durable
    use Durable.Helpers
    use Durable.Orchestration

    workflow "calls_cancelling_child" do
      step(:call, fn data ->
        case call_workflow(CancellingChild, %{}) do
          {:ok, result} -> {:ok, assign(data, :result, result)}
          {:error, reason} -> {:ok, assign(data, :child_error, reason)}
        end
      end)
    end
  end

  defmodule CancelsOneBranch do
    use Durable
    use Durable.Helpers

    workflow "cancels_one_branch" do
      parallel on_error: :complete_all do
        step(:skipped, fn _data -> {:cancel, "nothing to send"} end)
        step(:sent, fn data -> {:ok, assign(data, :sent, true)} end)
      end
    end
  end

  defp step_rows(run) do
    TestRepo.all(
      from(s in StepExecution,
        where: s.workflow_id == ^run.id,
        order_by: [asc: s.inserted_at],
        select: {s.step_name, s.status, s.is_compensation}
      )
    )
  end

  test "{:fail, reason} fails at once and runs compensations" do
    run = run_workflow(FailNow)

    assert run.status == :compensated
    assert run.error["type"] == "gone"

    assert step_rows(run) == [
             {"book", :completed, false},
             {"fetch", :failed, false},
             {"compensate_unbook", :completed, true}
           ]
  end

  test "{:cancel, reason} cancels at once, without compensations" do
    run = run_workflow(CancelNow)

    assert run.status == :cancelled
    assert run.error == %{"type" => "cancelled", "message" => "record deleted"}
    assert step_rows(run) == [{"book", :completed, false}, {"fetch", :cancelled, false}]
  end

  test "a cancelled child hands its parent an error instead of leaving it waiting" do
    run = run_workflow(CallsCancellingChild)

    assert run.status == :completed
    assert run.context["child_error"] == %{"type" => "cancelled", "message" => "not_needed"}
  end

  test "{:cancel, reason} in a parallel step cancels only that branch" do
    run = run_workflow(CancelsOneBranch)

    assert run.status == :completed
    assert %{"skipped" => ["error", cancelled], "sent" => ["ok", _]} = run.context["__results__"]
    assert cancelled == %{"type" => "cancelled", "message" => "nothing to send"}
  end
end
