defmodule DurableDashboard.Components.CoreTest do
  @moduledoc """
  Smoke coverage for the function components in `DurableDashboard.Components.Core`.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Core

  describe "icon/1" do
    test "renders a known icon as inline SVG" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.icon name="check" />])
      assert html =~ "<svg"
      assert html =~ "viewBox"
    end

    test "renders a placeholder span for an unknown icon" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.icon name="definitely-not-an-icon" />])
      assert html =~ "definitely-not-an-icon"
    end
  end

  describe "button/1" do
    test "primary kind picks up the primary background" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.button kind="primary">Save</Core.button>])
      assert html =~ "Save"
      assert html =~ "bg-primary"
    end

    test "ghost kind has no primary background" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.button kind="ghost">Cancel</Core.button>])
      assert html =~ "Cancel"
      refute html =~ "bg-primary"
    end
  end

  describe "kbd/1" do
    test "wraps content in a <kbd> tag with monospace styling" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.kbd>⌘K</Core.kbd>])
      assert html =~ "<kbd"
      assert html =~ "⌘K"
      assert html =~ "font-mono"
    end
  end

  describe "badge/1" do
    test "primary kind uses the primary tint" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.badge kind="primary">v2</Core.badge>])
      assert html =~ "bg-primary/15"
      assert html =~ "v2"
    end
  end

  describe "status_pill/1" do
    test "running state renders the LED pulse dot" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.status_pill status={:running} />])
      assert html =~ "running"
      assert html =~ "led-dot"
      assert html =~ "bg-success"
    end

    test "completed state renders solid success dot, no animation" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.status_pill status="completed" />])
      assert html =~ "completed"
      assert html =~ "bg-success"
      refute html =~ "led-dot"
    end

    test "failed state uses destructive color" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.status_pill status={:failed} />])
      assert html =~ "failed"
      assert html =~ "text-destructive"
    end

    test "unknown status falls back to muted" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.status_pill status="garbled" />])
      assert html =~ "garbled"
      assert html =~ "text-muted-foreground"
    end
  end

  describe "relative_time/1" do
    test "renders 'just now' for very recent timestamp" do
      now = DateTime.utc_now()
      assigns = %{at: now}
      html = rendered_to_string(~H[<Core.relative_time at={@at} />])
      assert html =~ "just now"
      assert html =~ DateTime.to_iso8601(now)
    end

    test "renders minutes-ago for older timestamps" do
      then_ = DateTime.add(DateTime.utc_now(), -125, :second)
      assigns = %{at: then_}
      html = rendered_to_string(~H[<Core.relative_time at={@at} />])
      assert html =~ "2m ago"
    end

    test "renders em-dash for nil" do
      assigns = %{at: nil}
      html = rendered_to_string(~H[<Core.relative_time at={@at} />])
      assert html =~ "—"
    end
  end

  describe "empty_state/1" do
    test "renders title and description" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Core.empty_state
          title="No workflows yet"
          description="When a workflow starts, it'll appear here."
          icon="queue"
        />
        """)

      assert html =~ "No workflows yet"
      assert html =~ "When a workflow starts"
      assert html =~ "<svg"
    end
  end

  describe "card/1" do
    test "title slot renders a header band" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Core.card>
          <:title>Recent</:title>
          Content goes here
        </Core.card>
        """)

      assert html =~ "Recent"
      assert html =~ "Content goes here"
      assert html =~ "border-b"
    end
  end

  describe "heading/1" do
    test "level=1 renders an <h1> with the subtitle below" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H[<Core.heading level={1} subtitle="Past 24h">Activity</Core.heading>]
        )

      assert html =~ "<h1"
      assert html =~ "Activity"
      assert html =~ "Past 24h"
    end

    test "level=2 renders an <h2>" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.heading level={2}>Section</Core.heading>])
      assert html =~ "<h2"
      assert html =~ "Section"
    end
  end

  describe "code/1" do
    test "wraps in <code> with mono styling" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.code>abc12345</Core.code>])
      assert html =~ "<code"
      assert html =~ "font-mono"
      assert html =~ "abc12345"
    end
  end
end
