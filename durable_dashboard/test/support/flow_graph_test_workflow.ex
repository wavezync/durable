defmodule DurableDashboard.Components.FlowGraphTestWorkflow do
  @moduledoc """
  A real compiled workflow used by `FlowGraphTest` so the FlowGraph render
  path can reflect an actual definition. It lives in `test/support` (compiled
  into the test code path deterministically) rather than inline in the test
  file: when defined inline it isn't reliably loaded before the parallel test
  runner reaches the render test, and `definition_for/1` then falls back to the
  "No graph available" empty state.
  """
  use Durable
  use Durable.Helpers

  workflow "fg_test" do
    step(:a, fn data -> {:ok, data} end)
    step(:b, fn data -> {:ok, data} end)
  end
end
