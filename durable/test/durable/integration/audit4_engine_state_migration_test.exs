defmodule Durable.Integration.Audit4EngineStateMigrationTest do
  @moduledoc """
  The migration that gives the engine's state its own column, run for real in
  a schema of its own.

  Rows written by hand in the old layout: a finished run has its markers moved
  out of `context`, `down` puts them back, and a second `up` changes nothing.
  A run that can still be run keeps them where a node on the old code reads
  them, until an engine with the column takes the run up.

  Then runs that were parked under the old layout: a run that is waiting on an
  event, one in the middle of a parallel block and one on its queue to be
  rolled back are taken through `down` (which leaves them as an engine from
  before the column wrote them) and `up`, put back, and have to carry on as if
  nothing had happened.
  """
  use Durable.IntegrationCase

  import Durable.Testing

  alias Durable.EngineState
  alias Durable.Migration

  @moduletag :capture_log
  @moduletag timeout: 120_000

  @prefix "audit4_engine_state_migration"

  # The order once it is shipped. A wait's answer stays in the data under its name.
  @shipped %{
    "order_id" => 7,
    "received" => true,
    "payment_received" => %{"amount" => 40},
    "paid" => 40,
    "shipped" => true
  }

  # The migration under test, not the latest: later ones come after it.
  @engine_state Durable.Migration.Migrations.V20261122000000AddEngineState.version()

  for {name, call} <- [
        {Up, quote(do: Migration.up(prefix: unquote(@prefix), log: false))},
        {DownOne,
         quote(
           do:
             Migration.down(
               prefix: unquote(@prefix),
               to: Migration.previous_version(unquote(@engine_state)),
               log: false
             )
         )},
        {UpToBefore,
         quote(
           do:
             Migration.up(
               prefix: unquote(@prefix),
               to: Migration.previous_version(unquote(@engine_state)),
               log: false
             )
         )}
      ] do
    defmodule Module.concat(__MODULE__, name) do
      use Ecto.Migration

      def up, do: unquote(call)
      def down, do: :ok
    end
  end

  defmodule Seen do
    def hit(key), do: Durable.IntegrationProbe.note(key)
    def count(key), do: Durable.IntegrationProbe.hits(key)
  end

  defmodule Orders do
    use Durable
    use Durable.Wait

    alias Durable.Integration.Audit4EngineStateMigrationTest.Seen

    # An order waits to be paid for, and is then shipped.
    workflow "migrated_order" do
      step :receive_order, fn order ->
        Seen.hit(:received)
        {:ok, Map.put(order, "received", true)}
      end

      step :await_payment, fn order ->
        payment = wait_for_event("payment_received")
        Seen.hit(:paid)
        {:ok, Map.put(order, "paid", payment["amount"])}
      end

      step :ship, fn order ->
        Seen.hit(:shipped)
        {:ok, Map.put(order, "shipped", true)}
      end
    end

    # A loan is checked against two bureaus at once, each of which answers later.
    workflow "migrated_loan" do
      step :receive_application, fn loan -> {:ok, Map.put(loan, "received", true)} end

      parallel :checks do
        step :credit, fn _loan ->
          Seen.hit(:credit_asked)
          {:ok, %{score: wait_for_event("credit_scored")["score"]}}
        end

        step :fraud, fn _loan ->
          Seen.hit(:fraud_asked)
          {:ok, %{clear: wait_for_event("fraud_checked")["clear"]}}
        end
      end

      step :decide, fn loan ->
        Seen.hit(:decided)
        {:ok, Map.put(loan, "approved", loan["checks"]["credit"]["score"] > 600)}
      end
    end

    # A trip whose payment is declined is left failed, its flight still booked.
    workflow "migrated_trip" do
      step :book_flight, [compensate: :cancel_flight], fn trip ->
        Seen.hit(:booked)
        {:ok, Map.put(trip, "flight", "FL-123")}
      end

      step :charge, fn _trip ->
        Seen.hit(:charged)
        {:error, "card declined"}
      end

      compensate :cancel_flight, fn trip ->
        Seen.hit({:cancelled, trip["flight"]})
        {:ok, trip}
      end
    end
  end

  setup do
    clean()
    on_exit(&clean/0)

    Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)
    :ok
  end

  defp clean do
    IntegrationRepo.query!("DROP SCHEMA IF EXISTS #{@prefix} CASCADE")
    IntegrationRepo.query!("DELETE FROM schema_migrations WHERE version >= 99980000000000")
  end

  defp migrate(name) do
    version = 99_980_000_000_000 + System.unique_integer([:positive, :monotonic])
    :ok = Ecto.Migrator.up(IntegrationRepo, version, Module.concat(__MODULE__, name), log: false)
  end

  defp columns do
    IntegrationRepo.query!(
      """
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = $1 AND table_name = 'workflow_executions'
      """,
      [@prefix]
    ).rows
    |> List.flatten()
  end

  # A row as an engine from before the column wrote it.
  defp insert_old!(context, status \\ "completed") do
    id = Ecto.UUID.generate()

    IntegrationRepo.query!(
      """
      INSERT INTO #{@prefix}.workflow_executions
        (id, workflow_module, workflow_name, status, queue, priority, input, context,
         inserted_at, updated_at)
      VALUES ($1, 'Elixir.Orders', 'order', $3, 'default', 0, '{}', $2, now(), now())
      """,
      [Ecto.UUID.dump!(id), context, status]
    )

    id
  end

  # `[context, engine_state]`, or `[context]` while there is no such column.
  defp stored(id) do
    engine_state = if "engine_state" in columns(), do: ", engine_state", else: ""

    [row] =
      IntegrationRepo.query!(
        "SELECT context#{engine_state} FROM #{@prefix}.workflow_executions WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      ).rows

    row
  end

  @old %{
    "order_id" => 7,
    # The user's own: not one of the engine's names, though it looks like one.
    "__typename" => "Order",
    "__string_keys__" => ["order_id"],
    "__done__" => %{"step" => "receive_order"},
    "__call_children" => %{"c-1" => %{"step_name" => "charge", "kind" => "call"}},
    "__child:charge" => "c-1",
    "__child_done:charge" => %{"status" => "completed", "result" => %{"paid" => true}},
    "__fire_forget:receipt" => "c-2",
    "__timeout__" => true
  }

  @users %{"order_id" => 7, "__typename" => "Order"}
  @engines Map.drop(@old, ["order_id", "__typename"])

  describe "rows written before the column" do
    setup do
      migrate(UpToBefore)
      refute "engine_state" in columns()
      :ok
    end

    test "up moves the engine's markers out of a finished run's context, and leaves the user's data" do
      finished =
        for status <- ~w(completed compensated compensation_failed), do: insert_old!(@old, status)

      plain = insert_old!(%{"order_id" => 8, "__typename" => "Order"})
      empty = insert_old!(%{})

      migrate(Up)

      for id <- finished, do: assert(stored(id) == [@users, @engines])
      assert stored(plain) == [%{"order_id" => 8, "__typename" => "Order"}, %{}]
      assert stored(empty) == [%{}, %{}]
    end

    # A node on the old code may still have to run these, and reads only the context.
    test "up leaves a run that can still be run as it is" do
      open =
        for status <- ~w(pending running waiting compensating failed cancelled),
            do: insert_old!(@old, status)

      migrate(Up)

      for id <- open, do: assert(stored(id) == [@old, %{}])
    end

    test "up twice is a no-op" do
      marked = insert_old!(@old)

      migrate(Up)
      once = stored(marked)
      migrate(Up)

      assert stored(marked) == once
      assert once == [@users, @engines]
    end

    test "down moves them back, and up again takes them out again" do
      marked = insert_old!(@old)
      plain = insert_old!(%{"order_id" => 8})
      # A run an engine with the column has written: marked, its state in the column.
      waiting = insert_old!(@users, "waiting")

      migrate(Up)

      IntegrationRepo.query!(
        "UPDATE #{@prefix}.workflow_executions SET engine_state = $2 WHERE id = $1",
        [Ecto.UUID.dump!(waiting), Map.put(@engines, "v", 1)]
      )

      migrate(DownOne)

      refute "engine_state" in columns()
      assert stored(marked) == [@old]
      assert stored(plain) == [%{"order_id" => 8}]
      assert stored(waiting) == [@old]

      migrate(Up)
      assert stored(marked) == [@users, @engines]
      assert stored(waiting) == [@old, %{}]
    end
  end

  # Takes the runs through `down` and `up` in the schema next door, and puts
  # what comes out back in the suite's own. Returns each run's context as the
  # old layout had it.
  defp through_the_migration(ids) do
    dumped = Enum.map(ids, &Ecto.UUID.dump!/1)
    migrate(Up)

    IntegrationRepo.query!(
      """
      INSERT INTO #{@prefix}.workflow_executions
      SELECT (jsonb_populate_record(NULL::#{@prefix}.workflow_executions, to_jsonb(d))).*
      FROM durable.workflow_executions d WHERE d.id = ANY($1)
      """,
      [dumped]
    )

    migrate(DownOne)
    refute "engine_state" in columns()
    old = Map.new(ids, &{&1, hd(stored(&1))})

    migrate(Up)

    IntegrationRepo.query!(
      """
      UPDATE durable.workflow_executions d
      SET context = m.context, engine_state = m.engine_state
      FROM #{@prefix}.workflow_executions m WHERE m.id = d.id AND d.id = ANY($1)
      """,
      [dumped]
    )

    # As the migration leaves a run that isn't over: in the old layout still,
    # for the first engine with the column that takes it up.
    for id <- ids do
      run = get(id)
      assert run.engine_state == %{}
      assert run.context == old[id]
    end

    old
  end

  defp lanes(run),
    do: IntegrationRepo.all(from(w in WorkflowExecution, where: w.parent_workflow_id == ^run.id))

  describe "a run parked under the old layout carries on after the migration" do
    test "when it was waiting on an event" do
      run = run_workflow(Orders, %{"order_id" => 7}, workflow: "migrated_order")
      assert run.status == :waiting

      old = through_the_migration([run.id])

      assert %{"__string_keys__" => ["order_id", "received"], "order_id" => 7, "received" => true} =
               old[run.id]

      :ok = Durable.send_event(run.id, "payment_received", %{"amount" => 40})
      run = drain(run)

      assert run.status == :completed

      assert run.context == @shipped

      assert run.engine_state["v"] == 1
      assert {Seen.count(:received), Seen.count(:paid), Seen.count(:shipped)} == {1, 1, 1}
    end

    test "when it was in the middle of a parallel block" do
      run = run_workflow(Orders, %{"applicant" => "A-1"}, workflow: "migrated_loan")
      assert run.status == :waiting
      [credit, fraud] = Enum.sort_by(lanes(run), & &1.current_step)
      assert [:waiting, :waiting] == [credit.status, fraud.status]

      old = through_the_migration([run.id, credit.id, fraud.id])
      assert %{"__parallel_children" => children, "__parallel_wait_group_id" => _} = old[run.id]
      assert Map.keys(children) |> Enum.sort() == Enum.sort([credit.id, fraud.id])
      assert old[credit.id]["__parallel_step"] == "checks__credit"

      :ok = Durable.send_event(credit.id, "credit_scored", %{"score" => 710})
      assert drain(run).status == :waiting
      :ok = Durable.send_event(fraud.id, "fraud_checked", %{"clear" => true})
      run = drain(run)

      assert run.status == :completed

      assert %{
               "applicant" => "A-1",
               "approved" => true,
               "checks" => %{"credit" => %{"score" => 710}, "fraud" => %{"clear" => true}}
             } = run.context

      # The block wasn't started a second time, and no lane ran as a whole run.
      assert length(lanes(run)) == 2
      assert {Seen.count(:credit_asked), Seen.count(:fraud_asked)} == {2, 2}
      assert Seen.count(:decided) == 1
    end

    test "when it was on its queue to be rolled back" do
      run = run_workflow(Orders, %{"trip" => "T-9"}, workflow: "migrated_trip")
      assert run.status == :failed
      {:ok, _} = Durable.rollback(run.id)
      assert get(run.id).status == :pending

      old = through_the_migration([run.id])
      assert %{"__rollback__" => %{"status" => "failed"}} = old[run.id]

      # A cancel still leaves it to be undone, though only its context says so
      # until an engine with the column has written the row.
      assert Durable.cancel(run.id) == {:error, :already_completed}

      run = drain(run)

      assert run.status == :compensated
      assert run.error["message"] == "card declined"
      assert Seen.count({:cancelled, "FL-123"}) == 1
      assert {Seen.count(:booked), Seen.count(:charged)} == {1, 1}
      refute is_map_key(run.engine_state, "__rollback__")
    end
  end

  describe "a run an engine from before the column wrote after the migration" do
    # Its state is still in its context, under the names it always had. The
    # first engine with the column to touch the row moves it out, once.
    test "is read as that engine left it, and from then on only from its own column" do
      run = run_workflow(Orders, %{"order_id" => 7}, workflow: "migrated_order")
      assert run.status == :waiting

      old_context = Map.merge(run.context, Map.delete(run.engine_state, "v"))

      IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^run.id),
        set: [context: old_context, engine_state: %{}]
      )

      :ok = Durable.send_event(run.id, "payment_received", %{"amount" => 40})

      adopted = get(run.id)
      assert adopted.engine_state["v"] == 1
      assert adopted.engine_state["__string_keys__"] == ["order_id", "received"]
      refute Enum.any?(Map.keys(adopted.context), &EngineState.key?/1)

      # Put there now, a marker is the user's data, and nothing reads it.
      forged = Map.put(adopted.context, "__rollback__", %{"error" => %{}, "status" => "failed"})

      IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^run.id),
        set: [context: forged]
      )

      run = drain(run)
      assert run.status == :completed

      assert run.context == @shipped
    end

    test "is still left to be rolled back by a cancel, and is rolled back" do
      run = run_workflow(Orders, %{"trip" => "T-9"}, workflow: "migrated_trip")
      {:ok, _} = Durable.rollback(run.id)
      queued = get(run.id)

      IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^run.id),
        set: [
          context: Map.merge(queued.context, Map.delete(queued.engine_state, "v")),
          engine_state: %{}
        ]
      )

      assert Durable.cancel(run.id) == {:error, :already_completed}
      assert Durable.cancel(run.id, "stop", rollback: true) == {:error, :already_completed}

      run = drain(run)
      assert run.status == :compensated
      assert Seen.count({:cancelled, "FL-123"}) == 1
      assert Seen.count(:charged) == 1
    end
  end
end
