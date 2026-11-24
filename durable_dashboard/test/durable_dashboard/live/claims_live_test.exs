defmodule DurableDashboard.Live.ClaimsLiveTest do
  @moduledoc """
  What a run's lock says (ARCHITECTURE rules 30 and 33): a stopped run whose
  worker still has its step, a run of its key waiting for that, a worker whose
  heartbeat is late, a caller running a run inline, and each node's clock.
  """
  use DurableDashboard.LiveCase

  alias Durable.Storage.Schemas.{Node, WorkflowExecution}

  defp repo, do: Durable.Config.get(Durable).repo

  # A run of the Payments fixture, in whatever state the test needs.
  defp run!(attrs) do
    %WorkflowExecution{
      workflow_module: Atom.to_string(Fixtures.Payments),
      workflow_name: "process_payment",
      queue: "default",
      input: %{},
      context: %{},
      started_at: Durable.Clock.utc_now()
    }
    |> Ecto.Changeset.change(attrs)
    |> repo().insert!()
  end

  defp ago(seconds), do: DateTime.add(Durable.Clock.utc_now(), -seconds, :second)

  # Cancelled while a worker on node-a ran its step, which it hasn't stopped.
  defp stopped!(key) do
    run!(%{
      status: :cancelled,
      key: key,
      error: %{"type" => "cancelled"},
      locked_by: "node-a",
      locked_at: ago(1)
    })
  end

  describe "a run cancelled while its worker ran a step" do
    test "says it's still stopping, and what waits for it", %{conn: conn} do
      stopped = stopped!("export:dana")
      {:ok, view, _html} = live(conn, dash("/executions/#{stopped.id}"))

      assert has_element?(view, "[data-claim=stopping]", "Stopping")
      assert has_element?(view, "[data-claim=stopping]", "export:dana")
    end

    test "stops saying so once its worker lets go", %{conn: conn} do
      stopped = stopped!("export:dana")
      {:ok, view, _html} = live(conn, dash("/executions/#{stopped.id}"))

      stopped |> Ecto.Changeset.change(locked_by: nil, locked_at: nil) |> repo().update!()
      send(view.pid, :reload)

      refute has_element?(view, "[data-claim=stopping]")
    end

    test "isn't stopping once its lock has gone stale", %{conn: conn} do
      stale =
        run!(%{status: :cancelled, key: "export:ines", locked_by: "node-a", locked_at: ago(600)})

      {:ok, view, _html} = live(conn, dash("/executions/#{stale.id}"))

      refute has_element?(view, "[data-claim=stopping]")
    end
  end

  test "a run of the key waiting for that step to stop says which run it waits for",
       %{conn: conn} do
    stopped = stopped!("export:dana")
    waiting = run!(%{status: :pending, key: "export:dana", holds_key: true, started_at: nil})

    {:ok, view, _html} = live(conn, dash("/executions/#{waiting.id}"))

    assert has_element?(view, "[data-claim=held-back]", String.slice(stopped.id, 0, 8))
    assert has_element?(view, "[data-claim=held-back]", "export:dana")
  end

  describe "a running run" do
    test "whose worker hasn't heartbeated for two intervals is flagged", %{conn: conn} do
      late =
        run!(%{
          status: :running,
          locked_by: "node-a",
          locked_at: ago(90),
          lock_token: Ecto.UUID.generate()
        })

      {:ok, view, _html} = live(conn, dash("/executions/#{late.id}"))
      assert has_element?(view, "[data-claim=late]", "No heartbeat from its worker on node-a")
    end

    test "whose worker heartbeated just now isn't", %{conn: conn} do
      fine =
        run!(%{
          status: :running,
          locked_by: "node-a",
          locked_at: ago(1),
          lock_token: Ecto.UUID.generate()
        })

      {:ok, view, _html} = live(conn, dash("/executions/#{fine.id}"))
      refute has_element?(view, "[data-claim=late]")
    end

    test "run inline names the caller's node, not a worker", %{conn: conn} do
      inline =
        run!(%{
          status: :running,
          locked_by: "node-a/inline",
          locked_at: ago(1),
          lock_token: Ecto.UUID.generate()
        })

      {:ok, _view, html} = live(conn, dash("/executions/#{inline.id}"))
      assert html =~ "default · inline on node-a"
    end
  end

  test "Queues & nodes shows how far each node's clock is from the database's", %{conn: conn} do
    now = Durable.Clock.utc_now()

    for {id, skew} <- [{"node-b", 2_500}, {"node-c", -40}, {"node-d", nil}] do
      repo().insert!(%Node{
        id: id,
        queues: [],
        started_at: now,
        heartbeat_at: now,
        clock_skew_ms: skew
      })
    end

    {:ok, _view, html} = live(conn, dash("/queues"))

    # node-b is off by more than a second; node-c is in step; node-d is older.
    assert html =~ "2500 ms ahead of the database"
    assert html =~ "40 ms behind the database"
    assert html =~ "Not reported"
  end
end
