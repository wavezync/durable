defmodule Durable.WakeTest do
  @moduledoc """
  A start or resume wakes its queue's pollers, so they don't wait out the
  poll interval.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Storage.Schemas.WorkflowExecution

  defmodule Quick do
    use Durable

    workflow "quick" do
      step(:a, fn data -> {:ok, data} end)
    end
  end

  defmodule Waits do
    use Durable
    use Durable.Wait

    workflow "waits_for_go" do
      step(:a, fn data ->
        wait_for_event("go")
        {:ok, data}
      end)
    end
  end

  describe "wake/2" do
    setup do
      :ok =
        DurablePubSub.subscribe(
          Config.get(Durable),
          DurablePubSub.queue_topic(Config.get(Durable), "default")
        )
    end

    test "a start and a resume wake the queue; a start for later doesn't" do
      {:ok, _} = Durable.start(Quick, %{})
      assert_receive {:durable_wake, "default"}

      later = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = Durable.start(Quick, %{}, scheduled_at: later)
      refute_receive {:durable_wake, _}

      run = run_workflow(Waits)
      assert_receive {:durable_wake, "default"}
      :ok = Durable.send_event(run.id, "go", %{})
      assert_receive {:durable_wake, "default"}
    end
  end

  describe "pollers" do
    @describetag :supervised

    setup do
      # A poll interval long enough that only a wake can pick the run up.
      Durable.DataCase.start_supervised_durable!(
        queues: %{default: [concurrency: 1, poll_interval: :timer.hours(1)]}
      )

      # Let the first poll, at start, go by.
      Process.sleep(100)
      :ok
    end

    test "claim a new run at once" do
      {:ok, id} = Durable.start(Quick, %{})
      assert eventually(fn -> TestRepo.get!(WorkflowExecution, id).status == :completed end)
    end
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
