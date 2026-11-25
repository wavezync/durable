defmodule Durable.KeyScopeTest do
  @moduledoc """
  `key_scope:` (issue #52): workflows that name one scope share its keys. A
  run of one waits for a run of another with the same key, in the order they
  were started, and a start never answers with, cancels or hands its input to
  another workflow's run.
  """
  use Durable.DataCase, async: false

  import Durable.Testing
  import ExUnit.CaptureIO

  alias Durable.Clock
  alias Durable.Config
  alias Durable.Executor
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Storage.Schemas.WorkflowExecution

  # One account's search index: an update after each change, and a rebuild an
  # operator asks for. For one account, never both at once.
  defmodule IndexUpdate do
    use Durable
    use Durable.Wait

    workflow "update_index", key_scope: "account_index", on_duplicate: :run_again do
      step :apply, fn change ->
        wait_for_event("go")
        {:ok, change}
      end
    end
  end

  defmodule IndexRebuild do
    use Durable
    use Durable.Wait

    workflow "rebuild_index", key_scope: "account_index" do
      step :rebuild, fn request ->
        wait_for_event("go")
        {:ok, request}
      end
    end
  end

  defmodule DebouncedIndexUpdate do
    use Durable
    use Durable.Wait

    workflow "debounced_update_index",
      key_scope: "account_index",
      debounce: [period: :timer.minutes(1)] do
      step :apply, fn change ->
        wait_for_event("go")
        {:ok, change}
      end
    end
  end

  # Two workflows in one module, with no key_scope: keys of their own.
  defmodule Articles do
    use Durable
    use Durable.Wait

    workflow "process_article" do
      step :summarize, fn article ->
        wait_for_event("go")
        {:ok, article}
      end
    end

    workflow "index_article" do
      step :index, fn article ->
        wait_for_event("go")
        {:ok, article}
      end
    end
  end

  # A rebuild that swaps a new index in, and swaps the old one back if the new
  # one fails its check. Swapping back writes the index too. `"start"` makes
  # the swap back start a run of the key, as a producer would meanwhile.
  defmodule SwappingRebuild do
    use Durable
    use Durable.Wait

    workflow "swap_index", key_scope: "account_index" do
      step :swap, [compensate: :swap_back], fn request -> {:ok, request} end

      step :verify, fn _request ->
        wait_for_event("go")
        {:rollback, "the new index is missing documents"}
      end

      compensate :swap_back, fn request ->
        case request["start"] do
          "update" ->
            Durable.start(Durable.KeyScopeTest.IndexUpdate, %{"change" => 9}, key: "account:7")

          "swap" ->
            Durable.start(__MODULE__, %{}, key: "account:7")

          nil ->
            :ok
        end

        {:ok, request}
      end
    end
  end

  # swap_index after a deploy took its key_scope: away. Its swap back starts
  # an update and another swap.
  defmodule UnscopedSwap do
    use Durable
    use Durable.Wait

    workflow "swap_index_unscoped" do
      step :swap, [compensate: :swap_back], fn request -> {:ok, request} end

      step :verify, fn _request ->
        wait_for_event("go")
        {:rollback, "the new index is missing documents"}
      end

      compensate :swap_back, fn request ->
        Durable.start(Durable.KeyScopeTest.IndexUpdate, %{"change" => 9}, key: "account:7")
        Durable.start(__MODULE__, %{}, key: "account:7")
        {:ok, request}
      end
    end
  end

  # A third workflow of the scope: a check of the index.
  defmodule IndexAudit do
    use Durable
    use Durable.Wait

    workflow "audit_index", key_scope: "account_index" do
      step :check, fn request ->
        wait_for_event("go")
        {:ok, request}
      end
    end
  end

  @key "account:7"

  defp config, do: Config.get(Durable)
  defp get(id), do: TestRepo.get!(WorkflowExecution, id)
  defp count, do: TestRepo.aggregate(WorkflowExecution, :count)
  defp claim, do: Postgres.fetch_jobs(config(), "default", 10, "test-node")

  defp start_update(change, opts \\ []),
    do: Durable.start(IndexUpdate, %{"change" => change}, [key: @key] ++ opts)

  defp start_rebuild(opts \\ []),
    do: Durable.start(IndexRebuild, %{"full" => true}, [key: @key] ++ opts)

  defp start_audit, do: Durable.start(IndexAudit, %{}, key: @key)

  defp runs_of(name, except),
    do:
      TestRepo.all(
        from(w in WorkflowExecution,
          where: w.workflow_name == ^name and w.id != ^except,
          select: w.id
        )
      )

  # As a run started while its workflow named `scope` (nil: named none).
  defp started_under!(id, scope),
    do:
      TestRepo.update_all(from(w in WorkflowExecution, where: w.id == ^id),
        set: [key_scope: scope]
      )

  defp finish(id) do
    :ok = Durable.send_event(id, "go", %{})
    drain(id)
  end

  # Claims the one run that's due and runs it to its wait.
  defp claim_and_run(id) do
    assert [%{id: ^id, lock_token: token}] = claim()
    Executor.execute_workflow(id, config(), token)
    get(id)
  end

  describe "a run of another workflow in the scope" do
    test "a rebuild started while an update runs waits for it" do
      %{id: running} = run_workflow(IndexUpdate, %{"change" => 1}, key: @key)

      {:ok, waiting} = start_rebuild()
      assert waiting != running
      assert %{status: :pending, holds_key: false, runs_after_id: ^running} = get(waiting)
      assert claim() == []

      assert finish(running).status == :completed
      assert %{status: :waiting, holds_key: true, runs_after_id: nil} = claim_and_run(waiting)
    end

    test "an update started while a rebuild runs waits for it" do
      %{id: running} = run_workflow(IndexRebuild, %{"full" => true}, key: @key)

      {:ok, waiting} = start_update(1)
      assert %{status: :pending, holds_key: false, runs_after_id: ^running} = get(waiting)
      assert claim() == []
    end

    test "a rebuild waiting for the key keeps its input when an update comes" do
      %{id: running} = run_workflow(IndexUpdate, %{"change" => 1}, key: @key)
      {:ok, waiting_rebuild} = start_rebuild()

      {:ok, next} = start_update(2)
      assert next not in [running, waiting_rebuild]
      assert {:ok, ^next} = start_update(3)

      assert get(waiting_rebuild).input == %{"full" => true}
      assert %{runs_after_id: ^waiting_rebuild, input: %{"change" => 3}} = get(next)
      assert count() == 3
    end

    test "a rebuild no worker has picked up keeps its input when an update comes" do
      {:ok, unstarted} = start_rebuild()
      {:ok, update_id} = start_update(1)

      assert update_id != unstarted
      assert %{input: %{"full" => true}, holds_key: true} = get(unstarted)
      assert %{runs_after_id: ^unstarted, holds_key: false} = get(update_id)
    end

    test "an update no worker has picked up doesn't take an update started after a rebuild" do
      {:ok, unstarted} = start_update(1)
      {:ok, waiting_rebuild} = start_rebuild()

      {:ok, next} = start_update(2)
      assert next not in [unstarted, waiting_rebuild]
      assert get(unstarted).input == %{"change" => 1}
      assert get(next).runs_after_id == waiting_rebuild
    end

    test "the runs in line go one at a time, in the order they were started" do
      %{id: first} = run_workflow(IndexUpdate, %{"change" => 1}, key: @key)
      {:ok, second} = start_rebuild()
      {:ok, third} = start_update(2)

      assert finish(first).status == :completed
      assert %{holds_key: true} = claim_and_run(second)
      assert claim() == []

      assert finish(second).status == :completed
      assert %{holds_key: true} = claim_and_run(third)
    end

    # A start reads the clock before it has the key's lock, and another
    # node's clock can be behind: start times can disagree with the line.
    test "a start on a node whose clock is behind still goes after the run it joined behind" do
      %{id: first} = run_workflow(IndexUpdate, %{"change" => 1}, key: @key)
      {:ok, second} = start_rebuild()

      on_exit(fn -> Clock.sync(config()) end)

      minute_behind =
        System.os_time(:microsecond) - System.monotonic_time(:microsecond) - 60_000_000

      Clock.put_offset(minute_behind)
      {:ok, third} = start_audit()
      Clock.sync(config())
      assert DateTime.before?(get(third).inserted_at, get(second).inserted_at)

      assert finish(first).status == :completed
      assert %{holds_key: true} = claim_and_run(second)
      assert finish(second).status == :completed
      assert %{holds_key: true} = claim_and_run(third)
    end

    test "a debounced start doesn't hand its input to it" do
      {:ok, unstarted} = start_rebuild()
      before = get(unstarted)

      {:ok, debounced} = Durable.start(DebouncedIndexUpdate, %{"change" => 1}, key: @key)

      assert debounced != unstarted
      assert %{input: %{"full" => true}, scheduled_at: at} = get(unstarted)
      assert at == before.scheduled_at
      assert get(debounced).runs_after_id == unstarted
    end

    for mode <- [:use_existing, :error, :cancel_existing, {:send_event, "change"}] do
      test "on_duplicate: #{inspect(mode)} waits its turn instead of meeting it" do
        %{id: running} = run_workflow(IndexRebuild, %{"full" => true}, key: @key)

        assert {:ok, waiting} = start_update(1, on_duplicate: unquote(Macro.escape(mode)))
        assert waiting != running
        assert %{runs_after_id: ^running, holds_key: false} = get(waiting)

        assert %{status: :waiting, holds_key: true} = get(running)
        assert Durable.Activity.list!(workflow_id: running, kinds: ["key_duplicate"]) == []
      end
    end

    test "takes the key once it has finished, whatever it finished as" do
      %{id: failed} = run_workflow(IndexRebuild, %{"full" => true}, key: @key)
      :ok = Durable.cancel(failed, "wrong account")

      {:ok, next} = start_update(1)
      assert %{holds_key: true, runs_after_id: nil} = get(next)
      refute get(failed).holds_key
    end

    # A run stopped mid-step keeps its worker's lock until that worker has
    # stopped the step: no other run of its key is claimed meanwhile.
    test "stopped mid-step, holds up the line until its worker lets go" do
      {:ok, stopped} = start_rebuild()
      assert [%{id: ^stopped}] = claim()

      TestRepo.update_all(from(w in WorkflowExecution, where: w.id == ^stopped),
        set: [started_at: Durable.Clock.utc_now()]
      )

      :ok = Durable.cancel(stopped, "wrong account")
      assert %{locked_by: "test-node", lock_token: nil} = get(stopped)

      {:ok, next} = start_update(1)
      assert get(next).holds_key
      assert claim() == []
    end
  end

  describe "a run of its own workflow in the line" do
    test "is the one on_duplicate: answers with" do
      %{id: running} = run_workflow(IndexUpdate, %{"change" => 1}, key: @key)
      {:ok, waiting} = start_rebuild()

      # A second rebuild asked for while one waits.
      assert {:ok, ^waiting} = start_rebuild()
      assert {:error, {:key_taken, ^waiting}} = start_rebuild(on_duplicate: :error)
      assert count() == 2

      outcomes =
        for a <- Durable.Activity.list!(workflow_id: waiting, kinds: ["key_duplicate"]),
            do: a.details["outcome"]

      assert Enum.sort(outcomes) == ["error", "use_existing"]
      assert Durable.Activity.list!(workflow_id: running, kinds: ["key_duplicate"]) == []
    end

    test ":cancel_existing replaces its own holder, and the replacement keeps its place" do
      %{id: replaced} = run_workflow(IndexUpdate, %{"change" => 1}, key: @key)
      {:ok, waiting_rebuild} = start_rebuild()

      {:ok, replacement} = start_update(2, on_duplicate: :cancel_existing)
      assert %{status: :cancelled, holds_key: false} = get(replaced)
      assert %{holds_key: true, runs_after_id: nil} = get(replacement)

      # The rebuild waited for the run that was replaced: it waits for the
      # replacement now.
      jobs = Map.new(claim(), &{&1.id, &1.lock_token})
      assert Map.keys(jobs) |> Enum.sort() == Enum.sort([replacement, waiting_rebuild])
      Executor.execute_workflow(waiting_rebuild, config(), jobs[waiting_rebuild])
      assert %{status: :pending, runs_after_id: ^replacement} = get(waiting_rebuild)
    end

    test ":cancel_existing behind another workflow's run gives its own waiting run the newer input" do
      %{id: running} = run_workflow(IndexRebuild, %{"full" => true}, key: @key)
      {:ok, waiting} = start_update(1)

      assert {:ok, ^waiting} = start_update(2, on_duplicate: :cancel_existing)
      assert %{status: :pending, input: %{"change" => 2}, runs_after_id: ^running} = get(waiting)
      assert %{status: :waiting, holds_key: true} = get(running)

      assert [%{workflow_id: ^waiting, details: %{"outcome" => "cancel_existing"} = details}] =
               Durable.Activity.list!(kinds: ["key_duplicate"])

      assert details["runs_after"] == waiting
    end
  end

  # A run being rolled back keeps its key until its undo has run: the undo
  # writes what the next run of the key works on.
  describe "a run being rolled back" do
    test "keeps the key while it undoes: an update asked for meanwhile waits for it" do
      %{id: rebuild} = run_workflow(SwappingRebuild, %{"start" => "update"}, key: @key)
      assert finish(rebuild).status == :compensated

      assert [update] = runs_of("update_index", rebuild)
      assert %{holds_key: false, runs_after_id: ^rebuild} = get(update)
      assert %{status: :compensated, holds_key: true} = get(rebuild)
      assert %{holds_key: true, runs_after_id: nil} = claim_and_run(update)
    end

    test "isn't handed to a start of its own workflow: that one waits for the undo" do
      %{id: rebuild} = run_workflow(SwappingRebuild, %{"start" => "swap"}, key: @key)
      assert finish(rebuild).status == :compensated

      assert [again] = runs_of("swap_index", rebuild)
      assert %{holds_key: false, runs_after_id: ^rebuild} = get(again)
    end

    test "cancelled with rollback: true, keeps the key until its undo has run" do
      %{id: rebuild} = run_workflow(SwappingRebuild, %{}, key: @key)
      :ok = Durable.cancel(rebuild, "wrong account", rollback: true)
      assert %{status: :pending, holds_key: true} = get(rebuild)

      {:ok, update} = start_update(1)
      {:ok, again} = Durable.start(SwappingRebuild, %{}, key: @key)
      assert again not in [rebuild, update]
      assert %{holds_key: false, runs_after_id: ^rebuild} = get(update)
      assert %{holds_key: false, runs_after_id: ^update} = get(again)

      undone = claim_and_run(rebuild)
      assert undone.holds_key and undone.status in WorkflowExecution.closed_statuses()
      assert %{holds_key: true, runs_after_id: nil} = claim_and_run(update)
    end

    test "keeps it by the scope it was started under, after a deploy took the scope away" do
      %{id: swap} = run_workflow(UnscopedSwap, %{}, key: @key)
      started_under!(swap, "account_index")
      assert finish(swap).status == :compensated

      assert [update] = runs_of("update_index", swap)
      assert [again] = runs_of("swap_index_unscoped", swap)
      assert %{holds_key: false, runs_after_id: ^swap} = get(update)
      assert %{holds_key: false, runs_after_id: ^swap} = get(again)
    end
  end

  # The line is kept in start order when a run in the middle of it goes.
  describe "a run of the line cancelled" do
    test "the run behind it waits again behind the run before it, not the holder" do
      %{id: holder} = run_workflow(IndexUpdate, %{"change" => 1}, key: @key)
      {:ok, rebuild} = start_rebuild()
      {:ok, audit} = start_audit()
      {:ok, update} = start_update(2)
      assert get(update).runs_after_id == audit

      :ok = Durable.cancel(audit, "not needed")

      assert %{status: :pending, holds_key: false, runs_after_id: ^rebuild} =
               claim_and_run(update)

      assert finish(holder).status == :completed
      assert %{holds_key: true} = claim_and_run(rebuild)
    end

    test "the run behind it doesn't take the key ahead of a run started before it" do
      %{id: holder} = run_workflow(IndexUpdate, %{"change" => 1}, key: @key)
      {:ok, rebuild} = start_rebuild()
      {:ok, audit} = start_audit()
      {:ok, update} = start_update(2)

      :ok = Durable.cancel(audit, "not needed")
      assert finish(holder).status == :completed

      jobs = Map.new(claim(), &{&1.id, &1.lock_token})
      assert Enum.sort(Map.keys(jobs)) == Enum.sort([rebuild, update])

      Executor.execute_workflow(update, config(), jobs[update])
      assert %{status: :pending, holds_key: false, runs_after_id: ^rebuild} = get(update)

      Executor.execute_workflow(rebuild, config(), jobs[rebuild])
      assert %{status: :waiting, holds_key: true} = get(rebuild)
    end
  end

  describe "a workflow that changed its key_scope" do
    test "still meets its run from before" do
      %{id: before} = run_workflow(IndexUpdate, %{"change" => 1}, key: @key)
      started_under!(before, nil)

      {:ok, waiting} = start_update(2)
      assert %{runs_after_id: ^before, holds_key: false} = get(waiting)
    end

    test "the new scope's other workflows don't" do
      %{id: before} = run_workflow(IndexUpdate, %{"change" => 1}, key: @key)
      started_under!(before, nil)

      {:ok, rebuild} = start_rebuild()
      assert %{holds_key: true, runs_after_id: nil} = get(rebuild)
    end

    test "the old scope's other workflows still do" do
      %{id: before} = run_workflow(Articles, %{}, key: @key, workflow: "process_article")
      started_under!(before, "account_index")

      {:ok, rebuild} = start_rebuild()
      assert %{holds_key: false, runs_after_id: ^before} = get(rebuild)
    end
  end

  test "a shared key is listed for each workflow, with the run of the scope that holds it" do
    %{id: rebuild} = run_workflow(IndexRebuild, %{"full" => true}, key: @key)
    {:ok, update} = start_update(1)

    rows =
      Map.new(Durable.Query.list_keys!(), fn row ->
        {row.workflow_name,
         Map.take(row, [
           :key_scope,
           :holder_id,
           :holder_status,
           :holder_workflow_module,
           :holder_workflow_name
         ])}
      end)

    held = %{
      key_scope: "account_index",
      holder_id: rebuild,
      holder_status: :waiting,
      holder_workflow_module: to_string(IndexRebuild),
      holder_workflow_name: "rebuild_index"
    }

    assert rows == %{"rebuild_index" => held, "update_index" => held}
    assert length(Durable.Query.list_keys!(holder_status: :waiting)) == 2
    assert Durable.Query.count_keys!(holder_status: :waiting) == 2
    assert Durable.Query.list_keys!(holder_status: :running) == []

    ids = for run <- Durable.list_executions!(key: @key), do: run.id
    assert Enum.sort(ids) == Enum.sort([rebuild, update])
    assert {:ok, %{key_scope: "account_index"}} = Durable.get_execution(update)
  end

  test "an unscoped key is listed as before, its holder of its own workflow" do
    %{id: held} = run_workflow(Articles, %{}, key: "article:42", workflow: "process_article")

    assert [%{key_scope: nil, holder_id: ^held, holder_workflow_name: "process_article"}] =
             Durable.Query.list_keys!()

    assert {:ok, %{key_scope: nil}} = Durable.get_execution(held)
  end

  describe "workflows without key_scope" do
    test "keep keys of their own, in one module too" do
      %{id: first} = run_workflow(Articles, %{}, key: "article:42", workflow: "process_article")

      {:ok, second} = Durable.start(Articles, %{}, key: "article:42", workflow: "index_article")
      assert second != first
      assert %{holds_key: true, runs_after_id: nil} = get(second)
    end

    test "don't wait for a scoped workflow's run of the same key" do
      %{id: scoped} = run_workflow(IndexRebuild, %{"full" => true}, key: "article:42")
      {:ok, unscoped} = Durable.start(Articles, %{}, key: "article:42", workflow: "index_article")

      assert unscoped != scoped
      assert %{holds_key: true, runs_after_id: nil} = get(unscoped)
    end
  end

  describe "definitions" do
    defp define(body) do
      name = "KeyScope#{System.unique_integer([:positive])}"
      source = "defmodule #{name} do\n  use Durable\n#{body}\nend"
      [{module, _bytecode}] = Code.compile_string(source)
      module
    end

    defp refused(body) do
      {error, printed} = with_io(:stderr, fn -> catch_error(define(body)) end)
      Exception.message(error) <> printed
    end

    defp workflow(opts),
      do: ~s|workflow "w", #{opts} do\n  step :work, fn d -> {:ok, d} end\nend|

    test "a key_scope with a reuse: that keeps a finished run's key is refused" do
      for reuse <- [":after_failure", ":never"] do
        assert refused(workflow(~s|key_scope: "account_index", reuse: #{reuse}|)) =~
                 "key_scope: needs reuse: :after_close"
      end
    end

    test "a key_scope that isn't a non-empty string is refused" do
      for scope <- [~s|""|, ":account_index", "42"] do
        assert refused(workflow("key_scope: #{scope}")) =~ "invalid key_scope"
      end
    end

    # Ecto's cast took " " for nil: the two held one key at once.
    test "a blank key_scope is a scope like any other" do
      [first, second] = for _ <- 1..2, do: define(workflow(~s|key_scope: " "|))
      {:ok, holder} = Durable.start(first, %{}, key: @key)
      {:ok, waiting} = Durable.start(second, %{}, key: @key)

      assert %{key_scope: " ", holds_key: true} = get(holder)
      assert %{key_scope: " ", holds_key: false, runs_after_id: ^holder} = get(waiting)
    end

    test "key_scope: is set on the workflow, not per call" do
      assert_raise ArgumentError, ~r/key_scope: is set on the workflow/, fn ->
        Durable.start(IndexUpdate, %{}, key: @key, key_scope: "other")
      end
    end
  end
end
