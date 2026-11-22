defmodule Durable.Query.Opts do
  @moduledoc """
  The contract every read function of Durable keeps, and the one place that
  checks it.

  A read function (`Durable.get_execution/2`, `Durable.list_executions/1`,
  everything in `Durable.Query` and `Durable.Stats`, `Durable.Activity.list/1`,
  the pending listings of `Durable.Wait`, the schedule lookups) returns
  `{:ok, result}` or `{:error, reason}`, and has a twin ending in `!` that
  returns the result itself or raises:

      {:ok, runs} = Durable.list_executions(status: :failed, limit: 20)
      runs = Durable.list_executions!(status: :failed, limit: 20)

      {:error, {:invalid_option, :limit}} = Durable.list_executions(limit: -1)
      Durable.list_executions!(limit: -1)
      #=> ** (ArgumentError) invalid value for option :limit: -1

  ## Reasons

    * `{:invalid_option, key}` - the option `key` has a value of the wrong type
      or out of range: a negative or non-integer `:limit` or `:offset`, a status
      no run can have (alone or in a list), `bucket_seconds: 0`, text with a NUL
      byte or bytes that aren't UTF-8, a filter on an id that isn't a UUID. An
      option the function doesn't know is named the same way, so a misspelt
      filter can't match everything: `{:invalid_option, :statuz}`.
      Nothing is clamped or quietly matched against nothing. Options that aren't
      a keyword list are `{:invalid_option, :opts}`, and an argument that isn't
      an option is named the same way (`:parent_ids`, `:count`).
    * `:not_found` - the id (or schedule name) names nothing. That includes
      `nil` and an id that isn't a UUID.
    * `{:too_many_buckets, count}` - from `Durable.Stats.timeline/1` and
      `Durable.Stats.keys/1`, for a window cut into more than 10,000 buckets.

  A `nil` value is an option that wasn't set. `:durable`, the instance, is
  accepted everywhere.

  The `!` twins raise `ArgumentError` for each of these, with a message that
  names the option and the value. Both forms raise `ArgumentError` for a
  `:durable` instance that isn't started: that is a mistake in the app, not in
  the input.
  """

  alias Durable.Repo

  @max_int 9_223_372_036_854_775_807

  @typedoc "What a read function returns when it can't answer."
  @type reason :: {:invalid_option, atom()} | :not_found | {:too_many_buckets, pos_integer()}

  @type type ::
          :non_neg_integer
          | :pos_integer
          | :boolean
          | :datetime
          | :text
          | :texts
          | :name
          | :module
          | :uuid
          | :uuids
          | :input
          | {:one_of, [atom()]}
          | {:one_or_more_of, [atom()]}

  @doc """
  Checks `opts` against `schema`, a keyword list of option to type. Returns the
  options that were set (the `nil`s dropped), or the first that is wrong. An
  option that isn't in `schema` is wrong, bar `:durable`: a misspelt filter
  would otherwise match everything.

      iex> Durable.Query.Opts.validate([limit: 5, tag: nil], limit: :non_neg_integer)
      {:ok, [limit: 5]}
      iex> Durable.Query.Opts.validate([limt: 5], limit: :non_neg_integer)
      {:error, {:invalid_option, :limt}}
      iex> Durable.Query.Opts.validate([limit: -1], limit: :non_neg_integer)
      {:error, {:invalid_option, :limit}}
  """
  @spec validate(term(), [{atom(), type()}]) ::
          {:ok, keyword()} | {:error, {:invalid_option, atom()}}
  def validate(opts, schema \\ []) do
    if Keyword.keyword?(opts),
      do: opts |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> check(schema),
      else: {:error, {:invalid_option, :opts}}
  end

  defp check(opts, schema) do
    case Enum.find(opts, fn {key, value} ->
           not known?(schema, key) or not valid?(schema[key], value)
         end) do
      nil -> {:ok, opts}
      {key, _value} -> {:error, {:invalid_option, key}}
    end
  end

  defp known?(schema, key), do: key == :durable or Keyword.has_key?(schema, key)

  @doc """
  Whether `value` is of `type`.

      iex> Durable.Query.Opts.valid?(:pos_integer, 0)
      false
  """
  @spec valid?(type() | nil, term()) :: boolean()
  def valid?(nil, _value), do: true
  def valid?(:non_neg_integer, value), do: is_integer(value) and value in 0..@max_int
  def valid?(:pos_integer, value), do: is_integer(value) and value in 1..@max_int
  def valid?(:boolean, value), do: is_boolean(value)
  def valid?(:datetime, value), do: is_struct(value, DateTime)
  def valid?(:text, value), do: is_binary(value) and not Repo.bad_text?(value)
  def valid?(:texts, value), do: is_list(value) and Enum.all?(value, &valid?(:text, &1))
  def valid?(:name, value), do: (is_binary(value) or is_atom(value)) and not Repo.bad_text?(value)
  def valid?(:module, value), do: is_atom(value) and not Repo.bad_text?(value)
  def valid?(:uuid, value), do: Repo.id?(value)
  def valid?(:uuids, value), do: is_list(value) and Enum.all?(value, &Repo.id?/1)
  def valid?({:one_of, values}, value), do: value in values

  def valid?({:one_or_more_of, values}, value),
    do: value in values or (is_list(value) and Enum.all?(value, &(&1 in values)))

  # Dotted paths to exact values: %{"customer.tier" => "gold"}.
  def valid?(:input, value) do
    is_map(value) and not is_struct(value) and
      Enum.all?(value, fn {path, match} -> valid?(:name, path) and comparable?(match) end)
  end

  defp comparable?(value), do: is_number(value) or valid?(:name, value)

  @doc """
  Whether `id` could name a run: `:ok`, or `{:error, :not_found}` for `nil` and
  anything that isn't a UUID.
  """
  @spec id(term()) :: :ok | {:error, :not_found}
  def id(id), do: if(Repo.id?(id), do: :ok, else: {:error, :not_found})

  @doc """
  Turns a read function's answer into its `!` form: the result, or an
  `ArgumentError` that says what was wrong. `opts` are the options the caller
  passed and `args` its other arguments by name (the id under `:id`), so the
  message can show the value.

      iex> Durable.Query.Opts.unwrap!({:ok, [1]}, limit: 1)
      [1]
  """
  @spec unwrap!({:ok, result} | {:error, term()}, term(), keyword()) :: result
        when result: term()
  def unwrap!(result, opts, args \\ [])
  def unwrap!({:ok, result}, _opts, _args), do: result

  def unwrap!({:error, reason}, opts, args) do
    opts = if Keyword.keyword?(opts), do: opts, else: [opts: opts]
    raise ArgumentError, message(reason, args ++ opts)
  end

  defp message({:invalid_option, key}, given),
    do: "invalid value for option #{inspect(key)}: #{inspect(Keyword.get(given, key))}"

  defp message(:not_found, given), do: "nothing found for #{inspect(Keyword.get(given, :id))}"

  defp message({:too_many_buckets, count}, _given) do
    "the window is cut into #{count} buckets, and 10000 is the most: " <>
      "ask for a shorter window or a larger :bucket_seconds"
  end

  defp message(reason, _given), do: "the read failed: #{inspect(reason)}"
end
