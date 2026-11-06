defmodule Durable.WorkflowKeysTest do
  @moduledoc """
  Workflow keys: `Durable.start(..., key: k)` creates at most one run per
  workflow and key. The run that holds a key has `holds_key`; status is not
  part of the constraint, so only a start, a retry, `release_key/2` or
  pruning moves a key.
  """
  use Durable.DataCase, async: false

  alias Durable.Activity
  alias Durable.Config
  alias Durable.Executor
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Storage.Schemas.WorkflowExecution
  alias Ecto.Adapters.SQL.Sandbox

  defmodule Article do
    @moduledoc false
    use Durable

    workflow "process_article", reuse: :after_failure do
      step :work, fn data ->
        if Process.get({__MODULE__, :broken}), do: raise("cms is down")
        {:ok, data}
      end
    end
  end

  defmodule Again do
    @moduledoc false
    use Durable

    workflow "again" do
      step :work, fn data -> {:ok, data} end
    end
  end

  defmodule Once do
    @moduledoc false
    use Durable

    workflow "once", reuse: :never do
      step :work, fn data -> {:ok, data} end
    end
  end

  defmodule Strict do
    @moduledoc false
    use Durable

    workflow "strict", on_duplicate: :error do
      step :work, fn data -> {:ok, data} end
    end
  end

  defmodule KeyedParallel do
    @moduledoc false
    use Durable

    workflow "keyed_parallel", reuse: :after_close do
      step :setup, fn data -> {:ok, data} end

      parallel do
        step :left, fn data -> {:ok, data} end

        step :right, fn data ->
          if Process.get({Article, :broken}), do: raise("right is broken")
          {:ok, data}
        end
      end
    end
  end

  setup do
    Process.delete({Article, :broken})
    %{config: Config.get(Durable)}
  end

  defp repo, do: Config.get(Durable).repo
  defp reload(id), do: repo().get!(WorkflowExecution, id)

  defp runs_with(key) do
    repo().all(from(w in WorkflowExecution, where: w.key == ^key, order_by: w.inserted_at))
  end

  # A run that holds `key`, in any status, without running anything.
  defp holder!(module, key, status) do
    {:ok, definition} = module.__default_workflow__()

    repo().insert!(%WorkflowExecution{
      workflow_module: Atom.to_string(module),
      workflow_name: definition.name,
      status: status,
      input: %{"id" => 42},
      key: key,
      holds_key: true
    })
  end

  defp activity(kind), do: Activity.list(kinds: [kind])

  describe "start/3 with a key" do
    test "the same key twice returns the same run and creates one row" do
      {:ok, id} = Durable.start(Article, %{"id" => 42}, key: "article:42")
      assert {:ok, ^id} = Durable.start(Article, %{"id" => 42}, key: "article:42")

      assert [%{id: ^id, holds_key: true, key: "article:42"}] = runs_with("article:42")
    end

    test "keys are scoped per workflow" do
      {:ok, a} = Durable.start(Article, %{}, key: "shared:1")
      {:ok, b} = Durable.start(Again, %{}, key: "shared:1")

      assert a != b
      assert Enum.all?(runs_with("shared:1"), & &1.holds_key)
    end

    test "without a key nothing changes" do
      {:ok, a} = Durable.start(Article, %{})
      {:ok, b} = Durable.start(Article, %{})
      assert a != b
      assert %{key: nil, holds_key: false} = reload(a)
    end

    test "on_duplicate: :error returns the holder in an error" do
      {:ok, id} = Durable.start(Article, %{}, key: "article:1")

      assert {:error, {:key_taken, ^id}} =
               Durable.start(Article, %{}, key: "article:1", on_duplicate: :error)
    end

    test "the workflow's on_duplicate is the default, and a call can override it" do
      {:ok, id} = Durable.start(Strict, %{}, key: "s:1")
      assert {:error, {:key_taken, ^id}} = Durable.start(Strict, %{}, key: "s:1")
      assert {:ok, ^id} = Durable.start(Strict, %{}, key: "s:1", on_duplicate: :use_existing)
    end

    test "a duplicate creates, broadcasts and runs nothing", %{config: config} do
      {:ok, id} = Durable.start(Again, %{}, key: "quiet")
      Durable.PubSub.subscribe(config, Durable.PubSub.workflows_topic(config))

      assert {:ok, ^id} = Durable.start(Again, %{}, key: "quiet", inline: true)

      refute_receive {:durable_event, :workflow_started, _}, 50
      assert reload(id).status == :pending
    end

    test "an invalid key is a changeset error" do
      assert {:error, %Ecto.Changeset{}} = Durable.start(Article, %{}, key: "")

      assert {:error, %Ecto.Changeset{}} =
               Durable.start(Article, %{}, key: String.duplicate("k", 256))

      assert {:error, %Ecto.Changeset{}} = Durable.start(Article, %{}, key: 42)
      assert runs_with("") == []
    end

    test "reuse: is the workflow's, not the call's" do
      assert_raise ArgumentError, ~r/reuse: is set on the workflow/, fn ->
        Durable.start(Article, %{}, key: "a", reuse: :never)
      end

      assert_raise ArgumentError, ~r/invalid on_duplicate/, fn ->
        Durable.start(Article, %{}, key: "a", on_duplicate: :replace)
      end
    end

    test "the workflow macro rejects an unknown reuse: policy at compile time" do
      assert_raise ArgumentError, ~r/invalid reuse: :sometimes/, fn ->
        Code.compile_string("""
        defmodule Durable.WorkflowKeysTest.BadReuse do
          use Durable

          workflow "bad", reuse: :sometimes do
            step :work, fn data -> {:ok, data} end
          end
        end
        """)
      end
    end
  end

  # Every cell of the key table: whether a start may take the key from a holder
  # in each status, under each policy.
  @open [:pending, :running, :waiting, :compensating]
  @table %{
    Again => %{
      completed: :free,
      failed: :free,
      cancelled: :free,
      compensated: :free,
      compensation_failed: :free
    },
    Article => %{
      completed: :taken,
      failed: :free,
      cancelled: :free,
      compensated: :free,
      compensation_failed: :free
    },
    Once => %{
      completed: :taken,
      failed: :taken,
      cancelled: :taken,
      compensated: :taken,
      compensation_failed: :taken
    }
  }

  describe "the key table" do
    for {module, closed} <- @table,
        status <- @open ++ Map.keys(closed) do
      expected = Map.get(closed, status, :taken)

      if expected == :taken do
        test "#{inspect(module)}: a #{status} holder keeps its key" do
          holder = holder!(unquote(module), "k", unquote(status))

          assert {:ok, holder.id} == Durable.start(unquote(module), %{}, key: "k")

          assert {:error, {:key_taken, holder.id}} ==
                   Durable.start(unquote(module), %{}, key: "k", on_duplicate: :error)

          assert [_] = runs_with("k")
        end
      else
        test "#{inspect(module)}: a #{status} holder hands its key over" do
          holder = holder!(unquote(module), "k", unquote(status))

          {:ok, new_id} = Durable.start(unquote(module), %{}, key: "k", on_duplicate: :error)

          assert new_id != holder.id
          assert %{holds_key: false, status: unquote(status)} = reload(holder.id)
          assert %{holds_key: true} = reload(new_id)
        end
      end
    end
  end

  describe "tracking" do
    test "a duplicate records key_duplicate and says whether the input changed" do
      Durable.TelemetryHandler.attach_events([[:durable, :key, :duplicate]])
      {:ok, id} = Durable.start(Article, %{"id" => 42, "rev" => 6}, key: "article:42")

      {:ok, ^id} = Durable.start(Article, %{id: 42, rev: 6}, key: "article:42")
      {:ok, ^id} = Durable.start(Article, %{"id" => 42, "rev" => 7}, key: "article:42")

      [changed, same] = activity("key_duplicate")
      assert changed.workflow_id == id

      assert %{
               "key" => "article:42",
               "workflow" => "process_article",
               "outcome" => "use_existing",
               "holder_status" => "pending",
               "input_changed" => true,
               "input" => %{"id" => 42, "rev" => 7}
             } = stringify(changed.details)

      assert %{"input_changed" => false} = details = stringify(same.details)
      refute Map.has_key?(details, "input")

      assert_receive {:event, :duplicate, %{count: 1}, %{holder_id: ^id, input_changed: false}}
      assert_receive {:event, :duplicate, %{count: 1}, %{holder_id: ^id, input_changed: true}}
    end

    test "a hand-off records key_handed_off on the new run" do
      Durable.TelemetryHandler.attach_events([[:durable, :key, :handoff]])
      old = holder!(Again, "k", :completed)

      {:ok, new_id} = Durable.start(Again, %{}, key: "k")

      assert [%{workflow_id: ^new_id, details: details}] = activity("key_handed_off")

      assert %{"from" => from, "from_status" => "completed", "reuse" => "after_close"} =
               stringify(details)

      assert from == old.id
      old_id = old.id
      assert_receive {:event, :handoff, _, %{from: ^old_id, to: ^new_id}}
    end
  end

  describe "inside the caller's transaction" do
    test "a duplicate leaves the transaction usable", %{config: config} do
      {:ok, id} = Durable.start(Article, %{}, key: "tx")

      assert {:ok, :done} =
               config.repo.transaction(fn ->
                 {:ok, ^id} = Durable.start(Article, %{}, key: "tx")

                 {:error, {:key_taken, ^id}} =
                   Durable.start(Article, %{}, key: "tx", on_duplicate: :error)

                 {:ok, _} = Durable.start(Again, %{}, key: "tx-other")
                 :done
               end)

      assert length(activity("key_duplicate")) == 2
    end

    test "rolling the transaction back frees the key", %{config: config} do
      {:error, :rollback} =
        config.repo.transaction(fn ->
          {:ok, _} = Durable.start(Article, %{}, key: "rolled")
          config.repo.rollback(:rollback)
        end)

      assert runs_with("rolled") == []
      assert {:ok, _} = Durable.start(Article, %{}, key: "rolled")
    end
  end

  describe "retry/2" do
    setup %{config: config} do
      Process.put({Article, :broken}, true)
      {:ok, old_id} = Durable.start(Article, %{"id" => 7}, key: "article:7")
      Executor.execute_workflow(old_id, config)
      Process.delete({Article, :broken})
      assert %{status: :failed, holds_key: true} = reload(old_id)
      %{old_id: old_id}
    end

    test "a run that still holds its key retries as before", %{old_id: old_id} do
      assert {:ok, ^old_id} = Durable.retry(old_id)
      assert %{status: :pending, holds_key: true} = reload(old_id)
    end

    test "is refused while a newer run holds the key", %{old_id: old_id, config: config} do
      {:ok, new_id} = Durable.start(Article, %{"id" => 7}, key: "article:7")
      assert %{holds_key: false} = reload(old_id)

      assert {:error, {:key_taken, ^new_id}} = Durable.retry(old_id)
      assert reload(old_id).status == :failed

      # :after_failure: a completed run keeps its key, so retry stays refused.
      Executor.execute_workflow(new_id, config)
      assert reload(new_id).status == :completed
      assert {:error, {:key_taken, ^new_id}} = Durable.retry(old_id)
    end

    test "takes the key back from a newer run that failed", %{old_id: old_id, config: config} do
      {:ok, new_id} = Durable.start(Article, %{"id" => 7}, key: "article:7")
      Process.put({Article, :broken}, true)
      Executor.execute_workflow(new_id, config)
      assert reload(new_id).status == :failed

      assert {:ok, ^old_id} = Durable.retry(old_id)
      assert %{status: :pending, holds_key: true} = reload(old_id)
      assert %{holds_key: false} = reload(new_id)
      assert [%{workflow_id: ^old_id, details: details}] = activity("key_retaken")
      assert stringify(details)["from"] == new_id
    end

    test "takes a released key back", %{old_id: old_id} do
      :ok = Durable.release_key(old_id)
      assert {:ok, ^old_id} = Durable.retry(old_id)
      assert %{holds_key: true} = reload(old_id)
    end
  end

  describe "retry/2 inside a parallel block" do
    import Durable.DataCase, only: [execute_children: 3, get_child_executions: 2]

    test "is refused whole while another run holds the key", %{config: config} do
      Process.put({Article, :broken}, true)
      {:ok, parent_id} = Durable.start(KeyedParallel, %{}, key: "p:1")
      Executor.execute_workflow(parent_id, config)
      execute_children(config.repo, parent_id, config)
      Executor.execute_workflow(parent_id, config)
      Process.delete({Article, :broken})
      assert reload(parent_id).status == :failed

      {:ok, new_id} = Durable.start(KeyedParallel, %{}, key: "p:1")
      assert new_id != parent_id

      children_before =
        Enum.map(get_child_executions(config.repo, parent_id), &{&1.id, &1.status})

      assert {:error, {:key_taken, ^new_id}} = Durable.retry(parent_id)
      assert reload(parent_id).status == :failed

      assert Enum.map(get_child_executions(config.repo, parent_id), &{&1.id, &1.status}) ==
               children_before
    end
  end

  describe "status changes never move a key" do
    test "cancel keeps holds_key" do
      {:ok, id} = Durable.start(Again, %{}, key: "c")
      :ok = Durable.cancel(id)
      assert %{status: :cancelled, holds_key: true} = reload(id)
    end

    test "running to completion keeps holds_key", %{config: config} do
      {:ok, id} = Durable.start(Again, %{}, key: "done")
      Executor.execute_workflow(id, config)
      assert %{status: :completed, holds_key: true} = reload(id)
    end

    test "reschedule leaves a finished run alone", %{config: config} do
      holder = holder!(Again, "r", :completed)
      assert {:error, :finished} = Postgres.reschedule(config, holder.id, DateTime.utc_now())
      assert reload(holder.id).status == :completed
    end
  end

  describe "rerun/2" do
    test "keeps the key and is refused while the key is held" do
      holder = holder!(Once, "once:1", :completed)
      assert {:error, {:key_taken, holder_id}} = Durable.rerun(holder.id)
      assert holder_id == holder.id

      :ok = Durable.release_key(holder.id)
      {:ok, new_id} = Durable.rerun(holder.id)
      assert %{key: "once:1", holds_key: true, trigger: :rerun} = reload(new_id)
    end

    test "takes the key when reuse: allows it" do
      holder = holder!(Again, "again:1", :completed)
      {:ok, new_id} = Durable.rerun(holder.id)
      assert %{holds_key: true} = reload(new_id)
      assert %{holds_key: false} = reload(holder.id)
    end
  end

  describe "release_key/2" do
    test "frees a finished holder's key and records who did it" do
      Durable.TelemetryHandler.attach_events([[:durable, :key, :release]])
      holder = holder!(Once, "once:2", :completed)

      assert :ok = Durable.release_key(holder.id, by: "ops")
      assert %{holds_key: false, key: "once:2"} = reload(holder.id)
      assert [%{details: details}] = activity("key_released")
      assert stringify(details)["by"] == "ops"
      assert_receive {:event, :release, _, %{by: "ops"}}

      {:ok, new_id} = Durable.start(Once, %{}, key: "once:2")
      assert new_id != holder.id
    end

    test "refuses an open run, a run without a key and an unknown id" do
      {:ok, open} = Durable.start(Again, %{}, key: "open")
      {:ok, plain} = Durable.start(Again, %{})

      assert {:error, :not_finished} = Durable.release_key(open)
      assert {:error, :no_key} = Durable.release_key(plain)
      assert {:error, :not_found} = Durable.release_key(Ecto.UUID.generate())
    end
  end

  test "deleting the holder (pruning) frees the key" do
    holder = holder!(Once, "pruned", :completed)
    repo().delete!(holder)
    assert {:ok, id} = Durable.start(Once, %{}, key: "pruned")
    assert id != holder.id
  end

  test "Query filters by key and shows the holder" do
    {:ok, id} = Durable.start(Article, %{}, key: "q:1")
    {:ok, _} = Durable.start(Article, %{}, key: "q:2")

    assert [%{id: ^id, key: "q:1", holds_key: true}] = Durable.Query.list_executions(key: "q:1")
    assert Durable.Query.count_executions(key: "q:1") == 1
  end

  test "Stats.keys/1 and Activity.list/1 count what happened to keys" do
    {:ok, id} = Durable.start(Article, %{"rev" => 1}, key: "a:1")
    {:ok, ^id} = Durable.start(Article, %{"rev" => 1}, key: "a:1")
    {:ok, ^id} = Durable.start(Article, %{"rev" => 2}, key: "a:1")
    {:error, _} = Durable.start(Article, %{"rev" => 3}, key: "a:1", on_duplicate: :error)
    holder!(Again, "b:1", :completed)
    {:ok, _} = Durable.start(Again, %{}, key: "b:1")

    stats = Durable.Stats.keys(workflow: "process_article")

    assert %{keyed: true, held: 1, readded: 3, dropped: 1, errors: 1, handed_off: 0} = stats

    assert [%{key: "a:1", readded: 3, dropped: 1, holder_id: ^id, holder_status: :pending}] =
             stats.top

    assert Enum.sum(Enum.map(stats.timeline, & &1.returned)) == 2
    assert Enum.sum(Enum.map(stats.timeline, & &1.errors)) == 1

    assert %{handed_off: 1, readded: 0} = Durable.Stats.keys(workflow: "again")
    assert %{keyed: false, held: 0} = Durable.Stats.keys(workflow: "once")

    assert length(Activity.list(workflow_id: id)) == 3
    assert Activity.list(workflow_id: id, kinds: ["key_handed_off"]) == []
  end

  describe "concurrent starts" do
    # The SQL sandbox shares one connection, which would serialize these
    # starts. Each task takes a real connection instead, so the inserts race.
    @tag :race
    test "make exactly one run" do
      key = "race:#{System.unique_integer([:positive])}"

      ids =
        1..20
        |> Task.async_stream(
          fn _ ->
            Sandbox.unboxed_run(Durable.TestRepo, fn -> Durable.start(Again, %{}, key: key) end)
          end,
          max_concurrency: 20
        )
        |> Enum.map(fn {:ok, {:ok, id}} -> id end)

      Sandbox.unboxed_run(Durable.TestRepo, fn ->
        rows = repo().all(from(w in WorkflowExecution, where: w.key == ^key))
        repo().delete_all(from(w in WorkflowExecution, where: w.key == ^key))

        repo().delete_all(
          from(a in Durable.Storage.Schemas.ActivityEvent,
            where: fragment("?->>'key' = ?", a.details, ^key)
          )
        )

        assert [%{id: id}] = rows
        assert Enum.uniq(ids) == [id]
      end)
    end
  end

  defp stringify(map), do: map |> Jason.encode!() |> Jason.decode!()
end
