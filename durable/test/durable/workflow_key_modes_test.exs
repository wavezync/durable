defmodule Durable.WorkflowKeyModesTest do
  @moduledoc """
  What a start does when its key is taken, beyond returning the holder:
  `on_duplicate: :cancel_existing`, `on_duplicate: {:send_event, name}` and a
  workflow's `debounce:`. Plus the key listing behind the dashboard's Keys page.
  """
  use Durable.DataCase, async: false

  alias Durable.Activity
  alias Durable.Config
  alias Durable.Executor
  alias Durable.Storage.Schemas.{PendingEvent, WorkflowExecution}

  defmodule Article do
    @moduledoc false
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "keyed_article", reuse: :after_failure do
      step :fetch, fn data -> {:ok, data} end

      step :await_update, fn data ->
        {:ok, assign(data, :update, wait_for_event("article_updated"))}
      end
    end
  end

  defmodule Once do
    @moduledoc false
    use Durable

    workflow "keyed_once", reuse: :never, on_duplicate: :cancel_existing do
      step :work, fn data -> {:ok, data} end
    end
  end

  defmodule Debounced do
    @moduledoc false
    use Durable

    workflow "keyed_debounced", debounce: [period: 60_000, timeout: 300_000], timeout: 600_000 do
      step :work, fn data -> {:ok, data} end
    end
  end

  setup do
    %{config: Config.get(Durable)}
  end

  defp repo, do: Config.get(Durable).repo
  defp reload(id), do: repo().get!(WorkflowExecution, id)
  defp set!(id, changes), do: id |> reload() |> Ecto.Changeset.change(changes) |> repo().update!()

  defp duplicates do
    for a <- Activity.list(kinds: ["key_duplicate"]), do: stringify(a.details)
  end

  defp holder!(module, key, status) do
    {:ok, definition} = module.__default_workflow__()

    repo().insert!(%WorkflowExecution{
      workflow_module: Atom.to_string(module),
      workflow_name: definition.name,
      status: status,
      input: %{},
      key: key,
      holds_key: true
    })
  end

  describe "on_duplicate: :cancel_existing" do
    test "cancels the open holder and starts a new run with the new input" do
      {:ok, old} = Durable.start(Article, %{"rev" => 1}, key: "a:1")

      {:ok, new} =
        Durable.start(Article, %{"rev" => 2}, key: "a:1", on_duplicate: :cancel_existing)

      assert new != old
      assert %{status: :cancelled, holds_key: false, error: error} = reload(old)
      assert error["replaced_by"] == new or error[:replaced_by] == new
      assert %{holds_key: true, input: %{"rev" => 2}, status: :pending} = reload(new)

      assert [%{"outcome" => "cancel_existing", "input_changed" => true}] = duplicates()

      assert [%{workflow_id: ^new, details: handoff}] = Activity.list(kinds: ["key_handed_off"])

      assert %{"from" => ^old, "from_status" => "pending", "replaced" => true} =
               stringify(handoff)
    end

    test "replaces a holder even under reuse: :never, the workflow's default here" do
      {:ok, old} = Durable.start(Once, %{}, key: "o:1")
      {:ok, new} = Durable.start(Once, %{"again" => true}, key: "o:1")

      assert new != old
      assert reload(old).status == :cancelled
    end

    test "cancels a waiting holder", %{config: config} do
      {:ok, old} = Durable.start(Article, %{}, key: "a:wait")
      Executor.execute_workflow(old, config)
      assert reload(old).status == :waiting

      {:ok, new} = Durable.start(Article, %{}, key: "a:wait", on_duplicate: :cancel_existing)
      assert new != old
      assert reload(old).status == :cancelled
    end

    test "a holder it can't cancel keeps the key, and the start gets an error" do
      compensating = holder!(Article, "a:comp", :compensating)
      completed = holder!(Once, "o:done", :completed)

      assert {:error, {:key_taken, compensating.id}} ==
               Durable.start(Article, %{}, key: "a:comp", on_duplicate: :cancel_existing)

      assert {:error, {:key_taken, completed.id}} == Durable.start(Once, %{}, key: "o:done")
      assert reload(compensating.id).status == :compensating
      assert reload(completed.id).holds_key
    end
  end

  describe "on_duplicate: {:send_event, name}" do
    @send {:send_event, "article_updated"}

    test "delivers the new input to a holder waiting for the event", %{config: config} do
      {:ok, id} = Durable.start(Article, %{"rev" => 1}, key: "s:1")
      Executor.execute_workflow(id, config)
      assert reload(id).status == :waiting

      assert {:ok, ^id} = Durable.start(Article, %{"rev" => 2}, key: "s:1", on_duplicate: @send)

      assert reload(id).status == :pending
      Executor.execute_workflow(id, config)

      assert %{status: :completed, context: context} = reload(id)
      assert context["update"] == %{"rev" => 2}
      assert [%{"outcome" => "send_event", "event" => "article_updated"}] = duplicates()
    end

    test "keeps the event until the holder waits for it, and delivers the newest", %{
      config: config
    } do
      {:ok, id} = Durable.start(Article, %{"rev" => 1}, key: "s:2")

      {:ok, ^id} = Durable.start(Article, %{"rev" => 2}, key: "s:2", on_duplicate: @send)
      {:ok, ^id} = Durable.start(Article, %{"rev" => 3}, key: "s:2", on_duplicate: @send)

      assert repo().aggregate(from(p in PendingEvent, where: p.status == :buffered), :count) == 2

      # It reaches wait_for_event, finds the newest kept event, and resumes.
      Executor.execute_workflow(id, config)
      assert reload(id).status == :pending
      assert repo().aggregate(from(p in PendingEvent, where: p.status == :buffered), :count) == 0

      Executor.execute_workflow(id, config)
      assert %{status: :completed, context: %{"update" => %{"rev" => 3}}} = reload(id)
    end

    test "a finished holder that reuse: keeps answers with an error" do
      completed = holder!(Article, "s:done", :completed)

      assert {:error, {:key_taken, completed.id}} ==
               Durable.start(Article, %{}, key: "s:done", on_duplicate: @send)
    end

    test "send_event buffering on its own" do
      {:ok, id} = Durable.start(Article, %{}, key: "s:3")
      finished = holder!(Article, "s:fin", :completed)

      assert {:error, :not_found} = Durable.send_event(id, "article_updated", %{})
      assert :ok = Durable.send_event(id, "article_updated", "just a string", buffer: true)
      assert {:error, :finished} = Durable.send_event(finished.id, "x", %{}, buffer: true)

      assert {:error, :not_found} =
               Durable.send_event(Ecto.UUID.generate(), "x", %{}, buffer: true)
    end
  end

  describe "debounce:" do
    test "a keyed start waits out the period" do
      before = DateTime.utc_now()
      {:ok, id} = Durable.start(Debounced, %{}, key: "d:1")

      run = reload(id)
      assert DateTime.diff(run.scheduled_at, before, :millisecond) >= 60_000
      assert DateTime.diff(run.deadline_at, run.scheduled_at, :millisecond) == 600_000
    end

    test "a duplicate before it starts replaces the input and restarts the wait" do
      {:ok, id} = Durable.start(Debounced, %{"rev" => 1}, key: "d:2")
      first = reload(id).scheduled_at

      Process.sleep(5)

      assert {:ok, ^id} =
               Durable.start(Debounced, %{"rev" => 2}, key: "d:2", on_duplicate: :error)

      run = reload(id)
      assert run.input == %{"rev" => 2}
      assert DateTime.after?(run.scheduled_at, first)
      assert DateTime.diff(run.deadline_at, run.scheduled_at, :millisecond) == 600_000
      assert [%{"outcome" => "debounced", "input_changed" => true}] = duplicates()
    end

    test "never pushes the start past timeout after the first start" do
      {:ok, id} = Durable.start(Debounced, %{}, key: "d:3")
      long_ago = DateTime.add(DateTime.utc_now(), -290, :second)
      set!(id, inserted_at: long_ago)

      {:ok, ^id} = Durable.start(Debounced, %{"rev" => 2}, key: "d:3")

      assert DateTime.diff(reload(id).scheduled_at, long_ago, :millisecond) == 300_000
    end

    test "once a worker claimed the run, a duplicate is a plain duplicate" do
      {:ok, id} = Durable.start(Debounced, %{"rev" => 1}, key: "d:4")
      set!(id, status: :running, locked_by: "node-1")

      assert {:error, {:key_taken, ^id}} =
               Durable.start(Debounced, %{"rev" => 2}, key: "d:4", on_duplicate: :error)

      assert reload(id).input == %{"rev" => 1}
    end

    test "only keyed starts are debounced" do
      {:ok, id} = Durable.start(Debounced, %{})
      assert reload(id).scheduled_at == nil
    end

    test "is set on the workflow, and checked" do
      assert_raise ArgumentError, ~r/debounce: is set on the workflow/, fn ->
        Durable.start(Debounced, %{}, key: "d:5", debounce: [period: 1])
      end

      assert_raise ArgumentError, ~r/invalid debounce/, fn ->
        Code.compile_string("""
        defmodule Durable.WorkflowKeyModesTest.BadDebounce do
          use Durable

          workflow "bad", debounce: [wait: 10] do
            step :work, fn data -> {:ok, data} end
          end
        end
        """)
      end
    end
  end

  test "Stats.keys/1 counts each outcome" do
    {:ok, _} = Durable.start(Debounced, %{}, key: "st:1")
    {:ok, _} = Durable.start(Debounced, %{"rev" => 2}, key: "st:1")
    {:ok, _} = Durable.start(Article, %{}, key: "st:2")

    {:ok, _} =
      Durable.start(Article, %{"rev" => 2},
        key: "st:2",
        on_duplicate: {:send_event, "article_updated"}
      )

    {:ok, _} = Durable.start(Article, %{"rev" => 3}, key: "st:2", on_duplicate: :cancel_existing)

    assert %{debounced: 1} = Durable.Stats.keys(workflow: "keyed_debounced")
    assert %{sent: 1, replaced: 1, handed_off: 1} = Durable.Stats.keys(workflow: "keyed_article")
  end

  describe "Query.list_keys/1" do
    test "one row per workflow and key, with its holder and re-adds" do
      {:ok, a1} = Durable.start(Article, %{}, key: "k:1")
      {:ok, ^a1} = Durable.start(Article, %{"rev" => 2}, key: "k:1")
      {:ok, a2} = Durable.start(Article, %{}, key: "k:2")
      {:ok, a2b} = Durable.start(Article, %{}, key: "k:2", on_duplicate: :cancel_existing)
      completed = holder!(Once, "k:1", :completed)
      {:ok, _} = Durable.start(Article, %{})

      keys = Durable.Query.list_keys()
      assert length(keys) == 3
      assert Durable.Query.count_keys() == 3

      assert %{runs: 1, holder_id: ^a1, holder_status: :pending, readded: 1, dropped: 1} =
               Enum.find(keys, &(&1.key == "k:1" and &1.workflow_name == "keyed_article"))

      assert %{runs: 2, holder_id: ^a2b} = Enum.find(keys, &(&1.key == "k:2"))
      assert a2 != a2b

      assert [%{workflow_name: "keyed_once", holder_status: :completed}] =
               Durable.Query.list_keys(holder_status: :completed)

      assert completed.id == hd(Durable.Query.list_keys(workflow_name: "keyed_once")).holder_id
      assert [%{key: "k:2"}] = Durable.Query.list_keys(key_prefix: "k:2")
      assert Durable.Query.count_keys(key_prefix: "k:") == 3
      assert Durable.Query.count_keys(key_prefix: "k%") == 0
    end
  end

  defp stringify(map), do: map |> Jason.encode!() |> Jason.decode!()
end
