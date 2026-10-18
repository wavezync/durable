defmodule DurableDashboard.RunSearchTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias DurableDashboard.RunSearch

  test "each syntax maps to its Durable.Query filter" do
    assert RunSearch.parse("9f2c41a0") == [id_prefix: "9f2c41a0"]
    assert RunSearch.parse("step:ship_order") == [current_step: "ship_order"]
    assert RunSearch.parse(~s(error:"rate limited")) == [error_contains: "rate limited"]
    assert RunSearch.parse("schedule:nightly") == [trigger: :schedule, trigger_ref: "nightly"]

    assert RunSearch.parse("input.order_id:ORD-1042 input.customer.tier:gold") == [
             input: %{"order_id" => "ORD-1042", "customer.tier" => "gold"}
           ]
  end

  test "filters combine, and plain words search the error" do
    filters = RunSearch.parse(~s(step:charge carrier timeout error:503))

    assert filters[:current_step] == "charge"
    assert filters[:error_contains] == "carrier timeout 503"
  end

  test "an unknown key is searched as text rather than dropped" do
    assert RunSearch.parse("region:eu") == [error_contains: "region:eu"]
  end

  test "id: strips characters that can't be in a run id" do
    assert RunSearch.parse("id:9F2C%_41") == [id_prefix: "9f2c41"]
    assert RunSearch.parse("id:%%") == []
  end

  test "blank input means no filters" do
    assert RunSearch.parse(nil) == []
    assert RunSearch.parse("   ") == []
  end

  test "tokens keep their text, so a tag can be removed by dropping it" do
    tokens = RunSearch.tokens(~s(step:charge error:"rate limited" 9f2c41a0 timeout))

    assert Enum.map(tokens, & &1.raw) == [
             "step:charge",
             ~s(error:"rate limited"),
             "9f2c41a0",
             "timeout"
           ]

    assert Enum.map(tokens, &RunSearch.label/1) == [
             {"step", "charge"},
             {"error", "rate limited"},
             {"id", "9f2c41a0"},
             {"error", "timeout"}
           ]

    assert RunSearch.label(hd(RunSearch.tokens("region:eu"))) == {"error", "region:eu"}
  end

  test "typed facets are lifted out of the search" do
    assert RunSearch.split_facets("workflow:pay status:failed,waiting since:24h step:x 9f2c") ==
             {%{workflow: "pay", statuses: ["failed", "waiting"], range: "24h"}, "step:x 9f2c"}

    assert RunSearch.split_facets("timeout") == {%{}, "timeout"}
  end

  property "any text parses to known filters without crashing" do
    check all(text <- string(:printable, max_length: 80), max_runs: 500) do
      filters = RunSearch.parse(text)

      assert Keyword.keyword?(filters)

      assert Enum.all?(
               Keyword.keys(filters),
               &(&1 in [:id_prefix, :current_step, :error_contains, :input])
             )
    end
  end

  property "generated field searches round-trip" do
    word = string([?a..?z, ?0..?9, ?_], min_length: 1, max_length: 12)

    check all(step <- word, path <- word, value <- word, max_runs: 200) do
      parsed = RunSearch.parse("step:#{step} input.#{path}:#{value}")

      assert parsed[:current_step] == step
      assert parsed[:input] == %{path => value}
    end
  end
end
