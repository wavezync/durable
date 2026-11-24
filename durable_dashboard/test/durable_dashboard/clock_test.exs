defmodule DurableDashboard.ClockTest do
  @moduledoc """
  The dashboard shows times Durable wrote by Durable's clock, the database's,
  not by the clock of the node it runs on.
  """

  # Durable's clock is one per node: nothing else may read it meanwhile.
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Core
  alias DurableDashboard.Layouts

  # This node's clock is an hour behind the database's.
  setup do
    was = DateTime.diff(Durable.Clock.utc_now(), DateTime.utc_now(), :microsecond)
    put_ahead(3_600_000_000)
    on_exit(fn -> put_ahead(was) end)
  end

  defp put_ahead(us),
    do:
      Durable.Clock.put_offset(
        System.os_time(:microsecond) + us - System.monotonic_time(:microsecond)
      )

  test "a time Durable wrote just now reads as just now" do
    assigns = %{at: Durable.Clock.utc_now()}
    html = rendered_to_string(~H[<Core.relative_time at={@at} />])

    assert html =~ "just now"
    refute html =~ "in 1h"
  end

  test "the page carries Durable's time, for the times the browser works out" do
    html =
      render_component(&Layouts.root/1,
        config: %{live_socket_path: "/live", base_path: "/dashboard"},
        inner_content: Phoenix.HTML.raw("<main></main>")
      )

    [_, ms] = Regex.run(~r/<meta name="durable-now" content="(\d+)"/, html)
    durable = DateTime.to_unix(Durable.Clock.utc_now(), :millisecond)
    assert_in_delta String.to_integer(ms), durable, 2_000
  end
end
