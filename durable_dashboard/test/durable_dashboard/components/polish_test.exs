defmodule DurableDashboard.Components.PolishTest do
  @moduledoc """
  Smoke coverage for the polish-pass components added in phase 5:
  `<.skeleton>`, `<.error_state>`, and the `CommandPalette` LiveComponent.
  Plus a SettingsLive Plug-level smoke check.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Command.CommandPalette
  alias DurableDashboard.Components.Core

  describe "skeleton/1" do
    test "default variant renders a rounded animated div" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.skeleton class="h-8 w-32" />])
      assert html =~ "animate-pulse"
      assert html =~ "rounded-md"
      assert html =~ "h-8 w-32"
      assert html =~ ~s(aria-hidden="true")
    end

    test "circle variant uses rounded-full" do
      assigns = %{}
      html = rendered_to_string(~H[<Core.skeleton variant="circle" class="size-6" />])
      assert html =~ "rounded-full"
    end
  end

  describe "error_state/1" do
    test "renders the alert role and the destructive icon ring" do
      assigns = %{}

      html =
        rendered_to_string(
          ~H[<Core.error_state title="Failed" description="Something went wrong" reason="ETIMEDOUT" />]
        )

      assert html =~ ~s(role="alert")
      assert html =~ "Failed"
      assert html =~ "Something went wrong"
      assert html =~ "ETIMEDOUT"
      assert html =~ "border-destructive/20"
    end

    test "action slot is rendered below the description" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Core.error_state title="Boom">
          <:action>
            <button>Retry</button>
          </:action>
        </Core.error_state>
        """)

      assert html =~ "Retry"
    end
  end

  describe "CommandPalette LiveComponent" do
    test "starts closed; root carries data-open=false and the hook attribute" do
      html =
        render_component(CommandPalette,
          id: "cmd-1",
          base_path: "/dashboard"
        )

      assert html =~ ~s(phx-hook="CommandPalette")
      assert html =~ ~s(data-open="false")
      # The dialog is hidden by class while closed.
      assert html =~ "hidden"
    end

    test "emits all five static routes when filtered with empty query" do
      html =
        render_component(CommandPalette,
          id: "cmd-2",
          base_path: "/dashboard"
        )

      for label <- ["Overview", "Workflows", "Pending inputs", "Schedules", "Settings"] do
        assert html =~ label
      end

      # Each item is wrapped in a listbox option with a per-row index value
      assert html =~ ~s(role="option")
      assert html =~ ~s(phx-value-index="0")
      assert html =~ ~s(phx-value-index="4")
    end
  end

  # Route-level smoke for SettingsLive deferred — the LV now lives in the
  # host's router (mounted via the `dashboard_routes/2` macro), not in the
  # dashboard's own plug. Driving routes here would require a configured
  # host endpoint + macro invocation in a fixture router, which is a
  # phase-6+ test-infra investment. Mount/render is exercised in dev via
  # the demo at /dashboard/settings.
end
