defmodule DurableDashboard.Live.KeysLiveTest do
  @moduledoc """
  Workflow keys across the dashboard: the run page (chip, banner, facts, the
  Key view, Retry and Rerun sentences, Release key), Runs (`key:` search and
  "Release N keys"), ⌘K and the workflow page's Keys section.
  """
  use DurableDashboard.LiveCase

  alias Fixtures.{Approvals, Invoices, Payments}

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
               "Added again 2 times while running. The newest input differs from this run's and was dropped"

      assert page =~ "Re-added 2×"
      assert page =~ "Key (2)"

      {:ok, view, html} = live(conn, dash("/executions/#{id}/key"))
      assert html =~ "Newer input dropped"
      assert html =~ "Same input"
      assert text(html) =~ "Holds the key"

      html = view |> element("tr[phx-click=toggle]") |> render_click()
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
               "Retry needs pay:1 back. #{String.slice(new, 0, 8)} holds it and hasn't started yet"

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
      refute has_element?(view, "a", "Key")
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

  test "Queues' Operations leaves key events out", %{conn: conn} do
    id = start!(Payments, %{}, "pay:3", inline: false)
    {:ok, ^id} = Durable.start(Payments, %{}, key: "pay:3")

    {:ok, _view, html} = live(conn, dash("/queues"))
    refute html =~ "key_duplicate"
  end
end
