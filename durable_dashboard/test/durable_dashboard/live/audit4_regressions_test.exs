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

    # The second instance's database, for the two-dashboards tests.
    start_supervised!(Audit4Dash.BillingRepo)

    Ecto.Migrator.run(
      Audit4Dash.BillingRepo,
      [{Durable.Migration.Migrator.current_version(), DurableDashboard.TestRepo.Migration}],
      :up,
      all: true,
      log: false
    )

    Ecto.Adapters.SQL.Sandbox.mode(Audit4Dash.BillingRepo, :manual)
    :ok
  end

  defp repo, do: DurableDashboard.TestRepo
  defp input_of(run_id), do: repo().one!(from(p in PendingInput, where: p.workflow_id == ^run_id))
  defp status(run_id), do: repo().get!(WorkflowExecution, run_id).status

  # What went wrong running `fun` against a page, or nil. A LiveView that
  # crashes takes the (linked) test with it unless exits are trapped.
  defp crashes(cases), do: for({label, fun} <- cases, reason = crash(fun), do: {label, reason})

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
      assert Durable.paused_queues!(named) == ["default"]

      {:ok, _} = Durable.schedule(Fixtures.Payments, "*/5 * * * *", [name: "sweep"] ++ named)
      assert click.(open.("/schedules"), "toggle", %{"name" => "sweep"}) == nil
      assert [%{enabled: false}] = Durable.list_schedules!(named)

      runs_before = repo().aggregate(WorkflowExecution, :count)
      assert click.(open.("/schedules"), "run-now", %{"name" => "sweep"}) == nil
      assert repo().aggregate(WorkflowExecution, :count) == runs_before + 1

      view = open.("/settings")
      assert click.(view, "prune", %{}) == nil
      refute render(view) =~ "Pruning needs admin access."
    end
  end

  describe "Inbox: the answer goes to the request that was on screen" do
    # "decide"/"answer" carried no request id: the server answered whatever
    # was selected when the event arrived, and the page re-picks that on every
    # refresh (the `?id=` request, or else the first by deadline). So a live
    # refresh between reading and clicking put Approve on a request the
    # operator never saw. The form now names its request.
    test "a request that arrives with an earlier deadline doesn't take the approval",
         %{conn: conn} do
      shown = input_of(Fixtures.run!(Fixtures.Approvals))
      {:ok, view, html} = live(conn, dash("/inputs"))
      assert html =~ "answer-#{shown.id}"

      assert has_element?(
               view,
               ~s(#answer-#{shown.id} input[name="request"][value="#{shown.id}"])
             )

      # Another run asks, with a deadline, so it sorts first.
      newcomer = input_of(Fixtures.run!(Fixtures.Approvals))

      repo().update_all(from(p in PendingInput, where: p.id == ^newcomer.id),
        set: [timeout_at: DateTime.add(DateTime.utc_now(), 60, :second)]
      )

      # The refresh the input_requested broadcast schedules; then the click
      # on the form the operator was looking at.
      send(view.pid, :refresh)
      render_submit(view, "decide", %{"decision" => "approve", "request" => shown.id})

      assert repo().get!(PendingInput, newcomer.id).status == :pending
      assert repo().get!(PendingInput, shown.id).response["approved"] == true
    end

    test "when the open request is answered elsewhere, Approve doesn't fall through to the next",
         %{conn: conn} do
      other_run = Fixtures.run!(Fixtures.Approvals)
      open_run = Fixtures.run!(Fixtures.Approvals)
      [other, open] = Enum.map([other_run, open_run], &input_of/1)

      {:ok, view, _html} = live(conn, dash("/inputs?id=#{open.id}"))
      assert has_element?(view, "#answer-#{open.id}")

      # A colleague rejects it; this page refreshes; the operator's click lands.
      :ok = Durable.provide_input(open_run, "manager_approval", %{"approved" => false})
      send(view.pid, :refresh)
      html = render_submit(view, "decide", %{"decision" => "approve", "request" => open.id})

      assert html =~ "That request changed while you were looking at it. Review it again."
      assert repo().get!(PendingInput, other.id).status == :pending
      assert repo().get!(PendingInput, other.id).response == nil
      assert repo().get!(PendingInput, open.id).response["approved"] == false
    end

    test "an answer that names no request, or one that isn't a request, answers nothing",
         %{conn: conn} do
      shown = input_of(Fixtures.run!(Fixtures.Approvals))
      {:ok, view, _html} = live(conn, dash("/inputs"))

      for request <- [nil, "", "nope", %{"a" => "b"}, Ecto.UUID.generate()] do
        html = render_submit(view, "decide", %{"decision" => "approve", "request" => request})
        assert html =~ "That request changed"
      end

      assert repo().get!(PendingInput, shown.id).status == :pending
    end
  end

  describe "a step's {:error, map} whose message isn't text" do
    # `Trace.error_parts/1` called `to_string/1` on whatever the step put under
    # `message`/`reason` and on `stacktrace`. A map or a list of maps raised,
    # in every place an error is summarised: the run's page (all views), the
    # Runs list and the workflow's runs, which stayed down for everyone while
    # such a run was on the page. `Format.text/1` shows it inspected instead.
    for mode <- ~w(message_map reason_map message_list stacktrace_list) do
      test "#{mode}: its page, the Runs list and the workflow's runs still render",
           %{conn: conn} do
        {:ok, id} =
          Durable.Executor.start_workflow(
            Audit4Dash.Bugs,
            %{"mode" => unquote(mode)},
            workflow: "audit4_bad_error",
            inline: true
          )

        assert Fixtures.get_run!(id).status == :failed

        assert crashes(
                 for path <- [
                       "/executions/#{id}",
                       "/executions/#{id}/graph",
                       "/executions/#{id}?pane=attempts",
                       "/executions",
                       "/workflows/audit4_bad_error/runs"
                     ] do
                   {path, fn -> {:ok, _view, _html} = live(conn, dash(path)) end}
                 end
               ) == []
      end
    end
  end

  test "a huge term where a message was expected is cut short" do
    huge = %{"message" => Enum.map(1..10_000, &%{"field" => String.duplicate("x", &1)})}
    assert String.length(DurableDashboard.Trace.error_parts(huge).message) < 20_000
  end

  test "a cancel reason that isn't text still shows the cancelled run", %{conn: conn} do
    id = Fixtures.run!(Fixtures.Approvals)
    :ok = Durable.cancel(id, "x")

    repo().update_all(from(w in WorkflowExecution, where: w.id == ^id),
      set: [error: %{"message" => %{"code" => 7}}]
    )

    assert crashes([{id, fn -> {:ok, _view, _html} = live(conn, dash("/executions/#{id}")) end}]) ==
             []
  end

  # A form field's `options:` given as `%{value:, label:}` maps (the shape
  # `wait_for_choice/2` documents for its choices) was put straight into
  # `<option value={opt}>{opt}</option>`, which raises for a map: while that
  # request was pending the whole Inbox was down, all three tabs, for everyone.
  test "a select field whose options are value/label maps doesn't take the Inbox down",
       %{conn: conn} do
    {:ok, _id} =
      Durable.Executor.start_workflow(Audit4Dash.Bugs, %{},
        workflow: "audit4_select_form",
        inline: true
      )

    assert crashes(
             for path <- ~w(/inputs /inputs?tab=events /inputs?tab=sleep) do
               {path, fn -> {:ok, _view, _html} = live(conn, dash(path)) end}
             end
           ) == []

    {:ok, view, _html} = live(conn, dash("/inputs"))
    assert has_element?(view, ~s(select option[value="mbp"]), "MacBook Pro")
    assert has_element?(view, ~s(select option[value="x1"]), "ThinkPad")
  end

  test "choices and options given as bare values, or as something odd, still render",
       %{conn: conn} do
    run = Fixtures.run!(Fixtures.Approvals)

    for {type, fields} <- [
          {:single_choice, [%{"value" => %{"a" => 1}}, %{"label" => 3}, %{}]},
          {:form,
           [%{"name" => "size", "type" => "select", "options" => ["s", 2, %{"label" => "L"}]}]}
        ] do
      repo().update_all(from(p in PendingInput, where: p.workflow_id == ^run),
        set: [input_type: type, fields: fields]
      )

      assert crash(fn -> {:ok, _view, _html} = live(conn, dash("/inputs")) end) == nil
    end
  end

  # "decide" is the approval form's event, but it never checked the request
  # was an approval: sent at a form request it completed it with
  # `%{"approved" => true}`, skipping the required-field checks `answer/2`
  # makes, and the run resumed with an answer of the wrong shape.
  test "an approval pushed at a form request is refused", %{conn: conn} do
    {:ok, id} =
      Durable.Executor.start_workflow(Audit4Dash.Bugs, %{},
        workflow: "audit4_required_form",
        inline: true
      )

    {:ok, view, _html} = live(conn, dash("/inputs"))

    html =
      render_submit(view, "decide", %{"decision" => "approve", "request" => input_of(id).id})

    assert html =~ "Only an approval can be approved or rejected."
    assert input_of(id).status == :pending
    assert input_of(id).response == nil
    assert Fixtures.get_run!(id).status == :waiting
  end

  # QueuesLive and TelemetryLive handled their own timer message only, with
  # no catch-all, so any other message was a FunctionClauseError and the page
  # died. Nothing in the dashboard sends them one, but a host `on_mount` hook
  # that subscribes to anything will.
  test "every page ignores a message it didn't ask for", %{conn: conn} do
    run = Fixtures.run!(Fixtures.Payments)

    pages =
      ~w(/ /executions /executions/#{run} /workflows /workflows/process_payment /inputs /keys
         /queues /schedules /telemetry /settings)

    assert crashes(
             for page <- pages,
                 message <- [:anything, {:durable_event, :workflow_started, %{}}, {:refresh}] do
               {{page, message},
                fn ->
                  {:ok, view, _html} = live(conn, dash(page))
                  send(view.pid, message)
                  render(view)
                end}
             end
           ) == []
  end

  # `AssetServer` was `Plug.Static` and nothing else: for a file that isn't
  # there it returned the conn unsent, and it sits behind a `forward`, so no
  # later route answered either. Under Bandit/Cowboy an unsent conn is a
  # Plug.Conn.NotSentError, a 500 in the host's logs for every stale asset URL.
  test "a missing asset is a 404", %{conn: conn} do
    conn = get(conn, dash("/__assets__/no-such-file.js"))

    assert conn.state == :sent
    assert conn.status == 404
    assert get(conn, dash("/__assets__/app.js")).status == 200
  end

  # Query params were read as strings without a check: a list or a map
  # (`?q[]=a`) reached String functions and raised; a page number past int8
  # reached OFFSET and Postgres refused it; a workflow name with a NUL or a
  # byte that isn't UTF-8 went into SQL. All were 500s. Every page now reads
  # its params through `DurableDashboard.Params`.
  test "malformed query params fall back instead of raising", %{conn: conn} do
    run = Fixtures.run!(Fixtures.Payments)
    Fixtures.schedule!("card_sweep")

    paths =
      ~w(/executions?page=99999999999999999999999999 /executions?q[]=a /executions?q[a]=b
         /executions?page[]=1 /executions?status[]=x /executions?from[]=a /executions?to[]=a
         /executions?range[]=a /executions?parent[]=a /executions?workflow[]=a
         /keys?q[]=a /keys?status[]=a /keys?workflow[]=a /keys?page[]=1
         /keys?page=99999999999999999999999999 /workflows/%00 /workflows/%ff
         /workflows/%00/runs /workflows/%ff/runs /workflows/process_payment?range[]=a
         /workflows?range[]=a /?range[]=a /inputs?tab[]=a /inputs?id[]=a /schedules/%ff
         /executions/#{run}?step[]=a /executions/#{run}?pane[]=a&step[a]=b /executions/%ff)

    assert crashes(
             for path <- paths do
               {path, fn -> {:ok, _view, _html} = live(conn, dash(path)) end}
             end
           ) == []
  end

  test "a name that can't be stored is a workflow nobody has, not every run", %{conn: conn} do
    Fixtures.run!(Fixtures.Payments)

    {:ok, _view, html} = live(conn, dash("/workflows/%00/runs"))
    assert html =~ "0 matching"

    {:ok, _view, html} = live(conn, dash("/executions?page=99999999999999999999999999"))
    assert html =~ "1 matching"
  end

  test "Params reads text, pages and lists from whatever was sent" do
    alias DurableDashboard.Params

    assert Params.text("a b") == "a b"
    assert Enum.map([nil, "", ["a"], %{"a" => "b"}, 1], &Params.text/1) == List.duplicate(nil, 5)
    assert Params.text("a\0b") == "\uFFFD"
    assert Params.text(<<255>>) == "\uFFFD"

    assert Enum.map(["3", "3abc", 7, "-1", "0", "abc", nil, ["1"], %{}], &Params.page/1) ==
             [3, 3, 7, 1, 1, 1, 1, 1, 1]

    assert Params.page("99999999999999999999999999") == 1_000_000
    assert Params.list("failed,,cancelled") == ["failed", "cancelled"]
    assert Enum.map([nil, ["a"], %{}], &Params.list/1) == [[], [], []]
  end

  describe "events for something that isn't there" do
    # Events pushed with no run loaded, nothing selected, a param missing or
    # of the wrong shape, or a name no page has, crashed the sender's LiveView
    # (a FunctionClauseError, or a read of `nil`). Handlers now check the state
    # they need and every LiveView and live component ignores the rest.
    test "are ignored by every page", %{conn: conn} do
      Fixtures.schedule!("card_sweep")
      run = Fixtures.run!(Fixtures.Payments, %{"decline" => true})
      missing = "/executions/#{Ecto.UUID.generate()}"
      long = String.duplicate("q", 100_000)

      cases =
        for(
          event <- ~w(cancel retry rerun release-key rollback edit-input confirm-rollback),
          do: {missing, event, %{}}
        ) ++
          for(
            page <-
              ~w(/ /executions /executions/#{run} /executions/nope /workflows
                 /workflows/process_payment /inputs /keys /queues /schedules /telemetry /settings),
            do: {page, "no-such-event", %{"a" => "b"}}
          ) ++
          [
            {"/executions/#{run}", "rerun", %{"input" => %{"a" => "b"}}},
            {"/inputs?tab=sleep", "decide", %{"decision" => "approve"}},
            {"/inputs?tab=events", "send", %{"payload" => "{}"}},
            {"/inputs?tab=events", "send", %{"payload" => %{}}},
            {"/inputs?tab=events", "compose", %{}},
            {"/inputs?tab=events", "compose", %{"id" => %{}}},
            {"/queues", "toggle", %{}},
            {"/queues", "toggle", %{"queue" => long}},
            {"/queues", "toggle", %{"queue" => %{}}},
            {"/schedules", "toggle", %{}},
            {"/schedules", "toggle", %{"name" => %{}}},
            {"/schedules", "run-now", %{}},
            {"/schedules", "run-now", %{"name" => ["a"]}},
            {"/keys", "toggle-status", %{"status" => "nope"}},
            {"/keys", "page", %{}},
            {"/keys", "page", %{"page" => %{}}},
            {"/keys", "filter", %{"q" => %{}, "workflow" => ["a"]}},
            {"/executions", "bulk", %{"action" => "drop"}},
            {"/executions", "bulk", %{}},
            {"/executions", "page", %{"page" => %{}}},
            {"/executions", "page", %{}},
            {"/executions", "view", %{"view" => %{}}},
            {"/executions", "toggle", %{"id" => %{}}},
            {"/executions", "filter-tag", %{"tag" => %{}}}
          ]

      assert crashes(
               for {path, event, params} <- cases do
                 {{path, event, params |> inspect() |> String.slice(0, 40)},
                  fn ->
                    {:ok, view, _html} = live(conn, dash(path))
                    render_click(view, event, params)
                  end}
               end
             ) == []
    end

    test "are ignored by the query bar, the palette and the run page's tabs", %{conn: conn} do
      {:ok, keyed} = Durable.start(Fixtures.Invoices, %{}, key: "invoice:1", inline: true)

      cases = [
        {"/executions?q=a+b", "#executions-filters",
         [
           {"toggle_facet", %{"facet" => "nope"}},
           {"toggle_facet", %{}},
           {"filter_workflows", %{"value" => %{}}},
           {"select_workflow", %{"name" => ["a"]}},
           {"toggle_status", %{"status" => %{}}},
           {"set_range", %{"range" => %{}}},
           {"set_custom", %{"from" => %{}, "to" => "x"}},
           {"commit", %{"draft" => %{}}},
           {"remove_tag", %{"tag" => "nope"}},
           {"remove_tag", %{"tag" => "q:abc"}},
           {"remove_tag", %{"tag" => %{}}},
           {"no-such-event", %{}}
         ]},
        {"/executions", "#command-palette",
         [
           {"palette:search", %{"value" => %{}}},
           {"palette:search", %{}},
           {"palette:select", %{"index" => "abc"}},
           {"palette:select", %{"index" => %{}}},
           {"palette:move", %{}},
           {"no-such-event", %{}}
         ]},
        {"/executions/#{keyed}/logs", "#logs-#{keyed}",
         [
           {"filter:step", %{"step" => %{}}},
           {"filter:level", %{}},
           {"filter:search", %{"value" => ["a"]}},
           {"page:set", %{"page" => %{}}},
           {"page:set", %{}},
           {"no-such-event", %{}}
         ]},
        {"/executions/#{keyed}/key", "#key-#{keyed}", [{"toggle", %{}}, {"no-such-event", %{}}]},
        {"/executions/#{keyed}/graph", "#flow-#{keyed}",
         [{"step-clicked", %{}}, {"no-such-event", %{}}]}
      ]

      assert crashes(
               for {path, target, events} <- cases, {event, params} <- events do
                 {{path, event, inspect(params)},
                  fn ->
                    {:ok, view, _html} = live(conn, dash(path))
                    view |> with_target(target) |> render_click(event, params)
                    render(view)
                  end}
               end
             ) == []
    end

    # Pausing writes a row for whatever name it is given: the page only does
    # it for a queue it lists.
    test "Queues pauses a queue it lists, and no other", %{conn: conn} do
      {:ok, view, _html} = live(conn, dash("/queues"))

      for queue <- ["ghost", String.duplicate("q", 100_000), "", %{"a" => "b"}] do
        render_click(view, "toggle", %{"queue" => queue})
      end

      assert Durable.paused_queues!() == []
      assert repo().aggregate(Durable.Storage.Schemas.Queue, :count) == 0

      render_click(view, "toggle", %{"queue" => "default"})
      assert Durable.paused_queues!() == ["default"]
    end

    test "a form answered with fields that aren't a map is refused, not a crash", %{conn: conn} do
      {:ok, id} =
        Durable.Executor.start_workflow(Audit4Dash.Bugs, %{},
          workflow: "audit4_required_form",
          inline: true
        )

      request = input_of(id).id
      {:ok, view, _html} = live(conn, dash("/inputs"))

      for fields <- ["not a map", ["a"], %{"amount" => %{"x" => "1"}}, %{"amount" => ["1"]}] do
        params = %{"fields" => fields, "request" => request}
        assert crash(fn -> render_submit(view, "answer", params) end) == nil
        assert has_element?(view, "[role=alert]")
      end

      assert input_of(id).status == :pending
    end

    test "an answer of the wrong shape for its request is refused", %{conn: conn} do
      run = Fixtures.run!(Fixtures.HoldAwaitingCustomer)
      request = input_of(run).id

      for {type, params} <- [
            {:free_text, %{"text" => %{"a" => "b"}}},
            {:free_text, %{}},
            {:single_choice, %{"choice" => %{"a" => "b"}}},
            {:multi_choice, %{"choices" => "a"}},
            {:multi_choice, %{"choices" => [%{"a" => "b"}]}},
            {:approval, %{"comment" => %{"a" => "b"}}}
          ] do
        repo().update_all(from(p in PendingInput, where: p.id == ^request),
          set: [input_type: type]
        )

        {:ok, view, _html} = live(conn, dash("/inputs"))
        params = Map.put(params, "request", request)
        assert crash(fn -> render_submit(view, "answer", params) end) == nil
        assert input_of(run).status == :pending, inspect({type, params})
      end
    end
  end

  describe "two dashboards in one router, one per Durable instance" do
    # `dashboard_routes/2` always named its live_session `:durable_dashboard`
    # and defined its pipelines on every call, so a host with two Durable
    # instances couldn't mount a dashboard for each: the router didn't compile.
    # `:as` names a mount's live_session, and the pipelines are defined once.
    setup %{conn: conn} do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Audit4Dash.BillingRepo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

      start_supervised!(
        Supervisor.child_spec(
          {Durable,
           name: Audit4Dash.Billing,
           repo: Audit4Dash.BillingRepo,
           queues: %{invoicing: [concurrency: 2]},
           queue_enabled: false,
           pubsub: DurableDashboard.TestPubSub},
          id: Audit4Dash.Billing
        )
      )

      {:ok, billed} =
        Durable.Executor.start_workflow(Fixtures.Approvals, %{},
          inline: true,
          durable: Audit4Dash.Billing
        )

      {:ok,
       conn: Plug.Conn.put_private(conn, :audit4_router, Audit4Dash.TwoRouter),
       paid: Fixtures.run!(Fixtures.Payments),
       billed: billed}
    end

    @main "/admin/durable"
    @billing "/admin/durable-billing"

    defp hrefs(html, selector, attribute) do
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute(attribute)
    end

    defp under?(link, base),
      do: link == base or String.starts_with?(link, [base <> "/", base <> "?"])

    test "each mount shows its own instance's runs", %{conn: conn, paid: paid, billed: billed} do
      {:ok, _view, html} = live(conn, @main <> "/executions")
      assert html =~ "process_payment"
      refute html =~ "expense_approval"

      {:ok, _view, html} = live(conn, @billing <> "/executions")
      assert html =~ "expense_approval"
      refute html =~ "process_payment"

      {:ok, _view, html} = live(conn, "#{@billing}/executions/#{billed}")
      assert html =~ "expense_approval"
      {:ok, _view, html} = live(conn, "#{@billing}/executions/#{paid}")
      assert html =~ "Run not found"
      {:ok, _view, html} = live(conn, "#{@main}/executions/#{billed}")
      assert html =~ "Run not found"

      # Each instance's own queues, and its own Inbox count.
      {:ok, _view, html} = live(conn, @billing <> "/queues")
      assert html =~ "invoicing"
      {:ok, _view, html} = live(conn, @main <> "/queues")
      refute html =~ "invoicing"

      {:ok, view, _html} = live(conn, @billing <> "/inputs")
      assert has_element?(view, ~s([aria-label="1 waiting"]))
      {:ok, view, _html} = live(conn, @main <> "/inputs")
      refute has_element?(view, ~s([aria-label="1 waiting"]))
    end

    test "no link, asset or redirect on one mount points into the other",
         %{conn: conn, paid: paid, billed: billed} do
      for {base, other, run} <- [{@billing, @main, billed}, {@main, @billing, paid}],
          page <-
            ~w(/ /executions /executions/#{run} /executions/#{run}/graph /executions/#{run}/logs
               /executions/#{run}/context /workflows /inputs /inputs?tab=events /keys /queues
               /schedules /telemetry /settings) do
        path = String.trim_trailing(base <> page, "/")
        {:ok, view, html} = live(conn, path)

        links =
          Enum.filter(
            hrefs(html, "a[href]", "href") ++ hrefs(render(view), "a[href]", "href"),
            &String.starts_with?(&1, "/")
          )

        assert links != []
        assert Enum.all?(links, &under?(&1, base)), "#{path}: #{inspect(links)}"
        refute Enum.any?(links, &under?(&1, other)), "#{path}: #{inspect(links)}"

        # The stylesheet and script come from this mount's own asset route.
        document = conn |> get(path) |> html_response(200)

        assets =
          Enum.filter(
            hrefs(document, "link[rel=stylesheet]", "href") ++
              hrefs(document, "script[src]", "src"),
            &String.starts_with?(&1, "/")
          )

        assert length(assets) == 2

        assert Enum.all?(assets, &String.starts_with?(&1, base <> "/__assets__/")),
               inspect(assets)

        for asset <- assets, do: assert(get(conn, asset).status == 200)
      end
    end

    test "navigation, the palette and actions stay on their mount", %{conn: conn, billed: billed} do
      # A sidebar link is a live navigation inside the mount's own live_session.
      {:ok, view, _html} = live(conn, @billing)

      {:ok, view, html} =
        view
        |> element(~s(a[href="#{@billing}/executions"]))
        |> render_click()
        |> follow_redirect(conn, @billing <> "/executions")

      assert html =~ "expense_approval"

      view |> with_target("#command-palette") |> render_hook("palette:open", %{})
      view |> element("#command-palette form") |> render_change(%{value: "Inbox"})
      view |> with_target("#command-palette") |> render_hook("palette:activate", %{})
      assert_redirect(view, @billing <> "/inputs")

      # The palette searches this mount's instance.
      {:ok, view, _html} = live(conn, @billing)
      view |> with_target("#command-palette") |> render_hook("palette:open", %{})
      palette = view |> element("#command-palette") |> render()
      assert palette =~ "expense_approval"
      refute palette =~ "process_payment"

      # Cancel, then Rerun: both on the billing instance, and the new run
      # opens under the billing mount.
      {:ok, view, _html} = live(conn, "#{@billing}/executions/#{billed}")
      render_click(view, "cancel", %{})
      assert Audit4Dash.BillingRepo.get!(WorkflowExecution, billed).status == :cancelled

      render_click(view, "rerun", %{})
      {path, _flash} = assert_redirect(view)
      assert String.starts_with?(path, @billing <> "/executions/")
      rerun = path |> String.split("/") |> List.last()
      assert Audit4Dash.BillingRepo.get(WorkflowExecution, rerun)
      refute repo().get(WorkflowExecution, rerun)
    end

    # Compiles a router with these routes and returns its module.
    defp compile_router(routes) do
      name = "Audit4Dash.CompiledRouter#{System.unique_integer([:positive])}"

      """
      defmodule #{name} do
        use Phoenix.Router
        import Phoenix.LiveView.Router
        import DurableDashboard.Router

        #{routes}
      end
      """
      |> Code.compile_string()
      |> Enum.find_value(fn {module, _bytecode} -> inspect(module) == name and module end)
    end

    test "a second mount needs its own :as, and says so" do
      router =
        compile_router("""
        dashboard_routes "/durable", durable: Durable
        dashboard_routes "/durable-billing", durable: Audit4Dash.Billing, as: :billing_dashboard
        use DurableDashboard.Router, mount: "/third", as: :third_dashboard
        """)

      paths = Enum.map(router.__routes__(), & &1.path)

      for base <- ~w(/durable /durable-billing /third),
          do: assert((base <> "/executions") in paths)

      for routes <- [
            """
            dashboard_routes "/durable", durable: Durable
            dashboard_routes "/durable-billing", durable: Audit4Dash.Billing
            """,
            """
            dashboard_routes "/a", as: :ops
            scope "/admin" do
              dashboard_routes "/b", as: :ops
            end
            """
          ] do
        error = assert_raise ArgumentError, fn -> compile_router(routes) end
        assert error.message =~ "already mounted"
        assert error.message =~ "as: :other_dashboard"
      end

      assert_raise ArgumentError, ~r/:as must be an atom/, fn ->
        compile_router(~s(dashboard_routes "/durable", as: "ops"))
      end
    end

    test "a single mount keeps the live_session name it always had; :as renames it" do
      session = fn router, path ->
        route = Enum.find(router.__routes__(), &(&1.path == path))
        route.metadata.phoenix_live_view |> elem(3) |> Map.fetch!(:name)
      end

      router = compile_router(~s(dashboard_routes "/durable"))
      assert session.(router, "/durable/executions") == :durable_dashboard

      assert session.(Audit4Dash.TwoRouter, "/admin/durable/executions") == :durable_dashboard

      assert session.(Audit4Dash.TwoRouter, "/admin/durable-billing/executions") ==
               :billing_dashboard
    end
  end

  describe "a run's family" do
    defp adopt(child, parent) do
      repo().update_all(from(w in WorkflowExecution, where: w.id == ^child),
        set: [parent_workflow_id: parent]
      )
    end

    # `walk_to_root` followed `parent_workflow_id` with no bound: two runs
    # that name each other as parent (no workflow can write that; a bad
    # import or a hand-edited row can) hung the page for ever.
    # (Before the bound this test ran until its timeout.)
    @tag timeout: 20_000
    test "runs that are each other's parent don't hang the run page", %{conn: conn} do
      [a, b, c] = for _ <- 1..3, do: Fixtures.run!(Fixtures.Payments)
      adopt(a, b)
      adopt(b, c)
      adopt(c, a)

      pages = for run <- [a, b, c], view <- ["", "/graph", "/family"], do: "#{run}#{view}"

      assert crashes(
               for page <- pages do
                 {page, fn -> {:ok, _view, _html} = live(conn, dash("/executions/#{page}")) end}
               end
             ) == []

      # A run that is its own parent.
      adopt(a, a)
      assert crash(fn -> {:ok, _view, _html} = live(conn, dash("/executions/#{a}")) end) == nil
    end

    # Only the root's direct children were loaded as "descendants", so from
    # the third level down a run's own steps weren't loaded for its own page,
    # and the family view missed everything below the root's children.
    test "a three-level family shows every level, from any member's page", %{conn: conn} do
      root = Fixtures.run!(Fixtures.Orders)
      child = Fixtures.run!(Fixtures.Payments)
      grandchild = Fixtures.run!(Fixtures.Holds)
      adopt(child, root)
      adopt(grandchild, child)
      short = &String.slice(&1, 0, 8)

      # The grandchild's own page has its own steps.
      {:ok, _view, html} = live(conn, dash("/executions/#{grandchild}"))
      assert html =~ "hold_order"
      assert html =~ "reserve"
      assert html =~ "charge"

      # The family view lists every run below the root, and a run's parent.
      # (From the third level down the root itself isn't on it: the view has
      # a card for the parent only.)
      for {run, others} <- [
            {root, [child, grandchild]},
            {child, [root, grandchild]},
            {grandchild, [child]}
          ] do
        {:ok, _view, html} = live(conn, dash("/executions/#{run}/family"))
        for other <- others, do: assert(html =~ short.(other), "#{short.(run)} misses a relative")
      end

      # Each run's graph has its own steps' outcomes. The grandchild's failed
      # `charge` is on its own graph and not on the root's step of that name.
      status = fn run, step ->
        {:ok, view, _html} = live(conn, dash("/executions/#{run}/graph"))

        view
        |> element("[phx-hook=FlowGraph]")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("data-graph")
        |> hd()
        |> Jason.decode!()
        |> Map.fetch!("nodes")
        |> Enum.find(&(&1["data"]["label"] == step))
        |> get_in(["data", "status"])
      end

      assert status.(grandchild, "reserve") == "completed"
      assert status.(grandchild, "charge") == "failed"
      assert status.(root, "charge") == "completed"
      assert status.(child, "authorize") == "completed"
    end
  end

  # `error["replaced_by"]` went to the run link as it was; anything but a
  # string there (a hand-written row, an older shape) raised in `short/1`.
  test "a cancelled run whose replaced_by isn't a run id still renders", %{conn: conn} do
    run = Fixtures.run!(Fixtures.Approvals)
    :ok = Durable.cancel(run)

    for replaced_by <- [5, %{"id" => "x"}, ["a"], nil, true] do
      repo().update_all(from(w in WorkflowExecution, where: w.id == ^run),
        set: [error: %{"replaced_by" => replaced_by, "message" => "replaced"}]
      )

      assert crashes(
               for view <- ["", "/key", "/graph"] do
                 {{replaced_by, view},
                  fn -> {:ok, _view, _html} = live(conn, dash("/executions/#{run}#{view}")) end}
               end
             ) == []
    end

    {:ok, _view, html} = live(conn, dash("/executions/#{run}"))
    assert html =~ "Cancelled"
  end

  # The Overview's live feed read `payload[:id]` from any workflow event; a
  # payload that isn't a map raised.
  test "the Overview survives a workflow event whose payload isn't a map", %{conn: conn} do
    Fixtures.run!(Fixtures.Payments)

    assert crashes(
             for payload <- [
                   "text",
                   :atom,
                   nil,
                   7,
                   [1, 2],
                   {:a, :b},
                   [id: 5],
                   %{id: %{}},
                   %{},
                   %{id: "x", workflow_name: %{"a" => 1}, current_step: %{"b" => 2}}
                 ] do
               {payload,
                fn ->
                  {:ok, view, _html} = live(conn, dash("/"))
                  send(view.pid, {:durable_event, :workflow_failed, payload})
                  render(view)
                end}
             end
           ) == []

    # A real event still makes its line.
    {:ok, view, _html} = live(conn, dash("/"))

    event = %{
      id: Ecto.UUID.generate(),
      workflow_name: "process_payment",
      current_step: "authorize"
    }

    send(view.pid, {:durable_event, :workflow_failed, event})
    assert render(view) =~ "failed at authorize"
  end
end
