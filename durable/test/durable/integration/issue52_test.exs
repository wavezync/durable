defmodule Issue52IndexUpdate do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # One account's search index, changed after each edit.
  workflow "i52_update_index", key_scope: "i52_account_index", on_duplicate: :run_again do
    step :apply, fn change ->
      Probe.inside([:index], fn ->
        if change["hold"],
          do: Probe.wait_for({:release, change["rev"]}),
          else: Process.sleep(50)
      end)

      Probe.note({:updated, change["rev"]})
      {:ok, change}
    end
  end
end

defmodule Issue52IndexRebuild do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The same index, rebuilt whole when an operator asks.
  workflow "i52_rebuild_index", key_scope: "i52_account_index", on_duplicate: :run_again do
    step :rebuild, fn request ->
      Probe.inside([:index], fn -> Process.sleep(200) end)
      Probe.note(:rebuilt)
      {:ok, request}
    end
  end
end

defmodule Issue52SwappingRebuild do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # A rebuild that swaps the old index back when the new one fails its check.
  # The swap back writes the index too, and is held until the test lets go.
  workflow "i52_swap_index", key_scope: "i52_account_index" do
    step :swap, [compensate: :swap_back], fn request -> {:ok, request} end

    step :verify, fn _request -> {:rollback, "the new index is missing documents"} end

    compensate :swap_back, fn request ->
      Probe.inside([:index], fn ->
        Probe.note(:swapping_back)
        Probe.wait_for(:swapped_back)
      end)

      Probe.note(:swapped_back)
      {:ok, request}
    end
  end
end

defmodule Durable.Integration.Issue52Test do
  @moduledoc """
  Issue #52: workflows that name one `key_scope:` share its keys, so an update
  and a rebuild of one account's index never run at once. On live pollers and
  real connections.
  """
  use Durable.IntegrationCase

  @key "acct:52"

  defp start_update(rev, opts \\ []) do
    {:ok, id} =
      Durable.start(Issue52IndexUpdate, %{"rev" => rev, "hold" => opts[:hold] == true}, key: @key)

    id
  end

  defp start_rebuild do
    {:ok, id} = Durable.start(Issue52IndexRebuild, %{}, key: @key)
    id
  end

  # What the steps noted, oldest first (`Probe.note/1` records no queue).
  defp noted, do: for({label, nil, _node} <- Probe.log(), do: label)

  test "an update and a rebuild never run at once, and go in the order they came" do
    start_durable!(%{default: 4})

    first = start_update(1, hold: true)
    assert_eventually(fn -> get(first).status == :running end)
    rebuilt = start_rebuild()
    last = start_update(2)

    :ok = Probe.set({:release, 1})
    await_status(last, :completed)

    assert %{status: :completed} = get(rebuilt)
    assert Probe.peak(:index) == 1
    assert noted() == [{:updated, 1}, :rebuilt, {:updated, 2}]
  end

  test "an update started while a rebuild is rolled back runs after the undo, not beside it" do
    start_durable!(%{default: 4})

    {:ok, rebuild} = Durable.start(Issue52SwappingRebuild, %{}, key: @key)
    assert_eventually(fn -> :swapping_back in noted() end)
    update = start_update(1)

    # Long enough for a poller to claim the update, were it free to run.
    Process.sleep(300)
    :ok = Probe.set(:swapped_back)
    await_status(update, :completed)

    assert Probe.peak(:index) == 1
    assert noted() == [:swapping_back, :swapped_back, {:updated, 1}]
    assert %{status: :compensated} = get(rebuild)
  end

  # Starts of the two workflows take one lock for the key, so they make one
  # line: no two runs wait for the same run.
  test "starts of both workflows racing on one key make one line" do
    start_durable!(%{default: 1}, queue_enabled: false)
    holder = start_update(0)

    IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^holder),
      set: [status: :running, started_at: Durable.Clock.utc_now()]
    )

    1..20
    |> Enum.map(fn i ->
      Task.async(fn -> if rem(i, 2) == 0, do: start_rebuild(), else: start_update(i) end)
    end)
    |> Task.await_many(10_000)

    afters =
      IntegrationRepo.all(
        from(w in WorkflowExecution, where: not is_nil(w.runs_after_id), select: w.runs_after_id)
      )

    assert length(afters) == 2
    assert Enum.uniq(afters) == afters
  end
end
