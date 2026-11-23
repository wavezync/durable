defmodule Durable.HelpersTest do
  use ExUnit.Case, async: true

  import Durable.Helpers

  @order %{"total" => 12, "customer" => %{"city" => "Galle", "vip" => false}}

  test "a key named by an atom or a string reads and writes the string key" do
    assert get(@order, :total) == 12
    assert get(@order, "total") == 12
    assert get(@order, :missing, 0) == 0

    assert assign(@order, :total, 20)["total"] == 20

    assert assign(@order, %{total: 20, paid: true}) |> Map.take(["total", "paid"]) ==
             %{"total" => 20, "paid" => true}

    assert increment(@order, :total)["total"] == 13
    assert increment(@order, :retries)["retries"] == 1
    assert append(@order, :notes, "late")["notes"] == ["late"]
    assert append(%{"notes" => ["a"]}, :notes, "b")["notes"] == ["a", "b"]
    refute has_key?(delete(@order, :total), :total)
  end

  test "a list is a path into the data" do
    assert get(@order, [:customer, :city]) == "Galle"
    assert get(@order, ["customer", :vip]) == false
    assert get(@order, [:customer, :street]) == nil
    assert get(@order, [:customer, :street], "unknown") == "unknown"
    assert get(@order, [:shipping, :city], "unknown") == "unknown"
  end

  test "an atom put with Map.put sits beside the stored key until the step returns" do
    order = Map.put(@order, :total, 99)
    assert get(order, :total) == 12
    # Stored, the atom's value is the one kept: it is what the step just wrote.
    assert Durable.Executor.sanitize_for_json(order) == Map.put(@order, "total", 99)
  end
end
