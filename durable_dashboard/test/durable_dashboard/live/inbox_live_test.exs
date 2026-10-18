defmodule DurableDashboard.Live.InboxLiveTest do
  @moduledoc "The Inbox: answering inputs, sending events, sleeping runs."
  use DurableDashboard.LiveCase

  import Ecto.Query

  alias Durable.Storage.Schemas.{PendingEvent, PendingInput}

  defmodule ExpenseForm do
    @moduledoc false
    use Durable
    use Durable.Wait

    workflow "expense_form" do
      step(:collect, fn data ->
        _ =
          wait_for_form("expense_details",
            prompt: "Submit expense",
            fields: [
              %{name: "amount", type: "number", required: true, label: "Amount"},
              %{name: "note", type: "text"}
            ]
          )

        {:ok, data}
      end)
    end
  end

  defmodule Shipping do
    @moduledoc false
    use Durable
    use Durable.Wait

    workflow "pick_shipping" do
      step(:ask, fn data ->
        _ =
          wait_for_choice("shipping_method",
            prompt: "Select shipping method",
            choices: [
              %{value: "express", label: "Express ($15)"},
              %{value: "standard", label: "Standard (Free)"}
            ]
          )

        {:ok, data}
      end)
    end
  end

  defmodule Nap do
    @moduledoc false
    use Durable
    use Durable.Wait

    workflow "nap" do
      step(:doze, fn data ->
        sleep(hours(1))
        {:ok, data}
      end)
    end
  end

  defp repo, do: Durable.Config.get(Durable).repo

  defp pending_input(run_id),
    do: repo().one!(from(p in PendingInput, where: p.workflow_id == ^run_id))

  defp short(id), do: String.slice(id, 0, 8)

  describe "needs input" do
    test "a waiting approval is listed with its prompt and opens on click", %{conn: conn} do
      _first = Fixtures.run!(Fixtures.Approvals)
      second = Fixtures.run!(Fixtures.Approvals)
      input = pending_input(second)

      {:ok, view, html} = live(conn, dash("/inputs"))
      assert html =~ "Approve $80 Meals expense from Bo?"
      assert has_element?(view, ~s(nav a[href="/dashboard/inputs?tab=input"]), "2")

      view |> element(~s(a[href="/dashboard/inputs?tab=input&id=#{input.id}"])) |> render_click()

      assert_patch(view, dash("/inputs?tab=input&id=#{input.id}"))
      assert has_element?(view, "#task-#{input.id}")
      assert has_element?(view, "#answer-#{input.id}")
    end

    test "Approve answers it: the run resumes and the URL drops the answered id", %{conn: conn} do
      run_id = Fixtures.run!(Fixtures.Approvals)
      input = pending_input(run_id)

      {:ok, view, _html} = live(conn, dash("/inputs?tab=input&id=#{input.id}"))

      view
      |> form("#answer-#{input.id}", %{"comment" => ""})
      |> render_submit(%{"decision" => "approve"})

      assert_patch(view, dash("/inputs?tab=input"))

      assert render(view) =~
               "Answered manager_approval on expense_approval · #{short(run_id)} — the run resumes."

      answered = pending_input(run_id)
      assert answered.status == :completed
      assert answered.response == %{"approved" => true, "by" => "admin@example.com"}
      assert Fixtures.get_run!(run_id).status != :waiting
      assert render(view) =~ "Nothing waiting on a person"
    end

    test "Reject sends approved: false with the comment", %{conn: conn} do
      run_id = Fixtures.run!(Fixtures.Approvals)
      input = pending_input(run_id)

      {:ok, view, _html} = live(conn, dash("/inputs"))

      view
      |> form("#answer-#{input.id}", %{"comment" => "  over budget  "})
      |> render_submit(%{"decision" => "reject"})

      assert %{
               status: :completed,
               response: %{"approved" => false, "comment" => "over budget"}
             } = pending_input(run_id)
    end

    test "a form checks required and number fields before answering", %{conn: conn} do
      run_id = Fixtures.run!(ExpenseForm)
      input = pending_input(run_id)

      {:ok, view, html} = live(conn, dash("/inputs"))
      assert html =~ "Submit expense"

      html =
        view |> form("#answer-#{input.id}", %{"fields" => %{"amount" => ""}}) |> render_submit()

      assert html =~ "Amount: required"
      assert pending_input(run_id).status == :pending

      html =
        view
        |> form("#answer-#{input.id}", %{"fields" => %{"amount" => "lots"}})
        |> render_submit()

      assert html =~ "Amount: not a number"
      assert pending_input(run_id).status == :pending

      view
      |> form("#answer-#{input.id}", %{"fields" => %{"amount" => "12.5", "note" => "taxi"}})
      |> render_submit()

      assert %{status: :completed, response: %{"amount" => 12.5, "note" => "taxi"}} =
               pending_input(run_id)
    end

    test "a choice needs one option picked, and sends its value", %{conn: conn} do
      run_id = Fixtures.run!(Shipping)
      input = pending_input(run_id)

      {:ok, view, html} = live(conn, dash("/inputs"))
      assert html =~ "Express ($15)"

      view |> form("#answer-#{input.id}") |> render_submit()
      assert has_element?(view, "[role=alert]", "Pick one option.")
      assert pending_input(run_id).status == :pending

      view |> form("#answer-#{input.id}", %{"choice" => "express"}) |> render_submit()
      # Stored wrapped (a plain value in a JSONB map column).
      assert %{status: :completed, response: %{"value" => "express"}} = pending_input(run_id)
    end

    test "the sidebar badge counts what's left after answering", %{conn: conn} do
      run_id = Fixtures.run!(Fixtures.Approvals)
      _other = Fixtures.run!(Fixtures.Approvals)
      input = pending_input(run_id)

      {:ok, view, _html} = live(conn, dash("/inputs?tab=input&id=#{input.id}"))
      assert has_element?(view, ~s([aria-label="2 waiting"]))

      view |> form("#answer-#{input.id}") |> render_submit(%{"decision" => "approve"})

      assert has_element?(view, ~s([aria-label="1 waiting"]))
      refute has_element?(view, ~s([aria-label="2 waiting"]))
    end

    test "answering a request someone else already answered says so", %{conn: conn} do
      run_id = Fixtures.run!(Fixtures.Approvals)
      input = pending_input(run_id)

      {:ok, view, _html} = live(conn, dash("/inputs?tab=input&id=#{input.id}"))
      :ok = Durable.provide_input(run_id, "manager_approval", %{"approved" => true})

      view |> form("#answer-#{input.id}") |> render_submit(%{"decision" => "reject"})

      assert has_element?(
               view,
               "[role=alert]",
               "It's no longer waiting — someone may have answered it already."
             )

      assert %{response: %{"approved" => true}} = pending_input(run_id)
    end

    test "with nothing waiting, it says so", %{conn: conn} do
      {:ok, _view, html} = live(conn, dash("/inputs"))
      assert html =~ "Nothing waiting on a person"
    end
  end

  describe "waiting for events" do
    test "lists the wait and delivers the event from the Send form", %{conn: conn} do
      run_id = Fixtures.run!(Fixtures.Webhooks)

      {:ok, view, html} = live(conn, dash("/inputs?tab=events"))
      assert html =~ "webhook_received"
      assert html =~ "await_webhook"
      assert has_element?(view, ~s(nav a[href="/dashboard/inputs?tab=events"]), "1")

      view |> element(~s(button[phx-click="compose"])) |> render_click()

      html =
        view
        |> form(~s(form[phx-submit="send"]), %{"payload" => ~s({"ok": true})})
        |> render_submit()

      assert html =~ "Sent webhook_received to await_webhook · #{short(run_id)}"

      event = repo().one!(from(e in PendingEvent, where: e.workflow_id == ^run_id))
      assert event.status != :pending
      assert Fixtures.get_run!(run_id).status != :waiting
      assert html =~ "No run is waiting for an event"
    end

    test "a payload that isn't JSON is refused", %{conn: conn} do
      run_id = Fixtures.run!(Fixtures.Webhooks)

      {:ok, view, _html} = live(conn, dash("/inputs?tab=events"))
      view |> element(~s(button[phx-click="compose"])) |> render_click()

      view |> form(~s(form[phx-submit="send"]), %{"payload" => "{nope"}) |> render_submit()

      assert has_element?(view, "[role=alert]", "The payload isn't valid JSON.")

      assert repo().one!(from(e in PendingEvent, where: e.workflow_id == ^run_id)).status ==
               :pending
    end
  end

  describe "sleeping" do
    test "an empty tab says nothing is sleeping", %{conn: conn} do
      {:ok, _view, html} = live(conn, dash("/inputs?tab=sleep"))
      assert html =~ "No run is sleeping"
    end

    test "a sleeping run is listed with its step", %{conn: conn} do
      run_id = Fixtures.run!(Nap)

      {:ok, view, html} = live(conn, dash("/inputs?tab=sleep"))
      assert html =~ "nap"
      assert html =~ "doze"
      assert has_element?(view, ~s(a[href="/dashboard/executions/#{run_id}"]))
      assert has_element?(view, ~s(nav a[href="/dashboard/inputs?tab=sleep"]), "1")
    end
  end
end
