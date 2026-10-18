defmodule DurableDashboard.Live.AccessLiveTest do
  @moduledoc """
  What each access level may do — checked on the server, not just in the
  markup: a viewer who pushes an action's event anyway is refused and nothing
  changes. Every attempt emits `[:durable_dashboard, :action]`.
  """
  use DurableDashboard.LiveCase

  import Ecto.Query

  alias Durable.Storage.Schemas.{PendingInput, WorkflowExecution}

  @refused "You don't have permission to do that."

  defp repo, do: Durable.Config.get(Durable).repo
  defp run_count, do: repo().aggregate(WorkflowExecution, :count)

  defp pending_input(run_id),
    do: repo().one!(from(p in PendingInput, where: p.workflow_id == ^run_id))

  defp enabled?(name) do
    {:ok, schedule} = Durable.get_schedule(name)
    schedule.enabled
  end

  defp attach_audit do
    id = "audit-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      id,
      [:durable_dashboard, :action],
      fn _event, measurements, meta, _ -> send(test, {:audit, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "a viewer" do
    @describetag role: :viewer

    test "sees no run actions, and forcing them changes nothing", %{conn: conn} do
      failed = Fixtures.run!(Fixtures.Payments, %{"decline" => true})
      waiting = Fixtures.run!(Fixtures.Approvals)
      before = run_count()

      {:ok, view, _html} = live(conn, dash("/executions/#{failed}"))
      refute has_element?(view, ~s(button[phx-click="retry"]))
      refute has_element?(view, ~s(button[phx-click="rerun"]))

      render_click(view, "retry", %{})
      assert has_element?(view, "[role=alert]", @refused)
      render_click(view, "rerun", %{})
      assert Fixtures.get_run!(failed).status == :failed
      assert run_count() == before

      {:ok, view, _html} = live(conn, dash("/executions/#{waiting}"))
      refute has_element?(view, ~s(button[phx-click="cancel"]))
      render_click(view, "cancel", %{})
      assert has_element?(view, "[role=alert]", @refused)
      assert Fixtures.get_run!(waiting).status == :waiting
    end

    test "can't select runs for bulk actions, or force one", %{conn: conn} do
      failed = Fixtures.run!(Fixtures.Payments, %{"decline" => true})

      {:ok, view, _html} = live(conn, dash("/executions"))
      refute has_element?(view, ~s(input[phx-click="toggle"]))

      render_click(view, "toggle", %{"id" => failed})
      render_click(view, "bulk", %{"action" => "retry"})

      assert has_element?(view, "[role=status]", @refused)
      assert Fixtures.get_run!(failed).status == :failed
    end

    test "can't pause a queue", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/queues"))
      refute has_element?(view, ~s(button[phx-click="toggle"]))

      render_click(view, "toggle", %{"queue" => "default"})

      assert has_element?(view, "[role=alert]", @refused)
      assert Durable.paused_queues() == []
    end

    test "can't turn schedules on or off or run them", %{conn: conn} do
      Fixtures.schedule!("card_sweep")
      before = run_count()

      {:ok, view, _html} = live(conn, dash("/schedules"))
      assert has_element?(view, ~s(button[role="switch"][disabled]))
      refute has_element?(view, ~s(button[phx-click="run-now"]))

      render_click(view, "toggle", %{"name" => "card_sweep"})
      assert has_element?(view, "[role=alert]", @refused)
      assert enabled?("card_sweep")

      render_click(view, "run-now", %{"name" => "card_sweep"})
      assert run_count() == before
    end

    test "can read an input but not answer it", %{conn: conn} do
      run_id = Fixtures.run!(Fixtures.Approvals)
      input = pending_input(run_id)

      {:ok, view, html} = live(conn, dash("/inputs"))
      assert html =~ "You can see this task but not answer it"
      assert has_element?(view, "fieldset[disabled]")

      render_submit(view, "decide", %{"decision" => "approve"})

      assert has_element?(view, "[role=alert]", @refused)
      assert pending_input(run_id).status == :pending
      assert input.id == pending_input(run_id).id
    end
  end

  describe "an operator" do
    @describetag role: :operator

    test "can retry a failed run and cancel a waiting one", %{conn: conn} do
      failed = Fixtures.run!(Fixtures.Payments, %{"decline" => true})
      waiting = Fixtures.run!(Fixtures.Approvals)

      {:ok, view, _html} = live(conn, dash("/executions/#{failed}"))
      view |> element(~s(button[phx-click="retry"])) |> render_click()
      refute Fixtures.get_run!(failed).status == :failed

      {:ok, view, _html} = live(conn, dash("/executions/#{waiting}"))
      view |> element(~s(button[phx-click="cancel"])) |> render_click()
      assert Fixtures.get_run!(waiting).status == :cancelled
    end

    test "can pause a queue and answer an input", %{conn: conn} do
      run_id = Fixtures.run!(Fixtures.Approvals)
      input = pending_input(run_id)

      {:ok, view, _html} = live(conn, dash("/queues"))
      view |> element(~s(button[phx-click="toggle"][phx-value-queue="default"])) |> render_click()
      assert Durable.paused_queues() == ["default"]

      {:ok, view, _html} = live(conn, dash("/inputs"))
      view |> form("#answer-#{input.id}") |> render_submit(%{"decision" => "approve"})
      assert pending_input(run_id).status == :completed
    end

    test "can run a schedule now but not turn it on or off — that's for admins", %{conn: conn} do
      Fixtures.schedule!("card_sweep")

      {:ok, view, _html} = live(conn, dash("/schedules"))
      assert has_element?(view, ~s(button[role="switch"][disabled]))

      render_click(view, "toggle", %{"name" => "card_sweep"})
      assert has_element?(view, "[role=alert]", @refused)
      assert enabled?("card_sweep")

      view |> element(~s(button[phx-click="run-now"])) |> render_click()
      assert {path, _flash} = assert_redirect(view)
      assert path =~ "/dashboard/executions/"
    end
  end

  describe "the audit event" do
    @describetag role: :operator

    test "records who did what to which, and whether it was allowed", %{conn: conn} do
      attach_audit()

      {:ok, view, _html} = live(conn, dash("/queues"))
      view |> element(~s(button[phx-click="toggle"][phx-value-queue="default"])) |> render_click()

      assert_receive {:audit, %{count: 1},
                      %{
                        action: :pause_queue,
                        user: "operator@example.com",
                        ids: ["default"],
                        result: :ok
                      }}

      Fixtures.schedule!("card_sweep")
      {:ok, view, _html} = live(conn, dash("/schedules"))
      render_click(view, "toggle", %{"name" => "card_sweep"})

      assert_receive {:audit, _measurements,
                      %{
                        action: :disable_schedule,
                        ids: ["card_sweep"],
                        result: {:error, :forbidden}
                      }}
    end
  end
end
