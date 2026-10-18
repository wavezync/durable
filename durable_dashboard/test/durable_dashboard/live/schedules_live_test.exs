defmodule DurableDashboard.Live.SchedulesLiveTest do
  @moduledoc "Schedules: the list, on/off, Run now, and a schedule's own page."
  use DurableDashboard.LiveCase

  import Ecto.Query

  alias Durable.Storage.Schemas.WorkflowExecution

  defp switch(name), do: ~s(button[role="switch"][phx-value-name="#{name}"])
  defp run_now(name), do: ~s(button[phx-click="run-now"][phx-value-name="#{name}"])

  defp enabled?(name) do
    {:ok, schedule} = Durable.get_schedule(name)
    schedule.enabled
  end

  defp scheduled_runs(name) do
    Durable.Config.get(Durable).repo.all(
      from(w in WorkflowExecution, where: w.trigger == :schedule and w.trigger_ref == ^name)
    )
  end

  describe "the list" do
    test "shows each schedule's cadence in words, whether it's on, and when it fires", %{
      conn: conn
    } do
      Fixtures.schedule!("card_sweep")
      Fixtures.schedule!("nightly", cron: "0 2 * * *", enabled: false)

      {:ok, view, html} = live(conn, dash("/schedules"))

      assert html =~ "2 schedules · 1 on"
      assert has_element?(view, "tr", "Every 5 minutes")
      assert has_element?(view, "tr", "*/5 * * * *")
      assert has_element?(view, "tr", "Every day at 02:00")
      assert has_element?(view, switch("card_sweep") <> ~s([aria-checked="true"]))
      assert has_element?(view, switch("nightly") <> ~s([aria-checked="false"]))

      assert has_element?(
               view,
               ~s|tr:has(a[href="/dashboard/schedules/card_sweep"]) time[data-rel]|
             )

      assert has_element?(view, ~s|tr:has(a[href="/dashboard/schedules/nightly"])|, "Off")
    end

    test "with none, it says how to add one", %{conn: conn} do
      {:ok, _view, html} = live(conn, dash("/schedules"))
      assert html =~ "No schedules"
    end

    test "the switch turns a schedule off and back on", %{conn: conn} do
      Fixtures.schedule!("card_sweep")

      {:ok, view, _html} = live(conn, dash("/schedules"))

      view |> element(switch("card_sweep")) |> render_click()
      refute enabled?("card_sweep")
      assert has_element?(view, switch("card_sweep") <> ~s([aria-checked="false"]))

      # Turning it back on used to crash on the next-run timestamp's precision.
      view |> element(switch("card_sweep")) |> render_click()
      assert enabled?("card_sweep")
      assert has_element?(view, switch("card_sweep") <> ~s([aria-checked="true"]))
      {:ok, schedule} = Durable.get_schedule("card_sweep")
      assert DateTime.compare(schedule.next_run_at, DateTime.utc_now()) == :gt
    end

    test "Run now starts a run from the schedule and opens it", %{conn: conn} do
      Fixtures.schedule!("card_sweep")

      {:ok, view, _html} = live(conn, dash("/schedules"))
      view |> element(run_now("card_sweep")) |> render_click()

      assert [run] = scheduled_runs("card_sweep")
      assert run.workflow_name == "process_payment"
      assert_redirect(view, dash("/executions/#{run.id}"))
    end
  end

  describe "a schedule's page" do
    test "shows its facts, next fires and the switch", %{conn: conn} do
      Fixtures.schedule!("card_sweep")

      {:ok, view, html} = live(conn, dash("/schedules/card_sweep"))

      assert has_element?(view, "h1", "card_sweep")
      assert html =~ "Every 5 minutes"
      assert has_element?(view, ~s(a[href="/dashboard/workflows/process_payment"]))
      assert has_element?(view, switch("card_sweep") <> ~s([aria-checked="true"]))
      assert has_element?(view, run_now("card_sweep"))
      # The next six times it fires.
      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("ol li time[data-format]")
             |> Enum.count() == 6
    end

    test "lists the runs it started, and links to them all in Runs", %{conn: conn} do
      Fixtures.schedule!("card_sweep")
      {:ok, run_id} = Durable.trigger_schedule("card_sweep")

      {:ok, view, _html} = live(conn, dash("/schedules/card_sweep"))

      assert has_element?(view, ~s(a[href="/dashboard/executions/#{run_id}"]))
      all_runs = dash("/executions?" <> URI.encode_query(q: "schedule:card_sweep"))
      assert has_element?(view, ~s(a[href="#{all_runs}"]), "All its runs")

      {:ok, runs, _html} = live(conn, all_runs)
      assert has_element?(runs, ~s(a[href="/dashboard/executions/#{run_id}"]))
    end

    test "the switch works from the page too", %{conn: conn} do
      Fixtures.schedule!("card_sweep")

      {:ok, view, _html} = live(conn, dash("/schedules/card_sweep"))
      view |> element(switch("card_sweep")) |> render_click()

      refute enabled?("card_sweep")
      assert has_element?(view, "header", "Off")
    end

    test "an unknown name says there's no such schedule", %{conn: conn} do
      {:ok, _view, html} = live(conn, dash("/schedules/nope"))
      assert html =~ "No schedule named nope"
    end
  end
end
