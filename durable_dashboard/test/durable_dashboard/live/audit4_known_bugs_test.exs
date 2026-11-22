Code.require_file("../audit4_support_test.exs", __DIR__)

defmodule DurableDashboard.Live.Audit4KnownBugsTest do
  @moduledoc """
  Bugs found by the fourth audit, each pinned by a test that fails today.
  All are tagged `:known_bug` (excluded by default): `mix test --only known_bug`.
  Remove the tag with the fix.
  """
  use DurableDashboard.LiveCase

  import Ecto.Query

  alias Durable.Storage.Schemas.PendingInput

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
end
