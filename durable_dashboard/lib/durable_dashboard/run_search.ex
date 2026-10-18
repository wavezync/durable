defmodule DurableDashboard.RunSearch do
  @moduledoc """
  Parses the Runs search box into `Durable.Query` filters.

      9f2c41a0                          run id (any leading slice)
      step:ship_order                   where the run is, or where it stopped
      error:503   error:"rate limited"  text anywhere in the run's error
      input.order_id:ORD-1042           exact value of an input field (dotted paths)
      schedule:nightly_report           runs that schedule started

  Other words are searched for in the error. Filters combine with AND.
  `workflow:`, `status:` and `since:` are facets: `split_facets/1` lifts them
  out of typed text before it joins the search.
  """

  @token ~r/([A-Za-z_][\w.]*):"([^"]*)"|([A-Za-z_][\w.]*):(\S+)|"([^"]*)"|(\S+)/u
  @id_like ~r/^[0-9a-f-]{4,36}$/

  @type token :: %{key: String.t() | nil, value: String.t(), raw: String.t()}

  @spec parse(String.t() | nil) :: keyword()
  def parse(text) do
    text
    |> tokens()
    |> Enum.reduce(%{}, &add/2)
    |> Enum.flat_map(&to_filter/1)
  end

  @doc """
  The search split into its terms, each with the text it came from — the
  query bar shows one tag per term and removes a tag by dropping its `raw`.
  """
  @spec tokens(String.t() | nil) :: [token()]
  def tokens(nil), do: []

  def tokens(text) when is_binary(text) do
    for [raw | groups] <- Regex.scan(@token, text), do: Map.put(token(groups), :raw, raw)
  end

  defp token([key, quoted]) when key != "", do: %{key: key, value: quoted}
  defp token(["", "", key, value]) when key != "", do: %{key: key, value: value}
  defp token(["", "", "", "", quoted]), do: %{key: nil, value: quoted}
  defp token(["", "", "", "", "", word]), do: %{key: nil, value: word}

  @doc """
  What a term searches, as `{label, value}` for its tag: a bare word is an
  id when it looks like one, otherwise text in the error, as `parse/1` reads it.
  """
  @spec label(token()) :: {String.t(), String.t()}
  def label(%{key: key, value: value}) when key in ~w(step id error schedule), do: {key, value}
  def label(%{key: "input." <> path = key, value: value}) when path != "", do: {key, value}
  def label(%{key: nil, value: value}), do: {word_kind(value), value}
  def label(%{key: key, value: value}), do: {"error", "#{key}:#{value}"}

  defp word_kind(word), do: if(Regex.match?(@id_like, word), do: "id", else: "error")

  @doc """
  Splits typed text into the facets it names — `workflow:`, `status:` (comma
  separated) and `since:` — and the rest of the search, so a typed facet
  becomes the same filter the facet menus set.
  """
  @spec split_facets(String.t()) :: {map(), String.t()}
  def split_facets(text) do
    {facets, rest} =
      text
      |> tokens()
      |> Enum.reduce({%{}, []}, fn
        %{key: "workflow", value: v}, {facets, rest} -> {Map.put(facets, :workflow, v), rest}
        %{key: "status", value: v}, {facets, rest} -> {Map.put(facets, :statuses, list(v)), rest}
        %{key: "since", value: v}, {facets, rest} -> {Map.put(facets, :range, v), rest}
        token, {facets, rest} -> {facets, [token.raw | rest]}
      end)

    {facets, rest |> Enum.reverse() |> Enum.join(" ")}
  end

  defp list(value), do: String.split(value, ",", trim: true)

  defp add(%{key: "step", value: value}, acc), do: Map.put(acc, :current_step, value)
  defp add(%{key: "id", value: value}, acc), do: Map.put(acc, :id_prefix, clean_id(value))
  defp add(%{key: "error", value: value}, acc), do: append_error(acc, value)
  defp add(%{key: "schedule", value: value}, acc), do: Map.put(acc, :schedule, value)

  defp add(%{key: "input." <> path, value: value}, acc) when path != "",
    do: Map.update(acc, :input, %{path => value}, &Map.put(&1, path, value))

  defp add(%{key: nil, value: word}, acc) do
    if Regex.match?(@id_like, word) and not Map.has_key?(acc, :id_prefix),
      do: Map.put(acc, :id_prefix, word),
      else: append_error(acc, word)
  end

  defp add(%{key: key, value: value}, acc), do: append_error(acc, "#{key}:#{value}")

  defp append_error(acc, ""), do: acc

  defp append_error(acc, text),
    do: Map.update(acc, :error_contains, text, &(&1 <> " " <> text))

  defp to_filter({:id_prefix, ""}), do: []
  defp to_filter({:schedule, name}), do: [trigger: :schedule, trigger_ref: name]
  defp to_filter({key, value}), do: [{key, value}]

  defp clean_id(value), do: value |> String.downcase() |> String.replace(~r/[^0-9a-f-]/, "")
end
