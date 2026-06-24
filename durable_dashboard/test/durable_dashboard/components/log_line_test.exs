defmodule DurableDashboard.Components.LogLineTest do
  @moduledoc """
  Unit coverage for the shared `LogLine` component — message classification
  (JSON / embedded Elixir map / plain text) and the rendered row markup.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DurableDashboard.Components.Workflow.LogLine

  describe "parse_message/1" do
    test "classifies a whole-message JSON object as a term" do
      assert {:term, %{"json" => 1}} = LogLine.parse_message(~S({"json": 1}))
    end

    test "classifies a whole-message Elixir map (string keys, =>) as a term" do
      msg = ~S(%{"a" => 1, "b" => 2.5})
      assert {:term, %{"a" => 1, "b" => 2.5}} = LogLine.parse_message(msg)
    end

    test "handles atom keys, nesting, lists and booleans in an Elixir map" do
      assert {:term, %{:b => 2, :c => [1, 2, %{d: true}], "a" => 1}} =
               LogLine.parse_message(~S|%{"a" => 1, b: 2, c: [1, 2, %{d: true}]}|)
    end

    test "splits a 'label: %{...}' message into a prefix + parsed map" do
      msg =
        ~S|[Cron] Metrics gathered: %{"active_users" => 491, "error_rate" => 0.046}|

      assert {:prefix_term, "[Cron] Metrics gathered:",
              %{"active_users" => 491, "error_rate" => 0.046}} = LogLine.parse_message(msg)
    end

    test "falls back to plain text for non-literal terms (function calls)" do
      assert :text = LogLine.parse_message(~S|result: %{pid: foo()}|)
    end

    test "plain text stays text" do
      assert :text = LogLine.parse_message("just a regular log line")
    end

    test "a leading [tag] alone is never mistaken for a list literal" do
      assert :text = LogLine.parse_message("[Cron] nothing structured here")
    end
  end

  describe "row/1 rendering" do
    defp render_entry(entry, opts \\ []) do
      assigns = Map.merge(%{entry: entry, show_step: true}, Map.new(opts))
      render_component(&LogLine.row/1, assigns)
    end

    test "an embedded Elixir map is syntax-highlighted in the expanded block" do
      html =
        render_entry(%{
          "level" => "info",
          "message" =>
            ~S|[Cron] Metrics gathered: %{"active_users" => 491, "error_rate" => 0.046}|,
          "timestamp" => "2026-05-04T06:21:04Z"
        })

      # The text prefix renders, and the map keys/values are highlighted spans.
      assert html =~ "[Cron] Metrics gathered:"
      assert html =~ ~s(<span class="text-primary">&quot;active_users&quot;</span>)
      assert html =~ ~s(<span class="text-warning">491</span>)
    end

    test "show_step={false} suppresses the summary step column (detail still lists it)" do
      entry = %{"level" => "info", "message" => "hi", "__step__" => "gather", "timestamp" => nil}
      with_step = render_entry(entry, show_step: true)
      without_step = render_entry(entry, show_step: false)

      # The summary-line step column (its distinctive max-width class) only
      # appears when show_step is true...
      assert with_step =~ "md:max-w-[150px]"
      refute without_step =~ "md:max-w-[150px]"

      # ...but the expanded fields table lists the step either way.
      assert without_step =~ ">step</span>"
      assert without_step =~ "gather"
    end

    test "level drives the semantic color and left accent" do
      html =
        render_entry(%{"level" => "error", "message" => "boom", "timestamp" => nil})

      assert html =~ "text-destructive"
      assert html =~ "border-l-destructive"
    end
  end
end
