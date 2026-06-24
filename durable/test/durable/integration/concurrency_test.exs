defmodule Durable.Integration.ConcurrencyTest do
  @moduledoc """
  Real-concurrency coverage that the shared SQL Sandbox cannot provide.

  Every other DB test runs inside ONE sandboxed connection wrapped in a single
  transaction, so two "concurrent" operations actually serialize and the
  locking primitives (`FOR UPDATE SKIP LOCKED`, `FOR UPDATE` row locks) are
  never contended — a regression that dropped the locks would still pass. These
  tests use `Sandbox.unboxed_run/2` to run against REAL, committed connections
  on separate backends, so the locks are genuinely exercised.

  They commit + truncate, so they're tagged `:integration` and excluded from the
  default suite. Run with: `mix test --only integration`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Durable.Config
  alias Durable.Queue.Adapters.Postgres
  alias Durable.Storage.Schemas.{PendingEvent, WaitGroup, WorkflowExecution}
  alias Ecto.Adapters.SQL.Sandbox

  @repo Durable.TestRepo

  setup do
    start_supervised!({Durable, repo: @repo, queue_enabled: false, pubsub: :start})
    truncate!()
    on_exit(&truncate!/0)
    %{config: Config.get(Durable)}
  end

  defp truncate! do
    Sandbox.unboxed_run(@repo, fn ->
      @repo.query!(
        "TRUNCATE durable.workflow_executions, durable.scheduled_workflows RESTART IDENTITY CASCADE"
      )
    end)
  end

  defp committed(fun), do: Sandbox.unboxed_run(@repo, fun)

  describe "fetch_jobs/4 — FOR UPDATE SKIP LOCKED across real backends" do
    test "two workers claiming concurrently never double-claim a job", %{config: config} do
      committed(fn ->
        for i <- 1..40 do
          @repo.insert!(%WorkflowExecution{
            workflow_module: "Elixir.IntegrationWorkflow",
            workflow_name: "claim_#{i}",
            status: :pending,
            queue: "default",
            priority: 0,
            input: %{},
            context: %{}
          })
        end
      end)

      claim = fn node ->
        committed(fn ->
          config |> Postgres.fetch_jobs("default", 30, node) |> Enum.map(& &1.id)
        end)
      end

      [a, b] =
        [
          Task.async(fn -> claim.("node_a") end),
          Task.async(fn -> claim.("node_b") end)
        ]
        |> Task.await_many(15_000)

      overlap = MapSet.intersection(MapSet.new(a), MapSet.new(b))

      assert MapSet.size(overlap) == 0,
             "two backends claimed the same job(s): #{inspect(MapSet.to_list(overlap))}"

      # Every job is claimed exactly once across the two workers.
      assert length(a) + length(b) == 40
      assert MapSet.size(MapSet.new(a ++ b)) == 40
    end
  end

  describe "WaitGroup.add_event_locked/4 — FOR UPDATE under real contention" do
    test "concurrent sibling completions never lose an event", %{config: _config} do
      # A wait group expecting 8 events, plus its pending event rows.
      event_names = for i <- 1..8, do: "evt_#{i}"

      {wf_id, wg_id} =
        committed(fn ->
          wf =
            @repo.insert!(%WorkflowExecution{
              workflow_module: "Elixir.IntegrationWorkflow",
              workflow_name: "wg_parent",
              status: :waiting,
              queue: "default",
              priority: 0,
              input: %{},
              context: %{}
            })

          wg =
            %WaitGroup{}
            |> WaitGroup.changeset(%{
              workflow_id: wf.id,
              step_name: "fan",
              wait_type: :all,
              event_names: event_names
            })
            |> @repo.insert!()

          for name <- event_names do
            %PendingEvent{}
            |> PendingEvent.changeset(%{
              workflow_id: wf.id,
              event_name: name,
              step_name: "fan",
              wait_group_id: wg.id,
              wait_type: :all
            })
            |> @repo.insert!()
          end

          {wf.id, wg.id}
        end)

      _ = wf_id

      # 8 backends each merge a distinct event concurrently. Each runs inside a
      # transaction (as production does via the executor's Ecto.Multi) so the
      # FOR UPDATE row lock is held across the read-modify-write on
      # received_events and serializes the siblings — without it, concurrent
      # merges overwrite each other and events are lost.
      event_names
      |> Enum.map(fn name ->
        Task.async(fn ->
          committed(fn ->
            @repo.transaction(fn ->
              WaitGroup.add_event_locked(@repo, wg_id, name, %{"ok" => true})
            end)
          end)
        end)
      end)
      |> Task.await_many(15_000)

      received = committed(fn -> @repo.get!(WaitGroup, wg_id).received_events end)

      assert map_size(received) == 8,
             "lost an event under contention: #{inspect(Map.keys(received))}"

      assert Enum.sort(Map.keys(received)) == Enum.sort(event_names)

      # Exactly one task observed the group transition to :completed.
      assert committed(fn -> @repo.get!(WaitGroup, wg_id).status end) == :completed
    end
  end
end
