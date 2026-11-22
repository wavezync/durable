Code.require_file("../audit4_support_test.exs", __DIR__)

defmodule DurableDashboard.Live.Audit4KnownBugsTest do
  @moduledoc """
  Bugs found by the fourth audit, each pinned by a test that fails today.
  All are tagged `:known_bug` (excluded by default): `mix test --only known_bug`.
  Remove the tag with the fix.
  """
  use DurableDashboard.LiveCase

  import Ecto.Query

  alias Durable.Storage.Schemas.{PendingInput, WorkflowExecution}

  @endpoint Audit4Dash.Endpoint
  @moduletag :known_bug

  setup_all do
    start_supervised!(Audit4Dash.Endpoint)
    :ok
  end

  defp repo, do: DurableDashboard.TestRepo
  defp input_of(run_id), do: repo().one!(from(p in PendingInput, where: p.workflow_id == ^run_id))

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

  defp crashes(cases), do: for({label, fun} <- cases, reason = crash(fun), do: {label, reason})

  describe "Inbox: the answer goes to the request that was on screen" do
    # "decide"/"answer" carry no request id: the server answers whatever
    # `socket.assigns.selected` is when the event arrives, and `load/1`
    # re-picks it on every refresh (inputs_live.ex:244 — the `?id=` request, or
    # else the first by deadline). So when the list changes under an operator —
    # a live refresh lands between reading and clicking — Approve lands on a
    # request they never saw. Suspected fix: put the request id in the form
    # (hidden input / phx-value) and refuse when it isn't `selected.id`, or
    # look the request up by that id.
    test "a request that arrives with an earlier deadline doesn't take the approval",
         %{conn: conn} do
      shown = input_of(Fixtures.run!(Fixtures.Approvals))
      {:ok, view, html} = live(conn, dash("/inputs"))
      assert html =~ "answer-#{shown.id}"

      # Another run asks, with a deadline, so it sorts first.
      newcomer = input_of(Fixtures.run!(Fixtures.Approvals))

      repo().update_all(from(p in PendingInput, where: p.id == ^newcomer.id),
        set: [timeout_at: DateTime.add(DateTime.utc_now(), 60, :second)]
      )

      # The refresh the input_requested broadcast schedules; then the click
      # on the form the operator was looking at.
      send(view.pid, :refresh)
      render_submit(view, "decide", %{"decision" => "approve"})

      assert repo().get!(PendingInput, newcomer.id).status == :pending
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
      render_submit(view, "decide", %{"decision" => "approve"})

      assert repo().get!(PendingInput, other.id).status == :pending
      assert repo().get!(PendingInput, other.id).response == nil
    end
  end

  describe "a step's {:error, map} whose message isn't text" do
    # `Trace.error_parts/1` calls `to_string/1` on whatever the step put under
    # `message`/`reason` (trace.ex:324 `message_text/2`) and on `stacktrace`
    # (trace.ex:305). A map or a list of maps raises Protocol.UndefinedError /
    # ArgumentError, in every place an error is summarised: the run's page (all
    # views) and — worse — the Runs list and the workflow's runs, which stay
    # down for everyone while such a run is on the page. Suspected fix: fall
    # back to `inspect/1` (or Jason) for anything that isn't a binary.
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
                       "/executions",
                       "/workflows/audit4_bad_error/runs"
                     ] do
                   {path, fn -> {:ok, _view, _html} = live(conn, dash(path)) end}
                 end
               ) == []
      end
    end
  end

  # A form field's `options:` given as `%{value:, label:}` maps — the shape
  # `wait_for_choice/2` documents for its choices — is interpolated straight
  # into `<option value={opt}>{opt}</option>` (inputs_live.ex:568), which
  # raises Protocol.UndefinedError (Phoenix.HTML.Safe for Map). While that
  # request is pending the whole Inbox is down, all three tabs, for everyone.
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
  end

  # "decide" is the approval form's event, but `handle_event("decide", …)`
  # (inputs_live.ex:90) never checks the selected request is an approval: sent
  # at a form request it completes it with `%{"approved" => true}`, skipping
  # the required-field checks `answer/2` makes. The run resumes with an
  # answer of the wrong shape.
  test "an approval pushed at a form request is refused", %{conn: conn} do
    {:ok, id} =
      Durable.Executor.start_workflow(Audit4Dash.Bugs, %{},
        workflow: "audit4_required_form",
        inline: true
      )

    {:ok, view, _html} = live(conn, dash("/inputs"))
    render_submit(view, "decide", %{"decision" => "approve"})

    assert input_of(id).status == :pending
    assert input_of(id).response == nil
  end

  # QueuesLive (queues_live.ex:54) and TelemetryLive (telemetry_live.ex:189)
  # define `handle_info/2` for their own timer message only, with no catch-all,
  # so any other message is a FunctionClauseError and the page dies. Every
  # other page has `def handle_info(_msg, socket)`. Nothing in the dashboard
  # sends them one today (InboxBadge halts the two input events), but a host
  # `on_mount` hook that subscribes to anything will.
  test "Queues and Telemetry ignore a message they didn't ask for", %{conn: conn} do
    assert crashes(
             for page <- ~w(/queues /telemetry),
                 message <- [:anything, {:durable_event, :workflow_started, %{}}] do
               {{page, message},
                fn ->
                  {:ok, view, _html} = live(conn, dash(page))
                  send(view.pid, message)
                  render(view)
                end}
             end
           ) == []
  end

  # Query params are read as strings without a check: a list or map
  # (`?q[]=a`) reaches String functions and raises FunctionClauseError
  # (executions_live.ex:936 parse_query, keys_live.ex:387); a page number past
  # int8 reaches OFFSET and Postgrex refuses it (executions_live.ex:769,
  # `KeysLive.load/1` rescues the same); a workflow name with a NUL or
  # a non-UTF-8 byte goes into SQL (workflow_detail_live.ex:100). All are 500s
  # where the page's own fallback, or a 400, would do.
  test "malformed query params fall back instead of raising", %{conn: conn} do
    Fixtures.run!(Fixtures.Payments)

    paths =
      ~w(/executions?page=99999999999999999999999999 /executions?q[]=a /executions?q[a]=b
         /executions?page[]=1 /executions?status[]=x /executions?from[]=a
         /executions?parent[]=a /executions?workflow[]=a /keys?q[]=a /keys?status[]=a
         /keys?workflow[]=a /workflows/%00 /workflows/%ff)

    assert crashes(
             for path <- paths do
               {path, fn -> {:ok, _view, _html} = live(conn, dash(path)) end}
             end
           ) == []
  end

  # Events pushed with no run loaded, nothing selected, or a param missing
  # crash the LiveView instead of being ignored: `rollback` and `edit-input`
  # read `socket.assigns.workflow.status`/`.input` on the "Run not found" page
  # (workflow_live.ex:237, :246); `decide`/`send` read `selected.workflow_id` /
  # `sending.workflow_id` when there is none (inputs_live.ex:138, :120);
  # `answer` with `fields` not a map (inputs_live.ex:180); the rest have a
  # single clause matching on the param they expect. Each only ends the
  # sender's own LiveView, which the client remounts.
  test "an event for something that isn't there is ignored", %{conn: conn} do
    Fixtures.schedule!("card_sweep")
    long = String.duplicate("q", 100_000)

    cases = [
      {"/executions/#{Ecto.UUID.generate()}", "rollback", %{}},
      {"/executions/#{Ecto.UUID.generate()}", "edit-input", %{}},
      {"/executions/nope", "no-such-event", %{}},
      {"/inputs?tab=sleep", "decide", %{"decision" => "approve"}},
      {"/inputs?tab=events", "send", %{"payload" => "{}"}},
      {"/inputs?tab=events", "compose", %{}},
      {"/queues", "toggle", %{}},
      {"/queues", "toggle", %{"queue" => long}},
      {"/schedules", "toggle", %{}},
      {"/schedules", "run-now", %{}},
      {"/keys", "toggle-status", %{"status" => "nope"}},
      {"/keys", "page", %{}},
      {"/executions", "bulk", %{"action" => "drop"}},
      {"/executions", "page", %{"page" => %{}}}
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

  test "a form answered with fields that aren't a map is refused, not a crash", %{conn: conn} do
    {:ok, id} =
      Durable.Executor.start_workflow(Audit4Dash.Bugs, %{},
        workflow: "audit4_required_form",
        inline: true
      )

    {:ok, view, _html} = live(conn, dash("/inputs"))

    assert crash(fn -> render_submit(view, "answer", %{"fields" => "not a map"}) end) == nil
    assert input_of(id).status == :pending
  end

  # `dashboard_routes/2` always names its live_session `:durable_dashboard`
  # and its pipelines `:durable_dashboard_browser`/`_assets` (router.ex:91,
  # :99, :111), so a host with two Durable instances can't mount a dashboard
  # for each: the router doesn't compile ("attempting to redefine live_session
  # :durable_dashboard"). Suspected fix: derive the names from the prefix or
  # an `:as` option, and define the pipelines once.
  test "the dashboard can be mounted twice, once per Durable instance" do
    router = "Audit4Dash.TwiceRouter#{System.unique_integer([:positive])}"

    assert [{_module, _bytecode}] =
             Code.compile_string("""
             defmodule #{router} do
               use Phoenix.Router
               import Phoenix.LiveView.Router
               import DurableDashboard.Router

               dashboard_routes "/durable", durable: Durable
               dashboard_routes "/durable-billing", durable: Audit4Dash.Named
             end
             """)
  end

  # `AssetServer` is `Plug.Static` and nothing else (asset_server.ex:21): for
  # a file that isn't there it returns the conn unsent, and it sits behind a
  # `forward`, so no later route answers either. Under Bandit/Cowboy an unsent
  # conn is a Plug.Conn.NotSentError — a 500 in the host's logs for every stale
  # asset URL — where a 404 belongs. (The 500 is those adapters' contract; only
  # the unsent conn is checked here.)
  test "a missing asset is a 404", %{conn: conn} do
    conn = get(conn, dash("/__assets__/no-such-file.js"))

    assert conn.state == :sent
    assert conn.status == 404
  end
end
