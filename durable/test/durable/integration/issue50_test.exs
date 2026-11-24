defmodule Issue50AccountSync do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # One sync of an account at a time; an edit while one runs syncs after it.
  workflow "i50_account_sync", on_duplicate: :run_again do
    step :sync, fn account ->
      if account["hold"], do: Probe.wait_for({:release, account["rev"]})
      Probe.note({:synced, account["rev"]})
      {:ok, account}
    end
  end
end

defmodule Durable.Integration.Issue50Test do
  @moduledoc """
  Issue #50: a start under another `on_duplicate:` took a free key ahead of a
  run waiting for it (run_again), and the waiting run's older input ran last.
  On live pollers and real connections.
  """
  use Durable.IntegrationCase

  @key "acct:50"

  defp sync(rev, opts \\ []) do
    Durable.start(Issue50AccountSync, %{"rev" => rev, "hold" => opts[:hold] == true},
      key: @key,
      on_duplicate: opts[:mode] || :run_again
    )
  end

  defp synced, do: for({{:synced, rev}, _queue, _node} <- Probe.log(), do: rev)

  test "the starts in between, in any mode, leave the newest input to run last" do
    start_durable!(%{default: 2})

    {:ok, holder} = sync(1, hold: true)
    assert_eventually(fn -> get(holder).status == :running end)
    {:ok, waiting} = sync(2)

    # The holder ends with its queue paused, so the waiting run stays waiting.
    :ok = Durable.pause_queue(:default)
    :ok = Probe.set({:release, 1})
    await_status(holder, :completed)

    assert {:error, {:key_taken, ^waiting}} = sync(3, mode: :error)
    assert {:ok, ^waiting} = sync(4, mode: :use_existing)
    assert {:ok, ^waiting} = sync(5)

    :ok = Durable.resume_queue(:default)
    assert %{holds_key: true, input: %{"rev" => 5}} = await_status(waiting, :completed)
    assert synced() == [1, 5]
    assert IntegrationRepo.aggregate(WorkflowExecution, :count) == 2
  end

  # `Durable.release_key/2` doesn't take the key's lock, so it can land, on
  # its own connection, in the middle of a start.
  describe "a holder released on another connection during a start" do
    setup do
      start_durable!(%{default: 1}, queue_enabled: false)
      {:ok, holder} = sync(1)

      IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^holder),
        set: [status: :running, started_at: Durable.Clock.utc_now()]
      )

      {:ok, waiting} = sync(2)
      assert get(waiting).runs_after_id == holder

      IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^holder),
        set: [status: :completed, completed_at: Durable.Clock.utc_now()]
      )

      release_after_insert_meets(holder)
      %{waiting: waiting}
    end

    test ":use_existing gets the waiting run", %{waiting: waiting} do
      assert {:ok, ^waiting} = sync(3, mode: :use_existing)
      assert Process.get(:fired)
      assert IntegrationRepo.aggregate(WorkflowExecution, :count) == 2
    end

    test ":run_again gives the waiting run its input", %{waiting: waiting} do
      assert {:ok, ^waiting} = sync(3)
      assert Process.get(:fired)
      assert get(waiting).input["rev"] == 3
      assert IntegrationRepo.aggregate(WorkflowExecution, :count) == 2
    end
  end

  # Right after the start's insert meets the holder, the holder is released
  # and that commits, before the start reads who holds the key.
  defp release_after_insert_meets(holder) do
    me = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:durable, :integration_repo, :query],
      fn _event, _measure, meta, _ ->
        if self() == me and not Process.get(:fired, false) and insert_met_holder?(meta),
          do: release_elsewhere(holder)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp insert_met_holder?(meta) do
    IO.iodata_to_binary(meta.query) =~ ~r/^INSERT INTO "durable"\."workflow_executions"/ and
      match?({:ok, %{num_rows: 0}}, meta.result)
  end

  defp release_elsewhere(holder) do
    Process.put(:fired, true)
    :ok = Task.async(fn -> Durable.release_key(holder) end) |> Task.await()
  end
end
