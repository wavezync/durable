defmodule Audit5QueueBooking do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The card gateway can take as long as it likes to answer.
  workflow "audit5_queue_booking" do
    step :hold_seat, [compensate: :release_seat], fn trip -> {:ok, trip} end

    step :charge_card, fn trip ->
      Probe.note(:charging)
      Probe.wait_for(:gateway_answered)
      Probe.note(:charged)
      {:ok, trip}
    end

    compensate :release_seat, fn trip ->
      Probe.note(:released)
      {:ok, trip}
    end
  end
end

defmodule Audit5QueueRefund do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit5_queue_refund", on_failure: :rollback do
    step :charge_card, [compensate: :refund_card], fn order -> {:ok, order} end
    step :ship_order, fn _order -> {:fail, "the warehouse is closed"} end

    compensate :refund_card, fn order ->
      Probe.note(:refunding)
      Probe.wait_for(:refund_sent)
      {:ok, order}
    end
  end
end

defmodule Durable.Integration.Audit5QueueTest do
  @moduledoc """
  Audit 5: the queue and crash recovery. Workers that lost their claim, and
  what they hold on to after.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  describe "a run cancelled with rollback: true while its step runs" do
    # The cancel puts the run straight back on its queue to be undone, so the
    # worker never sees it cancelled. It has to see that its claim is gone.
    test "has its step stopped at the worker's next heartbeat, and is undone" do
      start_durable!(%{default: 1}, heartbeat_interval: 1_000)

      {:ok, id} = Durable.start(Audit5QueueBooking, %{"seat" => "12A"})
      assert_eventually(fn -> Probe.hits(:charging) == 1 end)

      :ok = Durable.cancel(id, "traveller walked away", rollback: true)

      run = await_status(id, :compensated, 5_000)
      assert run.error["type"] == "cancelled"
      assert Probe.hits(:released) == 1

      # The gateway answers late: the step was stopped, so nothing is charged.
      :ok = Probe.set(:gateway_answered)
      Process.sleep(300)
      assert Probe.hits(:charged) == 0
      assert_eventually(fn -> :sys.get_state(Durable.Queue.Poller.Default).workers == %{} end)
    end
  end

  describe "two Durable instances on one node, on one database" do
    # Distributed, as a production cluster is: each instance's node id came
    # from the node's name, so the two had one.
    defp distributed! do
      unless Node.alive?() do
        {_, 0} = System.cmd("epmd", ["-daemon"])
        {:ok, _} = Node.start(:"audit5_queue_#{System.pid()}@127.0.0.1", :longnames)
      end
    end

    test "don't share a node id: one stopping hands back only its own runs" do
      distributed!()
      start_durable!(%{default: 1}, shutdown_grace_period: 200)

      Durable.DataCase.start_supervised_durable!(
        name: :audit5_mailer,
        repo: IntegrationRepo,
        queues: queue_opts(%{emails: 1})
      )

      refute Durable.Config.get(Durable).node_id ==
               Durable.Config.get(:audit5_mailer).node_id

      {:ok, receipt} = Durable.start(Audit5QueueBooking, %{"seat" => "3C"}, queue: :emails)
      assert_eventually(fn -> Probe.hits(:charging) == 1 end)
      %{status: :running, lock_token: token} = get(receipt)

      {:ok, booking} = Durable.start(Audit5QueueBooking, %{"seat" => "4D"})
      assert_eventually(fn -> Probe.hits(:charging) == 2 end)

      # Durable's own run outlasts its grace period and goes back on its queue.
      stop_supervised!(Durable)
      assert %{status: :pending, lock_token: nil} = get(booking)

      # The mailer's run is still the mailer's.
      assert %{status: :running, lock_token: ^token} = get(receipt)
    end
  end

  describe "a connection lost while a compensation's result is written" do
    # Holds a lock on the row so the worker's write blocks, then kills that one
    # backend: one connection dropped, the database still there.
    defp kill_writer_of!(row_id, fun) do
      test = self()

      holder =
        Task.async(fn ->
          IntegrationRepo.transaction(fn ->
            IntegrationRepo.query!(
              "SELECT 1 FROM durable.step_executions WHERE id = $1 FOR UPDATE",
              [Ecto.UUID.dump!(row_id)]
            )

            send(test, :locked)

            receive do
              :let_go -> :ok
            end
          end)
        end)

      assert_receive :locked, 2_000
      fun.()

      pid =
        Enum.find_value(1..200, fn _ ->
          case IntegrationRepo.query!(
                 "SELECT pid FROM pg_stat_activity WHERE datname = current_database() " <>
                   "AND wait_event_type = 'Lock' AND query ILIKE 'UPDATE%step_executions%'"
               ).rows do
            [[pid] | _] ->
              pid

            [] ->
              Process.sleep(20)
              nil
          end
        end)

      assert is_integer(pid), "the worker's write never blocked"
      IntegrationRepo.query!("SELECT pg_terminate_backend($1)", [pid])
      Process.sleep(200)
      send(holder.pid, :let_go)
      Task.await(holder)
    end

    # It says nothing about the undo, as it says nothing about a step: the run
    # goes back on its queue to be undone, as a stopping node hands it back.
    test "puts the rollback back on its queue, and it finishes" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit5QueueRefund, %{"order" => 7})
      assert_eventually(fn -> Probe.hits(:refunding) == 1 end)

      row =
        IntegrationRepo.one!(
          from(s in StepExecution,
            where: s.workflow_id == ^id and s.is_compensation and s.status == :running
          )
        )

      kill_writer_of!(row.id, fn -> :ok = Probe.set(:refund_sent) end)

      run = await_status(id, :compensated, 5_000)
      assert run.error["message"] == "the warehouse is closed"
      assert run.locked_by == nil
      assert Probe.hits(:refunding) == 2
    end
  end
end
