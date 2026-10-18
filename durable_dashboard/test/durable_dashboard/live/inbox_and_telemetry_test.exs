defmodule DurableDashboard.Live.InboxAndTelemetryTest do
  use ExUnit.Case, async: true

  alias DurableDashboard.Live.InputsLive
  alias DurableDashboard.Live.TelemetryLive

  describe "inbox answers" do
    test "a choice sends the chosen value, and needs one" do
      assert InputsLive.answer(%{input_type: :single_choice}, %{"choice" => "warn"}) ==
               {:ok, "warn"}

      assert {:error, _} = InputsLive.answer(%{input_type: :single_choice}, %{})
      assert InputsLive.answer(%{input_type: :multi_choice}, %{}) == {:ok, []}
    end

    test "a form parses numbers and checkboxes and enforces required fields" do
      input = %{
        input_type: :form,
        fields: [
          %{"name" => "amount", "type" => "number", "required" => true},
          %{"name" => "rush", "type" => "boolean"},
          %{"name" => "notes", "type" => "text"}
        ]
      }

      assert InputsLive.answer(input, %{"fields" => %{"amount" => "12.5", "notes" => ""}}) ==
               {:ok, %{"amount" => 12.5, "rush" => false}}

      assert InputsLive.answer(input, %{"fields" => %{"amount" => "3", "rush" => "true"}}) ==
               {:ok, %{"amount" => 3, "rush" => true}}

      assert {:error, "amount: required"} = InputsLive.answer(input, %{"fields" => %{}})

      assert {:error, "amount: not a number"} =
               InputsLive.answer(input, %{"fields" => %{"amount" => "x"}})
    end
  end

  test "the telemetry catalog lists exactly the events Durable emits, plus the audit event" do
    listed = for {_group, rows} <- TelemetryLive.catalog(), {event, _, _} <- rows, do: event

    assert Enum.sort(listed) ==
             Enum.sort([[:durable_dashboard, :action] | Durable.Telemetry.events()])

    # …and each one says, in its tooltip, what makes it fire.
    assert listed |> Enum.sort() == TelemetryLive.fires() |> Map.keys() |> Enum.sort()
  end

  test "config durations read in their largest whole unit" do
    assert DurableDashboard.Format.duration(250) == "250 ms"
    assert DurableDashboard.Format.duration(1_500) == "1500 ms"
    assert DurableDashboard.Format.duration(30_000) == "30 s"
    assert DurableDashboard.Format.duration(300_000) == "5 min"
    assert DurableDashboard.Format.duration(86_400_000) == "1 day"
    assert DurableDashboard.Format.duration(14 * 86_400_000) == "14 days"
  end
end
