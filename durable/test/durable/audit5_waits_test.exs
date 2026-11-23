defmodule Durable.Audit5WaitsTest do
  @moduledoc """
  A wait's answer belongs to that wait: not to an earlier wait of the same
  name, nor to a key of the same name in the run's own data. And a schedule
  turned back on doesn't fire for a time that went by while it was off.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Executor
  alias Durable.Scheduler.API
  alias Durable.Storage.Schemas.{ScheduledWorkflow, WorkflowExecution}
  alias Durable.Wait
  alias Durable.Wait.TimeoutWorker

  @moduletag :capture_log

  # A deposit and then the balance: the payment provider's webhook sends the
  # same event for both.
  defmodule Audit5WaitsInstallments do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_installments" do
      step :deposit, fn data ->
        {:ok, Map.put(data, "deposit", wait_for_event("payment.succeeded"))}
      end

      step :balance, fn data ->
        {:ok, Map.put(data, "balance", wait_for_event("payment.succeeded"))}
      end
    end
  end

  # The carrier sends its estimate and then a revised one, and the customer
  # picks the day. Each answer is a date.
  defmodule Audit5WaitsDelivery do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_delivery" do
      step :schedule, fn data ->
        first = wait_for_event("carrier.eta")
        revised = wait_for_event("carrier.eta")
        chosen = wait_for_input("delivery_date")

        {:ok,
         Map.merge(data, %{"first_eta" => first, "revised_eta" => revised, "chosen" => chosen})}
      end
    end
  end

  # Ask the manager; if nobody answers in time, remind them and ask again.
  defmodule Audit5WaitsReminder do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_reminder" do
      step :approve, fn data ->
        answer =
          case wait_for_input("manager_approval", timeout: 0, timeout_value: "remind") do
            "remind" -> wait_for_input("manager_approval", timeout: 3_600_000)
            answer -> answer
          end

        {:ok, Map.put(data, "approval", answer)}
      end
    end
  end

  defmodule Audit5WaitsGroupReminder do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_group_reminder" do
      step :decide, fn data ->
        names = ["approved", "rejected"]

        outcome =
          case wait_for_any(names, timeout: 0, timeout_value: "remind") do
            "remind" -> wait_for_any(names, timeout: 3_600_000, timeout_value: "escalate")
            outcome -> outcome
          end

        {:ok, Map.put(data, "outcome", inspect(outcome))}
      end
    end
  end

  # The order's own data has a "delivered" flag; the carrier sends a
  # "delivered" or a "lost" event.
  defmodule Audit5WaitsShipment do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_shipment" do
      step :ship, fn data -> {:ok, Map.put(data, "delivered", false)} end

      step :track, fn data ->
        timeout = data["timeout_ms"] || 3_600_000
        got = wait_for_any(["delivered", "lost"], timeout: timeout, timeout_value: "no news")
        {:ok, Map.put(data, "got", inspect(got))}
      end
    end
  end

  # The address is asked for first, then the payment is awaited.
  defmodule Audit5WaitsCheckout do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_checkout" do
      step :checkout, fn data ->
        address = wait_for_input("shipping_address")
        payment = wait_for_event("payment.succeeded")
        {:ok, Map.merge(data, %{"address" => address, "payment" => inspect(payment)})}
      end
    end
  end

  # A parcel is scanned out of one hub and into the next.
  defmodule Audit5WaitsScans do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_scans" do
      step :track, fn data ->
        out = wait_for_event("parcel.scanned")
        into = wait_for_event("parcel.scanned")
        {:ok, Map.merge(data, %{"out" => out, "into" => into})}
      end
    end
  end

  # The approval is posted to a ledger that may be down.
  defmodule Audit5WaitsLedger do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_ledger" do
      step :approve, fn data ->
        approval = wait_for_input("manager_approval")

        if :persistent_term.get(:audit5_waits_ledger_down, false),
          do: raise("ledger unavailable")

        {:ok, Map.put(data, "approval", approval)}
      end
    end
  end

  # An operator skips the site inspection; the adjuster still has to decide,
  # and the payout still waits out its cooling-off period.
  defmodule Audit5WaitsClaim do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_claim" do
      step :assess, fn data ->
        inspection = wait_for_event("inspection.done")
        decision = wait_for_input("adjuster_decision")
        {:ok, Map.merge(data, %{"inspection" => inspect(inspection), "decision" => decision})}
      end
    end

    workflow "audit5_waits_claim_payout" do
      step :pay, fn data ->
        inspection = wait_for_event("inspection.done")
        sleep(3_600_000)
        {:ok, Map.put(data, "inspection", inspect(inspection))}
      end
    end
  end

  # The order sends its receipt email on its own and doesn't wait for it; then
  # a manager has a day to approve it.
  defmodule Audit5WaitsReceipt do
    use Durable
    use Durable.Wait

    workflow "audit5_waits_receipt" do
      step :send, fn data ->
        {:ok, Map.put(data, "delivered", wait_for_event("email.delivered"))}
      end
    end
  end

  defmodule Audit5WaitsLargeOrder do
    use Durable
    use Durable.Wait
    use Durable.Orchestration

    workflow "audit5_waits_large_order" do
      step :receipt, fn data ->
        {:ok, _id} = start_workflow(Audit5WaitsReceipt, %{"to" => "ana@example.com"})
        {:ok, data}
      end

      step :approve, fn data ->
        wait_for_input("manager_approval", timeout: 0, on_timeout: :fail)
        {:ok, data}
      end
    end
  end

  defmodule Audit5WaitsNightlyReport do
    use Durable

    workflow "audit5_waits_nightly_report" do
      step :build, fn data -> {:ok, Map.put(data, "built", true)} end
    end
  end

  defmodule Audit5WaitsFold do
    @moduledoc false
    # Clocks go back from UTC-4 to UTC-5 at the instant in :persistent_term.
    @behaviour Calendar.TimeZoneDatabase

    @summer %{utc_offset: -18_000, std_offset: 3_600, zone_abbr: "DT"}
    @winter %{utc_offset: -18_000, std_offset: 0, zone_abbr: "ST"}
    @utc %{utc_offset: 0, std_offset: 0, zone_abbr: "UTC"}

    def set_fold(%DateTime{} = at), do: :persistent_term.put(__MODULE__, DateTime.to_unix(at))
    defp fold, do: :persistent_term.get(__MODULE__)

    @impl true
    def time_zone_period_from_utc_iso_days(_, "Etc/UTC"), do: {:ok, @utc}

    def time_zone_period_from_utc_iso_days({days, {parts, ppd}}, "Test/Fold") do
      unix = days * 86_400 + div(parts * 86_400, ppd) - 62_167_219_200
      if unix < fold(), do: {:ok, @summer}, else: {:ok, @winter}
    end

    def time_zone_period_from_utc_iso_days(_, _), do: {:error, :time_zone_not_found}

    @impl true
    def time_zone_periods_from_wall_datetime(_, "Etc/UTC"), do: {:ok, @utc}

    def time_zone_periods_from_wall_datetime(naive, "Test/Fold") do
      wall = naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

      cond do
        wall >= fold() - 14_400 -> {:ok, @winter}
        wall >= fold() - 18_000 -> {:ambiguous, @summer, @winter}
        true -> {:ok, @summer}
      end
    end

    def time_zone_periods_from_wall_datetime(_, _), do: {:error, :time_zone_not_found}
  end

  defp time_out_waits do
    TimeoutWorker.check_timeouts()
    :sys.get_state(TimeoutWorker.worker_name(Durable))
  end

  describe "the same event waited for in two steps" do
    test "the second wait waits for its own event" do
      waiting = run_workflow(Audit5WaitsInstallments, %{})
      assert Durable.send_event(waiting.id, "payment.succeeded", %{"amount" => 100}) == :ok

      waiting = drain(waiting)
      assert waiting.status == :waiting
      assert waiting.current_step == "balance"
      assert_waiting_for_event(waiting, "payment.succeeded")

      assert Durable.send_event(waiting.id, "payment.succeeded", %{"amount" => 900}) == :ok
      finished = drain(waiting)

      assert finished.status == :completed
      assert finished.context["deposit"] == %{"amount" => 100}
      assert finished.context["balance"] == %{"amount" => 900}
    end
  end

  describe "a wait asked again after it timed out, in the same step" do
    setup do
      start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
      :ok
    end

    test "wait_for_input waits for the reminder's answer" do
      waiting = run_workflow(Audit5WaitsReminder, %{})
      time_out_waits()

      reminded = drain(waiting)
      assert reminded.status == :waiting
      assert_waiting_for_input(reminded, "manager_approval")

      assert Durable.provide_input(reminded.id, "manager_approval", %{"approved" => true}) == :ok
      finished = drain(reminded)

      assert finished.status == :completed
      assert finished.context["approval"] == %{"approved" => true}
    end

    test "wait_for_any waits for the reminder's answer" do
      waiting = run_workflow(Audit5WaitsGroupReminder, %{})
      time_out_waits()

      reminded = drain(waiting)
      assert reminded.status == :waiting

      assert Durable.send_event(reminded.id, "rejected", %{"by" => "dana"}) == :ok
      finished = drain(reminded)

      assert finished.status == :completed
      assert finished.context["outcome"] == ~s({"rejected", %{"by" => "dana"}})
    end
  end

  describe "a wait_for_any named like a key of the run's data" do
    test "returns the event that came, not the key" do
      waiting = run_workflow(Audit5WaitsShipment, %{})
      assert waiting.status == :waiting

      assert Durable.send_event(waiting.id, "lost", %{"carrier" => "acme"}) == :ok
      finished = drain(waiting)

      assert finished.status == :completed
      assert finished.context["got"] == ~s({"lost", %{"carrier" => "acme"}})
    end

    test "returns {:cancelled, reason} when its wait is cancelled" do
      waiting = run_workflow(Audit5WaitsShipment, %{})
      assert Wait.cancel_wait(waiting.id, reason: "order withdrawn") == :ok

      finished = drain(waiting)
      assert finished.context["got"] == ~s({:cancelled, "order withdrawn"})
    end

    test "returns its timeout_value when it times out" do
      start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
      waiting = run_workflow(Audit5WaitsShipment, %{"timeout_ms" => 0})

      time_out_waits()
      finished = drain(waiting)
      assert finished.context["got"] == ~s("no news")
    end
  end

  describe "a step with an answered wait and then a cancelled one" do
    test "the answered wait keeps its answer" do
      waiting = run_workflow(Audit5WaitsCheckout, %{})
      address = %{"city" => "Leeds", "postcode" => "LS1 4AP"}
      assert Durable.provide_input(waiting.id, "shipping_address", address) == :ok

      waiting = drain(waiting)
      assert_waiting_for_event(waiting, "payment.succeeded")
      assert Wait.cancel_wait(waiting.id, reason: "card declined") == :ok

      finished = drain(waiting)
      assert finished.status == :completed
      assert finished.context["address"] == address
      assert finished.context["payment"] == ~s({:cancelled, "card declined"})
    end
  end

  describe "a step that waits again after its wait was cancelled" do
    test "the next wait waits for its own answer" do
      waiting = run_workflow(Audit5WaitsClaim, %{}, workflow: "audit5_waits_claim")
      assert Wait.cancel_wait(waiting.id, reason: "inspection skipped") == :ok

      deciding = drain(waiting)
      assert deciding.status == :waiting
      assert_waiting_for_input(deciding, "adjuster_decision")

      assert Durable.provide_input(deciding.id, "adjuster_decision", "approve") == :ok
      finished = drain(deciding)

      assert finished.status == :completed
      assert finished.context["inspection"] == ~s({:cancelled, "inspection skipped"})
      assert finished.context["decision"] == "approve"
    end

    test "the next sleep sleeps" do
      {:ok, id} = Durable.start(Audit5WaitsClaim, %{}, workflow: "audit5_waits_claim_payout")
      assert Executor.execute_workflow(id, Config.get(Durable)) |> elem(0) == :waiting
      assert Wait.cancel_wait(id, reason: "inspection skipped") == :ok

      Executor.execute_workflow(id, Config.get(Durable))
      sleeping = TestRepo.get!(WorkflowExecution, id)

      assert sleeping.status == :waiting
      assert DateTime.diff(sleeping.scheduled_at, DateTime.utc_now()) > 3_000
    end
  end

  describe "an input wait that fails its run when it times out" do
    setup do
      start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
      :ok
    end

    test "leaves the run's start_workflow children running, as any other failure does" do
      waiting = run_workflow(Audit5WaitsLargeOrder, %{})
      [receipt] = Durable.list_children!(waiting.id)
      assert receipt.status == :waiting

      time_out_waits()
      failed = drain(waiting)

      assert failed.status == :failed
      assert failed.error["type"] == "timeout"
      assert TestRepo.get!(WorkflowExecution, receipt.id).status == :waiting
    end
  end

  describe "a wait answered with a date" do
    test "gets the date's text, and an earlier wait reads it back from its own row" do
      waiting = run_workflow(Audit5WaitsDelivery, %{})
      assert Durable.send_event(waiting.id, "carrier.eta", ~D[2026-12-01]) == :ok

      waiting = drain(waiting)
      assert Durable.send_event(waiting.id, "carrier.eta", ~D[2026-12-03]) == :ok

      waiting = drain(waiting)
      assert_waiting_for_input(waiting, "delivery_date")
      assert Durable.provide_input(waiting.id, "delivery_date", ~D[2026-12-04]) == :ok

      finished = drain(waiting)
      assert finished.status == :completed
      assert finished.context["first_eta"] == "2026-12-01"
      assert finished.context["revised_eta"] == "2026-12-03"
      assert finished.context["chosen"] == "2026-12-04"
    end
  end

  describe "one name waited for twice in a step" do
    test "each wait gets its own event" do
      waiting = run_workflow(Audit5WaitsScans, %{})
      assert Durable.send_event(waiting.id, "parcel.scanned", %{"hub" => "LHR"}) == :ok

      waiting = drain(waiting)
      assert waiting.status == :waiting
      assert Durable.send_event(waiting.id, "parcel.scanned", %{"hub" => "JFK"}) == :ok

      finished = drain(waiting)
      assert finished.status == :completed
      assert finished.context["out"] == %{"hub" => "LHR"}
      assert finished.context["into"] == %{"hub" => "JFK"}
    end
  end

  describe "a schedule turned back on with update_schedule" do
    test "waits for its next time, as enable_schedule does" do
      config = Config.get(Durable)
      # Twelve hours from now, so the test never runs at the schedule's time.
      hour = rem(DateTime.utc_now().hour + 12, 24)
      {:ok, _} = Durable.schedule(Audit5WaitsNightlyReport, "0 #{hour} * * *", name: "nightly")
      {:ok, off} = Durable.disable_schedule("nightly")

      # It stays off for a week: the time it had then is long gone.
      week_ago = DateTime.add(off.next_run_at, -7 * 86_400, :second)
      {:ok, _} = off |> Ecto.Changeset.change(next_run_at: week_ago) |> config.repo.update()

      {:ok, on} = Durable.update_schedule("nightly", enabled: true)

      assert on.enabled
      assert DateTime.after?(on.next_run_at, DateTime.utc_now())
      assert on.next_run_at.hour == hour
      assert API.get_due_schedules(config) == []
    end
  end

  describe "a daily schedule whose fire is claimed late, in the hour the clocks repeat" do
    setup do
      previous = Calendar.get_time_zone_database()
      on_exit(fn -> Calendar.put_time_zone_database(previous) end)
      :ok
    end

    # The nightly report runs at a wall time the clocks show twice tonight. Every
    # node was down when it came round the first time, and back half an hour
    # after the clocks went back: the fire is claimed then, late.
    test "doesn't fire again when the wall clock comes round to its time again" do
      now = DateTime.utc_now()
      Audit5WaitsFold.set_fold(DateTime.add(now, -1_800, :second))
      Calendar.put_time_zone_database(Audit5WaitsFold)

      # Ten minutes ahead on the wall clock, which has gone back an hour. It
      # first showed that time on summer time, 50 minutes ago.
      wall = DateTime.add(now, -5 * 3_600 + 600, :second)
      first_time = DateTime.add(%{wall | second: 0, microsecond: {0, 6}}, 4 * 3_600, :second)

      {:ok, schedule} =
        %ScheduledWorkflow{}
        |> ScheduledWorkflow.changeset(%{
          name: "nightly_in_the_fold",
          workflow_module: inspect(Audit5WaitsNightlyReport),
          workflow_name: "audit5_waits_nightly_report",
          cron_expression: "#{wall.minute} #{wall.hour} * * *",
          timezone: "Test/Fold",
          next_run_at: first_time
        })
        |> TestRepo.insert()

      assert API.claim_fire(schedule, Config.get(Durable))

      next = TestRepo.get!(ScheduledWorkflow, schedule.id).next_run_at
      assert DateTime.diff(next, now, :hour) >= 23
    end
  end

  describe "a schedule for a workflow this node doesn't have yet" do
    # A rolling deploy adds a weekly digest to the reports module. A node with
    # the new code registered its schedule; this node still runs the old code.
    setup do
      {:ok, schedule} =
        %ScheduledWorkflow{}
        |> ScheduledWorkflow.changeset(%{
          name: "weekly_digest",
          workflow_module: inspect(Audit5WaitsNightlyReport),
          workflow_name: "audit5_waits_weekly_digest",
          cron_expression: "* * * * *",
          next_run_at: DateTime.add(DateTime.utc_now(), -5, :second)
        })
        |> TestRepo.insert()

      start_supervised!({Durable.Scheduler, config: Config.get(Durable), interval: 3_600_000})
      {:ok, schedule: schedule}
    end

    test "is left due for a node that has it, as for a module it lacks", %{schedule: schedule} do
      for _check <- 1..5 do
        Durable.Scheduler.check_schedules(Durable)
        Durable.Scheduler.status(Durable)
      end

      row = TestRepo.get!(ScheduledWorkflow, schedule.id)
      assert row.enabled
      assert row.consecutive_failures == 0
      assert row.next_run_at == schedule.next_run_at
    end
  end

  describe "a retried step" do
    setup do
      on_exit(fn -> :persistent_term.erase(:audit5_waits_ledger_down) end)
    end

    test "keeps the answer its wait already had" do
      :persistent_term.put(:audit5_waits_ledger_down, true)
      waiting = run_workflow(Audit5WaitsLedger, %{})
      assert Durable.provide_input(waiting.id, "manager_approval", %{"approved" => true}) == :ok
      assert drain(waiting).status == :failed

      :persistent_term.put(:audit5_waits_ledger_down, false)
      {:ok, _} = Durable.retry(waiting.id)
      finished = drain(waiting)

      assert finished.status == :completed
      assert finished.context["approval"] == %{"approved" => true}
      assert Wait.list_pending_inputs!() == []
    end
  end
end
