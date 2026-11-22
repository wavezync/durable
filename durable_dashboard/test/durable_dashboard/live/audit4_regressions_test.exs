Code.require_file("../audit4_support_test.exs", __DIR__)

defmodule DurableDashboard.Live.Audit4RegressionsTest do
  @moduledoc """
  Bugs found by the fourth audit, each pinned by the test that reproduced it.
  """
  use DurableDashboard.LiveCase

  import Ecto.Query

  alias Durable.Storage.Schemas.{PendingEvent, PendingInput, WorkflowExecution}

  @endpoint Audit4Dash.Endpoint

  setup_all do
    start_supervised!(Audit4Dash.Endpoint)
    :ok
  end

  defp repo, do: DurableDashboard.TestRepo
  defp input_of(run_id), do: repo().one!(from(p in PendingInput, where: p.workflow_id == ^run_id))
  defp status(run_id), do: repo().get!(WorkflowExecution, run_id).status

  # What went wrong running `fun` against a page, or nil. A LiveView that
  # crashes takes the (linked) test with it unless exits are trapped.
  defp crash(fun) do
    Process.flag(:trap_exit, true)
    fun.()
    nil
  rescue
    e -> Exception.format_banner(:error, e, __STACKTRACE__) |> String.slice(0, 200)
  catch
    :exit, {{reason, _stack}, _call} -> reason |> inspect(limit: 8) |> String.slice(0, 200)
    kind, reason -> {kind, reason} |> inspect(limit: 8) |> String.slice(0, 200)
  end

  describe "a dashboard on a named Durable instance" do
    setup %{conn: conn} do
      # The host runs one instance, and it isn't called `Durable`.
      stop_supervised!(Durable)
      Durable.Config.delete(Durable)

      start_supervised!(
        {Durable,
         name: Audit4Dash.Named,
         repo: DurableDashboard.TestRepo,
         queue_enabled: false,
         pubsub: DurableDashboard.TestPubSub}
      )

      {:ok, conn: Plug.Conn.put_private(conn, :audit4_router, Audit4Dash.NamedRouter)}
    end

    defp named_run!(module, input \\ %{}, opts \\ []) do
      {:ok, id} =
        Durable.Executor.start_workflow(
          module,
          input,
          [inline: true, durable: Audit4Dash.Named] ++ opts
        )

      id
    end

    # Cancel called `Durable.cancel(id)` without the instance, so it crashed
    # the LiveView with "Durable instance Durable not found" (or, with a
    # default instance also running, went to that one).
    test "Cancel on the run page cancels the run", %{conn: conn} do
      id = named_run!(Fixtures.Approvals)
      {:ok, view, _html} = live(conn, "/named/executions/#{id}")
      assert has_element?(view, ~s(button[phx-click="cancel"]))

      assert crash(fn -> render_click(view, "cancel", %{}) end) == nil
      assert status(id) == :cancelled
    end

    test "bulk Cancel on Runs cancels the selected run", %{conn: conn} do
      id = named_run!(Fixtures.Approvals)
      {:ok, view, _html} = live(conn, "/named/executions")
      render_click(view, "toggle", %{"id" => id})

      assert crash(fn -> render_click(view, "bulk", %{"action" => "cancel"}) end) == nil
      assert status(id) == :cancelled
    end

    # Every action that changes something, with no default instance to fall
    # back on: each must reach `Audit4Dash.Named`.
    test "every mutating action reaches the named instance", %{conn: conn} do
      named = [durable: Audit4Dash.Named]
      click = fn view, event, params -> crash(fn -> render_click(view, event, params) end) end
      open = fn path -> conn |> live("/named" <> path) |> elem(1) end

      # The run page.
      retried = named_run!(Fixtures.Payments, %{"decline" => true})
      assert click.(open.("/executions/#{retried}"), "retry", %{}) == nil
      assert repo().get!(WorkflowExecution, retried).status != :failed

      rolled_back = named_run!(Fixtures.Holds)
      assert click.(open.("/executions/#{rolled_back}"), "rollback", %{}) == nil
      assert status(rolled_back) in [:compensating, :compensated, :pending]

      live_one = named_run!(Fixtures.HoldAwaitingCustomer)
      assert click.(open.("/executions/#{live_one}"), "rollback", %{}) == nil
      assert status(live_one) != :waiting

      done = named_run!(Fixtures.Payments)
      runs_before = repo().aggregate(WorkflowExecution, :count)
      assert click.(open.("/executions/#{done}"), "rerun", %{}) == nil
      assert repo().aggregate(WorkflowExecution, :count) == runs_before + 1

      keyed = named_run!(Fixtures.Invoices, %{}, key: "invoice:1")
      assert click.(open.("/executions/#{keyed}"), "release-key", %{}) == nil
      refute repo().get!(WorkflowExecution, keyed).holds_key

      # The Runs list's bulk bar.
      bulk = %{
        retry: named_run!(Fixtures.Payments, %{"decline" => true}),
        rerun: named_run!(Fixtures.Payments),
        release: named_run!(Fixtures.Invoices, %{}, key: "invoice:2"),
        cancel: named_run!(Fixtures.Webhooks)
      }

      runs_before = repo().aggregate(WorkflowExecution, :count)

      for {action, id} <- bulk do
        view = open.("/executions")
        render_click(view, "toggle", %{"id" => id})
        assert click.(view, "bulk", %{"action" => to_string(action)}) == nil
      end

      assert status(bulk.retry) != :failed
      assert repo().aggregate(WorkflowExecution, :count) == runs_before + 1
      refute repo().get!(WorkflowExecution, bulk.release).holds_key
      assert status(bulk.cancel) == :cancelled

      # The Inbox.
      asked = input_of(named_run!(Fixtures.Approvals))
      view = open.("/inputs?id=#{asked.id}")

      assert crash(fn ->
               view |> form("#answer-#{asked.id}") |> render_submit(%{"decision" => "approve"})
             end) == nil

      assert repo().get!(PendingInput, asked.id).status == :completed

      awaited = named_run!(Fixtures.Webhooks)
      event = repo().one!(from(e in PendingEvent, where: e.workflow_id == ^awaited))
      view = open.("/inputs?tab=events")
      render_click(view, "compose", %{"id" => event.id})
      assert crash(fn -> render_submit(view, "send", %{"payload" => "{}"}) end) == nil
      assert repo().get!(PendingEvent, event.id).status != :pending

      # Queues, schedules, settings.
      assert click.(open.("/queues"), "toggle", %{"queue" => "default"}) == nil
      assert Durable.paused_queues(named) == ["default"]

      {:ok, _} = Durable.schedule(Fixtures.Payments, "*/5 * * * *", [name: "sweep"] ++ named)
      assert click.(open.("/schedules"), "toggle", %{"name" => "sweep"}) == nil
      assert [%{enabled: false}] = Durable.list_schedules(named)

      runs_before = repo().aggregate(WorkflowExecution, :count)
      assert click.(open.("/schedules"), "run-now", %{"name" => "sweep"}) == nil
      assert repo().aggregate(WorkflowExecution, :count) == runs_before + 1

      view = open.("/settings")
      assert click.(view, "prune", %{}) == nil
      refute render(view) =~ "Pruning needs admin access."
    end
  end
end
