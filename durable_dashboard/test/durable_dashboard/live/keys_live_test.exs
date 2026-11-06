defmodule DurableDashboard.Live.KeysLiveTest do
  @moduledoc """
  Workflow keys across the dashboard: the run page (chip, banner, facts, the
  Key view, Retry and Rerun sentences, Release key), Runs (`key:` search and
  "Release N keys"), ⌘K and the workflow page's Keys section.
  """
  use DurableDashboard.LiveCase

  alias Fixtures.{Approvals, Digests, Invoices, Payments, Webhooks}

  # Starts a keyed run, inline unless `inline: false`; returns its id.
  defp start!(module, input, key, opts \\ []) do
    {:ok, id} = Durable.start(module, input, key: key, inline: Keyword.get(opts, :inline, true))
    id
  end

  defp text(html) do
    html
    |> String.replace("><", "> <")
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  describe "the run page" do
    test "a holder shows its key, how often it was re-added and the dropped input", %{conn: conn} do
      # Approvals waits for input, so the holder stays open.
      id = start!(Approvals, %{"amount" => 80}, "expense:7")
      {:ok, ^id} = Durable.start(Approvals, %{"amount" => 80}, key: "expense:7")
      {:ok, ^id} = Durable.start(Approvals, %{"amount" => 95}, key: "expense:7")

      {:ok, _view, html} = live(conn, dash("/executions/#{id}"))
      page = text(html)

      assert page =~ "key expense:7 Holds key"

      assert page =~
               "Added again 2 times while waiting. The newest input differs from this run's and was dropped"

      assert page =~ "Re-added 2×"
      assert page =~ "Key (2)"

      {:ok, view, html} = live(conn, dash("/executions/#{id}/key"))
      assert html =~ "Newer input dropped"
      assert html =~ "Same input"
      assert text(html) =~ "Holds the key"

      assert has_element?(view, "button[phx-click=toggle][aria-expanded=false]")
      html = view |> element("button[phx-click=toggle]") |> render_click()
      assert has_element?(view, "button[phx-click=toggle][aria-expanded=true]")
      assert html =~ "amount"
      assert html =~ "<del class=\"text-destructive\">80</del>"
      assert html =~ "95"
      assert html =~ "Copy input"
    end

    test "a run whose key moved names the holder, and Retry asks for it back", %{conn: conn} do
      old = start!(Payments, %{"decline" => true}, "pay:1")
      new = start!(Payments, %{}, "pay:1", inline: false)

      {:ok, view, html} = live(conn, dash("/executions/#{old}"))
      page = text(html)

      assert page =~ "Key moved"
      assert page =~ "Run #{String.slice(new, 0, 8)} took pay:1"

      assert page =~
               "Retry and rerun need pay:1 back. #{String.slice(new, 0, 8)} holds it and hasn't started yet"

      assert has_element?(view, "button[phx-click=retry][disabled]")

      # Once the newer run finishes, reuse: :after_close lets the key go back.
      Durable.Executor.execute_workflow(new, Durable.Config.get(Durable))

      {:ok, view, html} = live(conn, dash("/executions/#{old}"))
      assert html =~ "Retry and take the key back"
      view |> element("button[phx-click=retry]") |> render_click()

      assert %{status: :pending, holds_key: true} = Fixtures.get_run!(old)
      refute Fixtures.get_run!(new).holds_key
    end

    test "Release key confirms inline, then Rerun can go ahead", %{conn: conn} do
      id = start!(Invoices, %{}, "inv:1")

      {:ok, view, html} = live(conn, dash("/executions/#{id}"))

      assert text(html) =~
               "Rerun would be refused: this run holds inv:1 and the workflow's reuse is :never"

      assert has_element?(view, "button[phx-click=rerun][disabled]")

      view |> element("button[phx-click=confirm-release]") |> render_click()
      assert render(view) =~ "This run keeps its history"

      html = view |> element("button[phx-click=release-key]") |> render_click()

      refute Fixtures.get_run!(id).holds_key
      refute has_element?(view, "button[phx-click=rerun][disabled]")
      refute html =~ "Rerun would be refused"

      assert [%{details: %{"by" => "admin@example.com"}}] =
               Durable.Activity.list(kinds: ["key_released"])
    end

    test "a refused rerun says which run holds the key", %{conn: conn} do
      id = start!(Invoices, %{}, "inv:4")
      {:ok, view, _html} = live(conn, dash("/executions/#{id}"))
      assert render_hook(view, "rerun", %{}) =~ "holds this run&#39;s key, so it was refused."
    end

    @tag role: :viewer
    test "a viewer can't release a key", %{conn: conn} do
      id = start!(Invoices, %{}, "inv:2")
      {:ok, view, _html} = live(conn, dash("/executions/#{id}"))

      refute has_element?(view, "[phx-click=confirm-release]")
      assert render_hook(view, "release-key", %{}) =~ "You don&#39;t have permission to do that."
      assert Fixtures.get_run!(id).holds_key
    end

    test "a run without a key has no Key view", %{conn: conn} do
      id = Fixtures.run!(Payments)
      {:ok, view, html} = live(conn, dash("/executions/#{id}"))

      refute html =~ "Holds key"
      refute has_element?(view, ~s(a[href="/dashboard/executions/#{id}/key"]))
    end
  end

  describe "Runs" do
    test "key: finds the runs with that key and shows it under the id", %{conn: conn} do
      id = start!(Payments, %{}, "pay:9")
      other = Fixtures.run!(Payments)

      {:ok, view, _html} = live(conn, dash("/executions?q=" <> URI.encode_www_form("key:pay:9")))
      html = render(view)

      assert html =~ String.slice(id, 0, 8)
      refute html =~ String.slice(other, 0, 8)
      assert text(html) =~ "pay:9 · holds key"
    end

    test "the bulk bar releases the keys of the finished runs selected", %{conn: conn} do
      id = start!(Invoices, %{}, "inv:3")
      {:ok, view, _html} = live(conn, dash("/executions"))

      view |> element("[phx-click=toggle][phx-value-id='#{id}']") |> render_click()
      html = view |> element("[phx-click=bulk][phx-value-action=release]") |> render_click()

      assert html =~ "Released 1 of 1 key."
      refute Fixtures.get_run!(id).holds_key
    end
  end

  describe "the command palette" do
    test "a key-shaped query lists the run holding it", %{conn: conn} do
      start!(Payments, %{}, "pay:5")
      {:ok, view, _html} = live(conn, dash())

      view |> with_target("#command-palette") |> render_hook("palette:open", %{})

      html =
        view |> element("#command-palette form") |> render_change(%{value: "pay:5"})

      assert html =~ "Keys"
      assert text(html) =~ "pay:5 process_payment · held by"
    end
  end

  describe "the workflow page" do
    test "a keyed workflow gets a Keys section, others don't", %{conn: conn} do
      # Not run, so it stays pending and keeps the key (reuse: :after_close).
      id = start!(Payments, %{"n" => 1}, "pay:7", inline: false)
      {:ok, ^id} = Durable.start(Payments, %{"n" => 2}, key: "pay:7")
      Fixtures.run!(Fixtures.Orders)

      {:ok, view, html} = live(conn, dash("/workflows/process_payment"))
      assert has_element?(view, "section[aria-label=Keys]")
      page = text(html)
      assert page =~ "Keys held 1"
      assert page =~ "Re-added 1"
      assert page =~ "Newer input dropped 1"
      assert has_element?(view, ~s(a[href="/dashboard/executions/#{id}/key"]), "pay:7")

      {:ok, view, _html} = live(conn, dash("/workflows/fulfill_order"))
      refute has_element?(view, "section[aria-label=Keys]")
    end
  end

  describe "the run page, more" do
    test "Release key is offered only when it changes something", %{conn: conn} do
      # A failed holder under reuse: :after_close already lets its key go.
      failed = start!(Payments, %{"decline" => true}, "pay:20")
      {:ok, view, _html} = live(conn, dash("/executions/#{failed}"))
      refute has_element?(view, "button[phx-click=confirm-release]")

      kept = start!(Invoices, %{}, "inv:20")
      {:ok, view, _html} = live(conn, dash("/executions/#{kept}"))
      assert has_element?(view, "button[phx-click=confirm-release]")
    end

    test "a released key reads Key released, not Key moved", %{conn: conn} do
      id = start!(Invoices, %{}, "inv:21")
      :ok = Durable.release_key(id)

      {:ok, _view, html} = live(conn, dash("/executions/#{id}"))
      page = text(html)
      assert page =~ "key inv:21 Key released"
      refute page =~ "Key moved"
    end

    test "a run replaced by :cancel_existing links the run that replaced it", %{conn: conn} do
      old = start!(Webhooks, %{"n" => 1}, "hook:1")

      {:ok, new} =
        Durable.start(Webhooks, %{"n" => 2}, key: "hook:1", on_duplicate: :cancel_existing)

      {:ok, view, html} = live(conn, dash("/executions/#{old}"))
      assert text(html) =~ "Cancelled — replaced by run #{String.slice(new, 0, 8)}"
      assert has_element?(view, ~s(a[href="/dashboard/executions/#{new}/key"]))
      refute text(html) =~ "took hook:1"

      {:ok, _view, html} = live(conn, dash("/executions/#{old}/key"))
      assert text(html) =~ "Replaced this run"
      assert text(html) =~ "Replaced by #{String.slice(new, 0, 8)}"
    end

    test "{:send_event, name} shows as sent, and a kept event shows in the facts", %{conn: conn} do
      waiting = start!(Webhooks, %{}, "hook:2")

      {:ok, ^waiting} =
        Durable.start(Webhooks, %{"n" => 2},
          key: "hook:2",
          on_duplicate: {:send_event, "webhook_received"}
        )

      {:ok, _view, html} = live(conn, dash("/executions/#{waiting}/key"))
      assert text(html) =~ "Sent as event webhook_received"

      # Not started yet, so the event is kept until it waits for it.
      pending = start!(Webhooks, %{}, "hook:3", inline: false)

      {:ok, ^pending} =
        Durable.start(Webhooks, %{"n" => 2},
          key: "hook:3",
          on_duplicate: {:send_event, "webhook_received"}
        )

      {:ok, _view, html} = live(conn, dash("/executions/#{pending}"))
      assert text(html) =~ "Kept events 1 · webhook_received"
    end

    test "a debounced run says when it starts, and a re-add shows as debounced", %{conn: conn} do
      {:ok, id} = Durable.start(Digests, %{"n" => 1}, key: "dig:1")
      {:ok, ^id} = Durable.start(Digests, %{"n" => 2}, key: "dig:1")

      {:ok, _view, html} = live(conn, dash("/executions/#{id}"))
      assert text(html) =~ "Debounced: starts"
      assert text(html) =~ "unless dig:1 is added again; at the latest"

      {:ok, _view, html} = live(conn, dash("/executions/#{id}/key"))
      assert text(html) =~ "Gave it the newer input (debounce)"
    end
  end

  describe "the workflow page, more" do
    test "shows Replaced, Sent and Debounced only where they apply", %{conn: conn} do
      start!(Webhooks, %{}, "hook:10")

      {:ok, _} =
        Durable.start(Webhooks, %{"n" => 2}, key: "hook:10", on_duplicate: :cancel_existing)

      {:ok, _} = Durable.start(Digests, %{}, key: "dig:10")
      start!(Payments, %{}, "pay:10", inline: false)
      {:ok, _} = Durable.start(Payments, %{}, key: "pay:10")

      {:ok, _view, html} = live(conn, dash("/workflows/await_webhook"))
      assert text(html) =~ "Replaced 1"
      refute text(html) =~ "Debounced"

      {:ok, _view, html} = live(conn, dash("/workflows/send_digest"))
      assert text(html) =~ "Debounced 0"
      assert text(html) =~ "debounce 1 min, at most 5 min"

      {:ok, _view, html} = live(conn, dash("/workflows/process_payment"))
      refute text(html) =~ "Replaced"
      refute text(html) =~ "Debounced"
    end
  end

  describe "the Keys page" do
    test "lists each key with its holder, and the sidebar links to it", %{conn: conn} do
      held = start!(Invoices, %{}, "inv:30")
      {:ok, ^held} = Durable.start(Invoices, %{"x" => 1}, key: "inv:30")
      start!(Payments, %{}, "pay:30", inline: false)

      {:ok, view, html} = live(conn, dash("/keys"))
      page = text(html)

      assert page =~ "2 keys"
      assert page =~ "inv:30 send_invoice #{String.slice(held, 0, 8)} Completed 1 1 1"
      assert page =~ ":never"
      assert has_element?(view, ~s(nav a[href="/dashboard/keys"]))

      assert has_element?(
               view,
               ~s(a[href="/dashboard/workflows/send_invoice/runs?q=key%3Ainv%3A30"])
             )
    end

    test "filters by key prefix, workflow and holder status, in the URL", %{conn: conn} do
      start!(Invoices, %{}, "inv:40")
      start!(Payments, %{}, "pay:40", inline: false)

      {:ok, view, _html} = live(conn, dash("/keys"))

      view |> element("form[role=search]") |> render_change(%{"q" => "inv:", "workflow" => ""})
      assert_patch(view, "/dashboard/keys?q=inv%3A")
      assert render(view) =~ "inv:40"
      refute render(view) =~ "pay:40"

      {:ok, view, _html} = live(conn, dash("/keys"))
      view |> element("button[phx-click=toggle-status-menu]") |> render_click()
      view |> element("button[phx-value-status=pending]") |> render_click()
      assert_patch(view, "/dashboard/keys?status=pending")
      html = render(view)
      assert html =~ "pay:40"
      refute html =~ "inv:40"

      {:ok, _view, html} = live(conn, dash("/keys?workflow=send_invoice"))
      assert html =~ "inv:40"
      refute html =~ "pay:40"

      {:ok, _view, html} = live(conn, dash("/keys?q=nothing-like-this"))
      assert html =~ "No keys match these filters"
    end

    test "says so when no run has a key", %{conn: conn} do
      Fixtures.run!(Payments)
      {:ok, _view, html} = live(conn, dash("/keys"))
      assert html =~ "No run was started with a key"
    end

    test "⌘K goes to it", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash())
      view |> with_target("#command-palette") |> render_hook("palette:open", %{})
      html = view |> element("#command-palette form") |> render_change(%{value: "keys"})
      assert html =~ "/dashboard/keys"
    end
  end

  test "Queues' Operations leaves key events out", %{conn: conn} do
    id = start!(Payments, %{}, "pay:3", inline: false)
    {:ok, ^id} = Durable.start(Payments, %{}, key: "pay:3")

    {:ok, _view, html} = live(conn, dash("/queues"))
    refute html =~ "key_duplicate"
  end
end
