defmodule DurableDashboard.InboxBadgeTest do
  use ExUnit.Case, async: true

  alias DurableDashboard.InboxBadge

  defp socket(assigns),
    do: %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}

  test "input events are consumed, so pages without a handler for them don't crash" do
    event = {:durable_event, :input_requested, %{}}

    assert {:halt, %{assigns: %{inbox_count: 0}}} = InboxBadge.recount(event, socket(%{}), nil)

    assert {:cont, _} =
             InboxBadge.recount(event, socket(%{wants_input_events: true}), nil)
  end

  test "other messages pass through untouched" do
    assert {:cont, _} = InboxBadge.recount(:refresh, socket(%{}), nil)
  end
end
