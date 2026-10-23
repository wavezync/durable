defmodule Durable.DefinitionChangeTest do
  @moduledoc """
  A deploy can change a workflow under runs that are still in flight.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Storage.Schemas.WorkflowExecution

  defmodule V1 do
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "order" do
      step(:reserve, fn data -> {:ok, data} end)

      step(:approve, fn data ->
        wait_for_input("ok")
        {:ok, data}
      end)

      step(:ship, fn data -> {:ok, assign(data, :shipped, true)} end)
    end
  end

  # The next deploy renames :approve.
  defmodule V2 do
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "order" do
      step(:reserve, fn data -> {:ok, data} end)

      step(:review, fn data ->
        wait_for_input("ok")
        {:ok, data}
      end)

      step(:ship, fn data -> {:ok, assign(data, :shipped, true)} end)
    end
  end

  defp deploy(run, module) do
    config = Config.get(Durable)

    config.repo.update_all(from(w in WorkflowExecution, where: w.id == ^run.id),
      set: [workflow_module: Atom.to_string(module)]
    )
  end

  test "a run whose step was renamed fails instead of skipping to the end" do
    run = run_workflow(V1)
    deploy(run, V2)
    :ok = Durable.provide_input(run.id, "ok", %{})

    run = run |> drain() |> assert_status(:failed)
    assert run.error["type"] == "definition_changed"
    assert run.error["message"] =~ "no step approve"

    # Putting the step back and retrying carries on from it.
    deploy(run, V1)
    {:ok, _} = Durable.retry(run.id)
    run = run |> drain() |> assert_status(:completed)
    assert run.context["shipped"]
  end
end
