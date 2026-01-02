defmodule Durable.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring access to the
  application's data layer.

  You may define functions here to be used as helpers in your tests.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Durable.TestRepo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Durable.DataCase
    end
  end

  setup tags do
    Durable.DataCase.setup_sandbox(tags)

    # Start Durable with test repo and queue disabled for unit tests
    start_supervised!({Durable, repo: Durable.TestRepo, queue_enabled: false})

    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Durable.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that polls until a condition is met or timeout.

  ## Examples

      assert_eventually(fn ->
        {:ok, exec} = Durable.get_execution(id)
        exec.status == :completed
      end)
  """
  def assert_eventually(fun, timeout \\ 5000, interval \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline, interval)
  end

  defp do_assert_eventually(fun, deadline, interval) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(interval)
        do_assert_eventually(fun, deadline, interval)
      else
        ExUnit.Assertions.flunk("Condition not met within timeout")
      end
    end
  end
end
