defmodule DurableDashboard.Components.CoreTest do
  @moduledoc """
  Smoke coverage for the function components in `DurableDashboard.Components.Core`.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Durable.Storage.Schemas.WorkflowExecution
  alias DurableDashboard.Components.Core

  describe "run_status/1 for a parked run" do
    @now ~U[2026-11-09 10:00:00Z]

    defp parked(status, seconds, reason) do
      %{
        status: :pending,
        current_step: "charge_card",
        error: nil,
        parked: %{
          status: status,
          step: "charge_card",
          at: DateTime.add(@now, seconds, :second),
          exec_id: "e1",
          attempt: 2,
          max: 5,
          reason: reason
        }
      }
    end

    defp status_html(run, now) do
      assigns = %{run: run, now: now}
      rendered_to_string(~H[<Core.run_status run={@run} now={@now} />])
    end

    test "a retry counts down, and says how many attempts it has used" do
      html = parked(:retrying, 12, "gateway timeout") |> status_html(@now)

      assert html =~ "st-retrying"
      assert html =~ "Retrying"
      assert html =~ "in 12s · 2 of 5"
      assert html =~ "gateway timeout"
    end

    test "the countdown follows the page's clock" do
      html = parked(:retrying, 12, "x") |> status_html(DateTime.add(@now, 5, :second))
      assert html =~ "in 7s · 2 of 5"
    end

    test "past its time it says it's due" do
      html = parked(:retrying, 12, "x") |> status_html(DateTime.add(@now, 60, :second))
      assert html =~ "due now · 2 of 5"

      html = parked(:snoozed, 12, nil) |> status_html(DateTime.add(@now, 60, :second))
      assert html =~ "· due now"
    end

    test "a snooze is grey and says how long" do
      html = parked(:snoozed, 48, "busy") |> status_html(@now)

      assert html =~ "st-snoozed"
      assert html =~ "Snoozed"
      assert html =~ "for 48s"
      assert html =~ "busy"
      refute html =~ "text-warning"
    end

    test "a pending run part-way through says what's next" do
      run = %{status: :pending, current_step: "run_ocr", error: nil}
      assert status_html(run, @now) =~ ~r/next <span[^>]*>run_ocr/
    end

    test "a run that hasn't started says nothing more" do
      html = %{status: :pending, current_step: nil, error: nil} |> status_html(@now)
      assert html =~ "Pending"
      refute html =~ "next"
    end

    test "takes a run struct, which has no parked key" do
      html = %WorkflowExecution{status: :running, current_step: "a"} |> status_html(@now)
      assert html =~ "Running"
    end
  end

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
    test "primary kind is ink-inverted, keeping blue for live state" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.button kind="primary">Save</Core.button>])
      assert html =~ "Save"
      assert html =~ "bg-foreground text-background"
      refute html =~ "bg-primary"
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
    test "running state renders the pulsing live mark in the primary tone" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.status_pill status={:running} />])
      assert html =~ "Running"
      assert html =~ "st-dot st-running"
      assert html =~ "text-primary"
    end

    test "failed state is a diamond mark, not just a color" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.status_pill status={:failed} />])
      assert html =~ "Failed"
      assert html =~ "st-failed"
      assert html =~ "text-destructive"
    end

    test "completed state renders solid success dot, no animation" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.status_pill status="completed" />])
      assert html =~ "Completed"
      assert html =~ "st-completed"
      refute html =~ "st-running"
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
      assert html =~ "Garbled"
      assert html =~ "text-subtle-foreground"
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

    test "renders 'in …' for future timestamps, not 'just now'" do
      future = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
      assigns = %{at: future}
      html = rendered_to_string(~H[<Core.relative_time at={@at} />])
      assert html =~ "in 2h"
      refute html =~ "just now"
    end

    test "emits <time data-ts data-rel> so the client localizes the tooltip" do
      now = DateTime.utc_now()
      assigns = %{at: now}
      html = rendered_to_string(~H[<Core.relative_time at={@at} />])
      assert html =~ "<time"
      assert html =~ ~s(data-rel="1")
      assert html =~ ~s(data-ts="#{DateTime.to_iso8601(now)}")
    end

    test "renders em-dash for nil, without a data-ts to localize" do
      assigns = %{at: nil}
      html = rendered_to_string(~H[<Core.relative_time at={@at} />])
      assert html =~ "—"
      refute html =~ "data-ts"
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

  describe "local_time/1" do
    test "emits a <time> carrying the UTC ISO for the client to localize" do
      assigns = %{at: ~U[2026-06-23 11:39:40.328499Z]}
      html = rendered_to_string(~H[<Core.local_time at={@at} format="datetime" />])

      assert html =~ "<time"
      # The client hook reads data-ts (UTC ISO) and data-format.
      assert html =~ ~s(data-ts="2026-06-23T11:39:40.328499Z")
      assert html =~ ~s(data-format="datetime")
      # A UTC fallback renders so it's legible before/without JS.
      assert html =~ "Jun 23, 2026"
    end

    test "the time format renders a ms-precision time-of-day fallback" do
      assigns = %{at: ~U[2026-06-23 11:39:40.328499Z]}
      html = rendered_to_string(~H[<Core.local_time at={@at} format="time" />])

      assert html =~ ~s(data-format="time")
      assert html =~ "11:39:40.328"
    end

    test "accepts an ISO string and normalizes it to data-ts" do
      assigns = %{at: "2026-06-23T11:39:40Z"}
      html = rendered_to_string(~H[<Core.local_time at={@at} format="datetime" />])

      assert html =~ ~s(data-ts="2026-06-23T11:39:40Z")
    end

    test "renders an em dash for a nil timestamp" do
      assigns = %{at: nil}
      html = rendered_to_string(~H[<Core.local_time at={@at} />])

      assert html =~ "—"
    end
  end
end
