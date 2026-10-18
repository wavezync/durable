defmodule Durable.BlockIdsTest do
  @moduledoc """
  Steps inside `parallel` and `branch` blocks are named after their block's
  id, and those names are stored on runs. The ids must come out the same on
  every compile, or a run suspended inside a block can't resume after a deploy.
  """
  use ExUnit.Case, async: true

  @source """
  defmodule MODULE do
    use Durable
    use Durable.Context

    workflow "fan_out" do
      step :start, fn data -> {:ok, data} end

      parallel do
        step :a, fn data -> {:ok, data} end
        step :b, fn data -> {:ok, BODY} end
      end

      branch on: fn data -> data[:kind] end do
        :x -> step :on_x, fn data -> {:ok, data} end
        _ -> step :otherwise, fn data -> {:ok, data} end
      end
    end

    workflow "twin" do
      parallel do
        step :a, fn data -> {:ok, data} end
        step :b, fn data -> {:ok, data} end
      end
    end
  end
  """

  defp compile(module, body) do
    @source
    |> String.replace("MODULE", inspect(module))
    |> String.replace("BODY", body)
    |> Code.compile_string()

    for name <- ["fan_out", "twin"], into: %{} do
      {:ok, definition} = module.__workflow_definition__(name)
      {name, Enum.map(definition.steps, & &1.name)}
    end
  end

  test "ids survive a recompile and edits to step bodies" do
    first = compile(Durable.BlockIdsTest.First, "data")
    second = compile(Durable.BlockIdsTest.Second, "Map.put(data, :edited, true)")

    assert first == second
  end

  test "identical blocks in one module get different ids" do
    names = compile(Durable.BlockIdsTest.Third, "data")

    [fan_out_parallel] =
      for n <- names["fan_out"],
          String.starts_with?(to_string(n), "parallel_") and
            not String.contains?(to_string(n), "__"),
          do: n

    [twin_parallel] =
      for n <- names["twin"],
          String.starts_with?(to_string(n), "parallel_") and
            not String.contains?(to_string(n), "__"),
          do: n

    assert fan_out_parallel != twin_parallel
  end
end
