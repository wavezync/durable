defmodule Durable.FuzzTerms do
  @moduledoc false
  # Generators for the worst things a workflow can hand Durable.

  import StreamData

  @strings [
    "",
    "\0",
    "a\0b",
    <<0xFF>>,
    <<0xC0, 0x80>>,
    <<0xED, 0xA0, 0x80>>,
    "\u{FFFF}",
    "\u{10FFFF}",
    "\\u0000",
    "'; DROP TABLE x; --",
    "__atom_keys__",
    "__fail__",
    "__timeout__",
    "__payload__",
    "__cancelled__",
    "__child:x"
  ]

  defp structs do
    [
      ~D[2026-01-01],
      ~U[2026-01-01 00:00:00Z],
      ~N[2026-01-01 00:00:00],
      ~T[00:00:00],
      Decimal.new("1.5"),
      Decimal.new("NaN"),
      URI.parse("https://example.com"),
      MapSet.new([1, {2}]),
      1..3,
      ~r/x/,
      %RuntimeError{message: "a\0b"},
      %ArgumentError{message: <<0xFF>>},
      Ecto.Changeset.change(%Durable.Storage.Schemas.StepExecution{})
    ]
  end

  defp exotic do
    [self(), make_ref(), &String.upcase/1, fn -> :ok end, [1 | 2], [[1] | "x"], {}, 2 ** 256]
  end

  def nasty_string do
    one_of([member_of(@strings), string(:utf8, max_length: 20), binary(max_length: 20)])
  end

  def leaf do
    one_of([
      member_of([nil, true, false, 0, -1, 1.5, -0.0, 1.0e308, :ok, :error, :"a b", :"\0"]),
      integer(),
      float(),
      atom(:alphanumeric),
      nasty_string(),
      bitstring(max_length: 9),
      member_of(structs()),
      member_of(exotic())
    ])
  end

  def key do
    one_of([
      member_of(@strings),
      string(:ascii, max_length: 4),
      atom(:alphanumeric),
      integer(0..3),
      constant({:a, 1}),
      constant([1]),
      constant(nil)
    ])
  end

  def nasty_term do
    tree(leaf(), fn child ->
      one_of([
        list_of(child, max_length: 3),
        map(list_of({key(), child}, max_length: 3), &Map.new/1),
        map(list_of(child, max_length: 3), &List.to_tuple/1)
      ])
    end)
  end

  @doc "A value `put_context/2` or a step's data could hold."
  def map_term, do: map(list_of({key(), nasty_term()}, max_length: 4), &Map.new/1)
end
