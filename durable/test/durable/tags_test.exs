defmodule Durable.TagsTest do
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Storage.Schemas.WorkflowExecution

  defmodule Order do
    use Durable
    use Durable.Wait

    workflow "tagged_order" do
      step(:wait, fn data ->
        wait_for_event("paid")
        {:ok, data}
      end)
    end
  end

  defmodule Export do
    use Durable

    workflow "tagged_export" do
      step(:run, fn data -> {:ok, data} end)
    end
  end

  test "list_executions finds runs by tag, across workflows" do
    {:ok, order} = Durable.start(Order, %{}, tags: ["account:7", "rush"])
    {:ok, export} = Durable.start(Export, %{}, tags: ["account:7"])
    {:ok, _other} = Durable.start(Export, %{}, tags: ["account:8"])

    ids = for run <- Durable.list_executions(tag: "account:7"), do: run.id
    assert Enum.sort(ids) == Enum.sort([order, export])
    assert [%{id: ^order, tags: ["account:7", "rush"]}] = Durable.list_executions(tag: "rush")
  end

  test "cancel_all cancels the open runs that match, and counts them" do
    waiting = run_workflow(Order, %{}, tags: ["account:7"])
    finished = run_workflow(Export, %{}, tags: ["account:7"])
    {:ok, pending} = Durable.start(Export, %{}, tags: ["account:7"])
    {:ok, other} = Durable.start(Export, %{}, tags: ["account:8"])

    assert {:ok, 2} = Durable.cancel_all([tag: "account:7"], "account closed")

    status = fn id -> TestRepo.get!(WorkflowExecution, id).status end
    assert status.(waiting.id) == :cancelled
    assert status.(pending) == :cancelled
    assert status.(finished.id) == :completed
    assert status.(other) == :pending

    assert TestRepo.get!(WorkflowExecution, pending).error["message"] == "account closed"
  end

  test "cancel_all needs a filter" do
    assert_raise ArgumentError, fn -> Durable.cancel_all([], "oops") end
    assert_raise ArgumentError, fn -> Durable.cancel_all([limit: 10], "oops") end
  end

  test "tags must be strings" do
    assert {:error, %Ecto.Changeset{}} = Durable.start(Export, %{}, tags: [:not_a_string])
  end
end
