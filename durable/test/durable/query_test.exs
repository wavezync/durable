defmodule Durable.QueryTest do
  @moduledoc """
  Covers the parent/child-aware query surface used by the dashboard:

    * `top_level_only` / `parent_workflow_id` filters
    * `list_workflows/1` catalog excluding children (no fan-out double-count)
    * `child_counts/2`
    * `parent_workflow_id` exposed on the execution map
  """
  use Durable.DataCase, async: false

  alias Durable.Config
  alias Durable.Query
  alias Durable.Storage.Schemas.WorkflowExecution

  setup do
    config = Config.get(Durable)
    %{config: config, repo: config.repo}
  end

  defp insert_exec(repo, attrs) do
    defaults = %{
      workflow_module: "Elixir.MyApp.SomeWorkflow",
      workflow_name: "some_workflow",
      status: :completed,
      queue: "default",
      priority: 0,
      input: %{},
      context: %{}
    }

    %WorkflowExecution{}
    |> Ecto.Changeset.change(Map.merge(defaults, Map.new(attrs)))
    |> repo.insert!()
  end

  describe "top_level_only / parent_workflow_id filters" do
    test "top_level_only excludes children; parent_workflow_id selects them", %{repo: repo} do
      parent = insert_exec(repo, %{workflow_name: "fan_out", status: :completed})
      _c1 = insert_exec(repo, %{workflow_name: "fan_out", parent_workflow_id: parent.id})
      _c2 = insert_exec(repo, %{workflow_name: "fan_out", parent_workflow_id: parent.id})
      other = insert_exec(repo, %{workflow_name: "lonely", status: :running})

      top = Query.list_executions(top_level_only: true)
      top_ids = MapSet.new(top, & &1.id)

      assert MapSet.member?(top_ids, parent.id)
      assert MapSet.member?(top_ids, other.id)
      refute Enum.any?(top, &(&1.parent_workflow_id != nil))

      kids = Query.list_executions(parent_workflow_id: parent.id)
      assert length(kids) == 2
      assert Enum.all?(kids, &(&1.parent_workflow_id == parent.id))
    end

    test "list_executions_with_total respects top_level_only in both list and count", %{
      repo: repo
    } do
      parent = insert_exec(repo, %{workflow_name: "p"})
      insert_exec(repo, %{workflow_name: "p", parent_workflow_id: parent.id})
      insert_exec(repo, %{workflow_name: "p", parent_workflow_id: parent.id})

      {rows, total} = Query.list_executions_with_total(top_level_only: true)

      assert total == Enum.count(rows)
      assert Enum.all?(rows, &is_nil(&1.parent_workflow_id))
    end
  end

  describe "list_workflows/1 catalog" do
    test "counts only top-level runs — fan-out children don't inflate totals", %{repo: repo} do
      parent = insert_exec(repo, %{workflow_name: "fan_out", workflow_module: "Elixir.FanOut"})

      # 5 children inheriting the parent's (module, name).
      for _ <- 1..5 do
        insert_exec(repo, %{
          workflow_name: "fan_out",
          workflow_module: "Elixir.FanOut",
          parent_workflow_id: parent.id
        })
      end

      row = Enum.find(Query.list_workflows(), &(&1.workflow_name == "fan_out"))

      assert row, "fan_out definition should appear in the catalog"
      # Exactly one top-level run, not 6.
      assert row.total_runs == 1
    end
  end

  describe "child_counts/2" do
    test "returns parent_id => count, omitting childless parents", %{repo: repo} do
      p1 = insert_exec(repo, %{})
      p2 = insert_exec(repo, %{})
      p3 = insert_exec(repo, %{})
      insert_exec(repo, %{parent_workflow_id: p1.id})
      insert_exec(repo, %{parent_workflow_id: p1.id})
      insert_exec(repo, %{parent_workflow_id: p2.id})

      counts = Query.child_counts([p1.id, p2.id, p3.id])

      assert counts[p1.id] == 2
      assert counts[p2.id] == 1
      refute Map.has_key?(counts, p3.id)
    end

    test "empty parent list short-circuits to %{}" do
      assert Query.child_counts([]) == %{}
    end
  end

  describe "execution map" do
    test "exposes parent_workflow_id", %{repo: repo} do
      parent = insert_exec(repo, %{})
      child = insert_exec(repo, %{parent_workflow_id: parent.id})

      {:ok, map} = Query.get_execution(child.id)
      assert map.parent_workflow_id == parent.id

      {:ok, parent_map} = Query.get_execution(parent.id)
      assert parent_map.parent_workflow_id == nil
    end
  end

  describe "id / id_prefix / status-list / time filters" do
    test "id selects an exact execution", %{repo: repo} do
      a = insert_exec(repo, %{workflow_name: "a"})
      _b = insert_exec(repo, %{workflow_name: "b"})

      rows = Query.list_executions(id: a.id)

      assert Enum.map(rows, & &1.id) == [a.id]
    end

    test "id_prefix matches the leading slice of the uuid", %{repo: repo} do
      a = insert_exec(repo, %{workflow_name: "a"})
      _b = insert_exec(repo, %{workflow_name: "b"})
      prefix = String.slice(a.id, 0, 8)

      rows = Query.list_executions(id_prefix: prefix)

      assert Enum.any?(rows, &(&1.id == a.id))
      assert Enum.all?(rows, &String.starts_with?(&1.id, prefix))
    end

    test "status accepts a list and matches any (IN)", %{repo: repo} do
      f = insert_exec(repo, %{status: :failed})
      r = insert_exec(repo, %{status: :running})
      _c = insert_exec(repo, %{status: :completed})

      rows = Query.list_executions(status: [:failed, :running])
      ids = MapSet.new(rows, & &1.id)

      assert MapSet.member?(ids, f.id)
      assert MapSet.member?(ids, r.id)
      refute Enum.any?(rows, &(&1.status == :completed))
    end

    test "single status atom still filters", %{repo: repo} do
      f = insert_exec(repo, %{status: :failed})
      _c = insert_exec(repo, %{status: :completed})

      rows = Query.list_executions(status: :failed)

      assert Enum.any?(rows, &(&1.id == f.id))
      assert Enum.all?(rows, &(&1.status == :failed))
    end

    test "from bounds results by inserted_at", %{repo: repo} do
      now = DateTime.utc_now()

      old =
        insert_exec(repo, %{workflow_name: "old", inserted_at: DateTime.add(now, -3_600, :second)})

      recent = insert_exec(repo, %{workflow_name: "recent"})

      rows = Query.list_executions(from: DateTime.add(now, -60, :second))
      ids = MapSet.new(rows, & &1.id)

      assert MapSet.member?(ids, recent.id)
      refute MapSet.member?(ids, old.id)
    end
  end
end
