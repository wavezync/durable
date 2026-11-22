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
end
