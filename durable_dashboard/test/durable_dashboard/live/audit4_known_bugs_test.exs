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
