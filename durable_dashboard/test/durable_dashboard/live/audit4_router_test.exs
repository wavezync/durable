Code.require_file("../audit4_support_test.exs", __DIR__)

defmodule DurableDashboard.Live.Audit4RouterTest do
  @moduledoc """
  Hardening: the router macro mounted at `/`, at a nested path with a trailing
  slash, and inside a `scope` — every page mounts and every internal link
  stays under the mount. And the list pages run the same number of queries
  however many rows they show.
  """
  use DurableDashboard.LiveCase

  alias Durable.Storage.Schemas.{PendingInput, StepExecution, WorkflowExecution}

  @endpoint Audit4Dash.Endpoint

  setup_all do
    start_supervised!(Audit4Dash.Endpoint)
    :ok
  end

  defp repo, do: DurableDashboard.TestRepo

  defp pages(run_id) do
    ~w(/ /executions /executions/#{run_id} /executions/#{run_id}/graph
       /executions/#{run_id}/logs /executions/#{run_id}/context /executions/#{run_id}/family
       /workflows /workflows/process_payment /workflows/process_payment/runs /inputs
       /inputs?tab=events /keys /queues /schedules /schedules/card_sweep /telemetry /settings)
  end

  defp internal_links(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("a[href]")
    |> LazyHTML.attribute("href")
    |> Enum.filter(&String.starts_with?(&1, "/"))
  end

  # Inside a `scope` the pages are under the scope's path, but the dashboard
  # used to be told only the path it was given: its links and its stylesheet
  # pointed outside the mount.
  for {router, base} <- [
        {Audit4Dash.RootRouter, ""},
        {Audit4Dash.NestedRouter, "/admin/ops/durable"},
        {Audit4Dash.ScopedRouter, "/admin/durable"}
      ] do
    test "mounted at #{inspect(base)}: every page renders and links stay inside", %{conn: conn} do
      base = unquote(base)
      conn = Plug.Conn.put_private(conn, :audit4_router, unquote(router))
      run_id = Fixtures.run!(Fixtures.Payments, %{"decline" => true})
      Fixtures.run!(Fixtures.Approvals)
      Fixtures.schedule!("card_sweep")

      for page <- pages(run_id) do
        path =
          if base == "" and page == "/", do: "/", else: String.trim_trailing(base <> page, "/")

        {:ok, view, html} = live(conn, path)
        links = internal_links(html) ++ internal_links(render(view))

        assert links != []

        inside? = fn link ->
          link == base or String.starts_with?(link, [base <> "/", base <> "?"])
        end

        assert Enum.all?(links, inside?), "#{path}: #{inspect(links)}"

        refute Enum.any?(links, &String.contains?(&1, "//")), "#{path}: #{inspect(links)}"
      end

      # The stylesheet, the script and the favicon come from the mount's own
      # asset route.
      # (Mounted at "/", they were asked for at "//__assets__/app.css", which
      # a browser reads as the host "__assets__": the page had no styles and
      # no script.)
      document =
        conn
        |> get(if(base == "", do: "/", else: base))
        |> html_response(200)
        |> LazyHTML.from_document()

      assets =
        Enum.filter(
          LazyHTML.attribute(LazyHTML.query(document, "link[rel=stylesheet]"), "href") ++
            LazyHTML.attribute(LazyHTML.query(document, "link[rel=icon]"), "href") ++
            LazyHTML.attribute(LazyHTML.query(document, "script[src]"), "src"),
          &String.starts_with?(&1, "/")
        )

      assert length(assets) == 3

      # The tab says which page, and that it's Durable's.
      assert LazyHTML.text(LazyHTML.query(document, "title")) == "Overview · Durable"
      assert Enum.all?(assets, &String.starts_with?(&1, base <> "/__assets__/")), inspect(assets)
      for asset <- assets, do: assert(get(conn, asset).status == 200)

      # Navigation and an action work from the mount, not just the first render.
      {:ok, view, _html} = live(conn, if(base == "", do: "/", else: base))
      view |> with_target("#command-palette") |> render_hook("palette:open", %{})
      view |> element("#command-palette form") |> render_change(%{value: "Runs"})
      view |> with_target("#command-palette") |> render_hook("palette:activate", %{})
      assert_redirect(view, base <> "/executions")

      {:ok, view, _html} = live(conn, base <> "/executions/#{run_id}")
      view |> element(~s(button[phx-click="rerun"])) |> render_click()
      {path, _flash} = assert_redirect(view)
      assert String.starts_with?(path, base <> "/executions/")
    end
  end

  test "the macro compiles inside a scope" do
    name = "Audit4Dash.ScopedRouter#{System.unique_integer([:positive])}"

    modules =
      Code.compile_string("""
             defmodule #{name} do
               use Phoenix.Router
               import Phoenix.LiveView.Router
               import DurableDashboard.Router

               scope "/admin" do
                 dashboard_routes "/durable", durable: Durable
               end
      end
      """)

    router = Enum.find_value(modules, fn {module, _} -> inspect(module) == name and module end)
    paths = Enum.map(router.__routes__(), & &1.path)
    assert "/admin/durable" in paths
    assert "/admin/durable/executions/:id/:tab" in paths
    assert "/admin/durable/__assets__" in paths
  end

  describe "queries per page load" do
    setup do
      counter = :counters.new(1, [])
      handler = "audit4-queries-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:durable_dashboard, :test_repo, :query],
        fn _event, _measurements, _meta, _ -> :counters.add(counter, 1, 1) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      {:ok, counter: counter}
    end

    defp queries(conn, counter, path) do
      :counters.put(counter, 1, 0)
      {:ok, _view, _html} = live(conn, dash(path))
      :counters.get(counter, 1)
    end

    defp seed_rows(count) do
      now = DateTime.utc_now()

      runs =
        for i <- 1..count do
          %{
            id: Ecto.UUID.generate(),
            workflow_module: "Elixir.DurableDashboard.Fixtures.Payments",
            workflow_name: "process_payment",
            status: Enum.at([:completed, :failed, :waiting, :pending], rem(i, 4)),
            input: %{"i" => i},
            error: if(rem(i, 4) == 1, do: %{"message" => "boom #{rem(i, 40)}", "type" => "E"}),
            current_step: "authorize",
            started_at: now,
            scheduled_at: now,
            key: "k:#{System.unique_integer([:positive])}",
            holds_key: true,
            tags: ["t:#{rem(i, 9)}"],
            inserted_at: DateTime.add(now, -i, :second),
            updated_at: now
          }
        end

      repo().insert_all(WorkflowExecution, runs)

      repo().insert_all(
        StepExecution,
        for run <- runs, name <- ~w(validate authorize) do
          %{
            id: Ecto.UUID.generate(),
            workflow_id: run.id,
            step_name: name,
            status: :completed,
            started_at: now,
            completed_at: now,
            duration_ms: 5,
            inserted_at: now,
            updated_at: now
          }
        end
      )

      repo().insert_all(
        PendingInput,
        for run <- runs, run.status == :waiting do
          %{
            id: Ecto.UUID.generate(),
            workflow_id: run.id,
            input_name: "ok",
            step_name: "authorize",
            input_type: :approval,
            status: :pending,
            inserted_at: now,
            updated_at: now
          }
        end
      )
    end

    test "don't grow with the rows on the page (no N+1)", %{conn: conn, counter: counter} do
      pages = ~w(/executions /executions?status=failed /executions?status=pending /inputs
                 /inputs?tab=sleep /keys /workflows / /workflows/process_payment/runs)

      seed_rows(4)
      few = Map.new(pages, &{&1, queries(conn, counter, &1)})

      seed_rows(2_000)
      many = Map.new(pages, &{&1, queries(conn, counter, &1)})

      for page <- pages,
          do: assert(many[page] <= few[page], "#{page}: #{few[page]} → #{many[page]}")

      # Two mounts (static, then connected) of a bounded page each.
      assert Enum.all?(many, fn {_page, count} -> count <= 80 end), inspect(many)
    end

    test "a page past the end, and the last page, are one bounded load each", %{
      conn: conn,
      counter: counter
    } do
      seed_rows(60)

      {:ok, _view, html} = live(conn, dash("/executions?page=3"))
      assert html =~ "51–60 of 60"

      {:ok, _view, html} = live(conn, dash("/executions?page=4"))
      assert html =~ "No runs"

      assert queries(conn, counter, "/executions?page=368934881474191032") <=
               queries(conn, counter, "/executions?page=1")
    end
  end
end
