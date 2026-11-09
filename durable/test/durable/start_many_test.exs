defmodule Durable.StartManyTest do
  use Durable.DataCase, async: false

  alias Durable.Storage.Schemas.WorkflowExecution

  defmodule ImportRow do
    use Durable

    workflow "import_row" do
      step(:save, fn data -> {:ok, data} end)
    end
  end

  defmodule Strict do
    use Durable

    workflow "strict_row", on_duplicate: :error do
      step(:save, fn data -> {:ok, data} end)
    end
  end

  defp runs, do: TestRepo.all(from(w in WorkflowExecution, order_by: w.inserted_at))

  test "one result per item, in order, with keys checked and shared options" do
    results =
      Durable.start_many(
        [
          {ImportRow, %{"row" => 1}, key: "import:9:row:1"},
          {ImportRow, %{"row" => 2}, key: "import:9:row:2", tags: ["row:2"]},
          {ImportRow, %{"row" => 1}, key: "import:9:row:1"},
          {Strict, %{"row" => 3}, key: "import:9:row:3"},
          {Strict, %{"row" => 3}, key: "import:9:row:3"},
          {ImportRow, %{"row" => 4}}
        ],
        tags: ["import:9"]
      )

    assert [{:ok, one}, {:ok, two}, {:ok, again}, {:ok, three}, dup, {:ok, four}] = results
    assert again == one
    assert dup == {:error, {:key_taken, three}}

    assert Enum.map(runs(), & &1.id) == [one, two, three, four]
    assert Enum.map(runs(), & &1.tags) == [["import:9"], ["row:2"], ["import:9"], ["import:9"]]
  end

  describe "return: :details" do
    test "says whether a start created a run" do
      assert {:ok, %{id: id, created: true}} =
               Durable.start(ImportRow, %{}, key: "a", return: :details)

      assert {:ok, %{id: ^id, created: false}} =
               Durable.start(ImportRow, %{}, key: "a", return: :details)

      assert {:ok, ^id} = Durable.start(ImportRow, %{}, key: "a")
      assert {:ok, %{created: true}} = Durable.start(ImportRow, %{}, return: :details)
    end

    test "still refuses a taken key the same way" do
      {:ok, holder} = Durable.start(Strict, %{}, key: "a")

      assert {:error, {:key_taken, ^holder}} =
               Durable.start(Strict, %{}, key: "a", return: :details)
    end

    test "works on start_many, for all items or one" do
      assert [{:ok, %{created: true}}, {:ok, %{created: false}}, {:ok, %{created: true}}] =
               Durable.start_many(
                 [
                   {ImportRow, %{}, key: "b"},
                   {ImportRow, %{}, key: "b"},
                   {ImportRow, %{}}
                 ],
                 return: :details
               )

      assert [{:ok, id}, {:ok, %{id: id2, created: true}}] =
               Durable.start_many([
                 {ImportRow, %{}},
                 {ImportRow, %{}, return: :details}
               ])

      assert is_binary(id) and is_binary(id2)
    end

    test "anything else is a programmer error" do
      assert_raise ArgumentError, ~r/return/, fn ->
        Durable.start(ImportRow, %{}, return: :everything)
      end
    end
  end

  test "joins the caller's transaction" do
    TestRepo.transaction(fn ->
      [{:ok, _}, {:ok, _}] = Durable.start_many([{ImportRow, %{}}, {ImportRow, %{}}])
      TestRepo.rollback(:undo)
    end)

    assert runs() == []
  end
end
