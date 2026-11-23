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

defmodule Audit5QueueInvoice do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # One email per invoice: sent twice, the customer is billed twice.
  workflow "audit5_queue_invoice" do
    step :email_invoice, fn invoice ->
      Probe.note({:emailed, invoice["number"]})
      Probe.wait_for(:mail_server_up)
      {:ok, invoice}
    end
  end
end

defmodule Audit5QueueReceipt do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "audit5_queue_receipt" do
    step :email_receipt, fn order ->
      Probe.note({:receipt, order["number"]})
      {:ok, order}
    end
  end
end

defmodule Audit5QueueRouting do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  # The carrier lookup never answers: the worker's process is lost in it,
  # outside any step.
  workflow "audit5_queue_routing" do
    step :take_order, fn order -> {:ok, order} end

    branch on: fn _order ->
             Probe.note(:routing)
             Probe.wait_for(:carrier_answered)
           end do
      _ -> step :ship_order, fn order -> {:ok, order} end
    end
  end
end

defmodule Durable.Integration.Audit5QueueTest do
  @moduledoc """
  Audit 5: the queue and crash recovery. Workers that lost their claim, and
  what they hold on to after.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Queue.Manager
  alias Durable.Queue.StaleJobRecovery

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

  describe "a node with shutdown_grace_period: 0 that stops cleanly" do
    # No Drainer was started at 0, so its runs stayed locked until
    # `stale_lock_timeout`, as if the node had crashed.
    test "hands its runs back at once, and the next node carries on" do
      start_durable!(%{default: 1}, shutdown_grace_period: 0)

      {:ok, id} = Durable.start(Audit5QueueBooking, %{"seat" => "7B"})
      assert_eventually(fn -> Probe.hits(:charging) == 1 end)

      {us, _} = :timer.tc(fn -> stop_supervised!(Durable) end)

      assert %{status: :pending, locked_by: nil, lock_token: nil} = get(id)
      assert us < 1_000_000

      assert [%{status: :snoozed, error: %{"type" => "node_stopped"}}] =
               IntegrationRepo.all(
                 from(s in StepExecution,
                   where: s.workflow_id == ^id and s.step_name == "charge_card"
                 )
               )

      :ok = Probe.set(:gateway_answered)
      start_durable!(%{default: 1})
      await_status(id, :completed, 5_000)
      assert Probe.hits(:charged) == 1
    end
  end

  describe "a queue resumed on this node while a poll is already due" do
    def count_poll(_event, _measurements, _meta, test), do: send(test, :polled)

    defp polls_in(ms) do
      flush_polls()
      Process.sleep(ms)
      flush_polls()
    end

    defp flush_polls(count \\ 0) do
      receive do
        :polled -> flush_polls(count + 1)
      after
        0 -> count
      end
    end

    # The poll's message was in the mailbox behind the resume, which couldn't
    # cancel it and set a second timer: two chains of polls from then on, and
    # one more with every resume.
    test "still polls once per poll_interval" do
      start_durable!(%{default: 1}, poll_interval: 100)
      poller = Process.whereis(Durable.Queue.Poller.Default)

      :telemetry.attach(
        "audit5-polls",
        [:durable, :queue, :poll],
        &__MODULE__.count_poll/4,
        self()
      )

      on_exit(fn -> :telemetry.detach("audit5-polls") end)

      for _ <- 1..5 do
        # A poller busy for a moment: the resume arrives, and then its poll
        # comes due, before it gets to either.
        :ok = :sys.suspend(poller)
        resume = Task.async(fn -> Manager.resume(:default) end)
        Process.sleep(150)
        :ok = :sys.resume(poller)
        :ok = Task.await(resume)
      end

      polls = polls_in(1_000)
      assert polls in 5..12, "#{polls} polls in a second at a poll_interval of 100 ms"
    end
  end

  describe "a run started inline" do
    # Run by its caller, not by a worker: it had no lock, so nothing ever
    # found it when the caller died.
    test "whose caller dies mid-step is recovered like any other lost worker's" do
      # No poller on :billing here, so only the caller runs it.
      start_durable!(%{default: 1}, stale_lock_timeout: 1)

      caller =
        spawn(fn ->
          Durable.start(Audit5QueueInvoice, %{"number" => "INV-1"}, inline: true, queue: :billing)
        end)

      assert_eventually(fn -> Probe.hits({:emailed, "INV-1"}) == 1 end)
      [run] = IntegrationRepo.all(WorkflowExecution)
      assert run.status == :running

      Process.exit(caller, :kill)
      Process.sleep(1_500)
      StaleJobRecovery.recover_now(Durable)

      assert %{status: :pending, locked_by: nil, lock_token: nil} = get(run.id)

      assert [%{status: :failed, error: %{"type" => "worker_lost"}}] =
               IntegrationRepo.all(from(s in StepExecution, where: s.workflow_id == ^run.id))
    end

    # A worker heartbeats; a caller had nothing to, so a step that outlasted
    # `stale_lock_timeout` would be taken for lost and run a second time.
    test "keeps its claim fresh through a step longer than stale_lock_timeout" do
      start_durable!(%{default: 1}, stale_lock_timeout: 1, heartbeat_interval: 100)

      spawn(fn ->
        Durable.start(Audit5QueueInvoice, %{"number" => "INV-2"}, inline: true, queue: :billing)
      end)

      assert_eventually(fn -> Probe.hits({:emailed, "INV-2"}) == 1 end)
      [run] = IntegrationRepo.all(WorkflowExecution)

      Process.sleep(1_500)
      {:ok, 0} = StaleJobRecovery.recover_now(Durable)
      assert %{status: :running, lock_token: token} = get(run.id)
      assert token == run.lock_token

      :ok = Probe.set(:mail_server_up)
      assert %{locked_by: nil} = await_status(run.id, :completed)
      assert Probe.hits({:emailed, "INV-2"}) == 1
    end

    # Its row was `pending` with no lock until the caller got to it, and a
    # poller that claimed it first didn't stop the caller.
    test "on a queue this node polls runs once, by the caller or by a worker" do
      start_durable!(%{default: 50})

      numbers = for n <- 1..600, do: "R-#{n}"

      numbers
      |> Task.async_stream(
        fn number -> Durable.start(Audit5QueueReceipt, %{"number" => number}, inline: true) end,
        max_concurrency: 50,
        timeout: 30_000
      )
      |> Stream.run()

      assert_eventually(
        fn ->
          IntegrationRepo.aggregate(
            from(w in WorkflowExecution, where: w.status == :completed),
            :count
          ) == 600
        end,
        20_000
      )

      assert [] = for(number <- numbers, Probe.hits({:receipt, number}) != 1, do: number)
    end
  end

  describe "a worker that reports to a poller that has just died" do
    @poller Durable.Queue.Poller.Default

    defp worker!(id) do
      assert_eventually(fn -> is_pid(Durable.DataCase.get_worker_pid(Durable, "default", id)) end)
      Durable.DataCase.get_worker_pid(Durable, "default", id)
    end

    # The worker is busy for a moment (a heartbeat's write, say) while its
    # task ends and its poller dies. It gets to the task's end before the new
    # poller's takeover, and reports to the poller that is gone.
    defp lose_report!(id, end_task) do
      worker = worker!(id)
      ref = Process.monitor(worker)
      :ok = :sys.suspend(worker)
      end_task.(:sys.get_state(worker).task_pid)

      poller = Process.whereis(@poller)
      Process.exit(poller, :kill)
      assert_eventually(fn -> Process.whereis(@poller) not in [nil, poller] end, 5_000, 1)
      Process.sleep(50)
      :ok = :sys.resume(worker)

      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5_000
      assert_eventually(fn -> :sys.get_state(@poller).workers == %{} end)
    end

    defp kill_task!(task) do
      ref = Process.monitor(task)
      Process.exit(task, :kill)
      assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 5_000
    end

    test "leaves a run that completed as it is: completed, with no lock" do
      start_durable!(%{default: 1})
      {:ok, id} = Durable.start(Audit5QueueBooking, %{"seat" => "9F"})
      assert_eventually(fn -> Probe.hits(:charging) == 1 end)

      lose_report!(id, fn _task ->
        :ok = Probe.set(:gateway_answered)
        await_status(id, :completed)
      end)

      assert %{status: :completed, locked_by: nil, locked_at: nil} = get(id)

      # The queue's slot is free again.
      {:ok, next} = Durable.start(Audit5QueueBooking, %{"seat" => "9G"})
      await_status(next, :completed)
    end

    # Nobody fails the run for the undo that died, so it is the stale sweep's:
    # failed after `stale_lock_timeout`, as for a node that crashed.
    test "leaves a rollback whose undo died to the stale sweep, which fails it" do
      start_durable!(%{default: 1}, stale_lock_timeout: 1)
      {:ok, id} = Durable.start(Audit5QueueRefund, %{"order" => 11})
      assert_eventually(fn -> Probe.hits(:refunding) == 1 end)

      lose_report!(id, &kill_task!/1)
      assert %{status: :compensating} = get(id)

      Process.sleep(1_200)
      StaleJobRecovery.recover_now(Durable)

      assert %{status: :failed, locked_by: nil, error: %{"type" => "zombie_detected"}} = get(id)
    end

    # The third loss in a row is the poller's to fail the run for. Unheard, the
    # run is the stale sweep's: it gets one more go, and fails then.
    test "leaves a run lost for the third time to the stale sweep, and it fails on its next loss" do
      start_durable!(%{default: 1}, stale_lock_timeout: 1)
      {:ok, id} = Durable.start(Audit5QueueRouting, %{"order" => 12})

      for n <- 1..2 do
        assert_eventually(fn -> Probe.hits(:routing) == n end)
        kill_task!(:sys.get_state(worker!(id)).task_pid)
      end

      assert_eventually(fn -> Probe.hits(:routing) == 3 end)
      lose_report!(id, &kill_task!/1)
      assert %{status: :running} = get(id)

      Process.sleep(1_200)
      StaleJobRecovery.recover_now(Durable)

      assert_eventually(fn -> Probe.hits(:routing) == 4 end)
      kill_task!(:sys.get_state(worker!(id)).task_pid)

      assert %{locked_by: nil, error: %{"type" => "task_crash"}} = await_status(id, :failed)
      assert Probe.hits(:routing) == 4
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
