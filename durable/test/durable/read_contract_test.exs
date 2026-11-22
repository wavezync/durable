defmodule Durable.ReadContractTest do
  @moduledoc """
  Every read function, in both forms, with every kind of bad input. The tuple
  form answers `{:ok, _}` or `{:error, _}` and never raises; the `!` form
  returns what the tuple form held, or raises `ArgumentError`.

  The functions come from `Durable.ReadFunctions`, and the first test fails
  when a read function isn't listed there.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.ReadFunctions

  @moduletag :capture_log

  doctest Durable.Query.Opts

  defmodule Asks do
    use Durable
    use Durable.Wait

    workflow "read_contract_asks" do
      step :ask, fn data -> {:ok, Map.put(data, "answer", wait_for_input("ok"))} end
    end
  end

  setup do
    run = run_workflow(Asks, %{}, key: "read:1", tags: ["read"])
    {:ok, schedule} = Durable.schedule(Asks, "0 9 * * *", name: "read_contract")
    {:ok, id: run.id, schedule: schedule}
  end

  # One option of each kind a read function takes, wrong in each way.
  @texts [
    :workflow_name,
    :current_step,
    :trigger_ref,
    :error_contains,
    :key,
    :tag,
    :id_prefix,
    :key_prefix,
    :event_name,
    :queue,
    :workflow
  ]
  @ids [:id, :parent_workflow_id, :workflow_id]
  @times [:since, :until, :from, :to, :timeout_before]
  @statuses [:status, :holder_status]

  @bad_options for(
                 key <- [:limit, :offset],
                 bad <- [-1, "10", 1.5, 2 ** 70, :all],
                 do: [{key, bad}]
               ) ++
                 for(
                   key <- @statuses,
                   bad <- [:bogus, "running", [:pending, :bogus], 7],
                   do: [{key, bad}]
                 ) ++
                 for(key <- @texts, bad <- ["a\0b", <<0xFF>>, 7, %{}], do: [{key, bad}]) ++
                 for(key <- @ids, bad <- ["not-a-uuid", "", 7, "a\0"], do: [{key, bad}]) ++
                 for(key <- @times, bad <- ["2026-01-01", 7, ~D[2026-01-01]], do: [{key, bad}]) ++
                 for(bad <- [0, -60, 1.5, "60"], do: [{:bucket_seconds, bad}]) ++
                 [
                   [since: ~U[2000-01-01 00:00:00Z], bucket_seconds: 1],
                   [kinds: ["a\0"]],
                   [kinds: "queue_paused"],
                   [input: %{"a\0" => "b"}],
                   [input: %{"a" => {1, 2}}],
                   [input: "a=b"],
                   [trigger: :bogus],
                   [enabled: "yes"],
                   [workflow_module: "Mod"],
                   [top_level_only: 1],
                   [include_steps: "yes"],
                   [include_logs: 1],
                   [include_children: "yes"],
                   [include_children: nil, limit: nil],
                   [no_such_option: -1]
                 ]

  @not_options [%{limit: 1}, "limit", [1, 2], [{"limit", 1}], nil, 7]

  # What each argument is when it is wrong, and what the function then says.
  defp bad(:id, _ctx) do
    for id <- [nil, "", "not-a-uuid", Ecto.UUID.generate(), 7, %{}, "a\0", <<0::128>>],
        do: {id, {:error, :not_found}}
  end

  defp bad(:ids, _ctx) do
    for ids <- [nil, "x", ["not-a-uuid"], [nil], %{}, 7],
        do: {ids, {:error, {:invalid_option, :parent_ids}}}
  end

  defp bad(:step, _ctx) do
    for step <- ["a\0", <<0xFF>>, 7, %{}, "no_such_step", :no_such_step],
        do: {step, {:error, :not_found}}
  end

  defp bad(:name, _ctx) do
    for name <- [nil, "a\0", <<0xFF>>, "no-such-schedule", 7, %{}, :read_contract],
        do: {name, {:error, :not_found}}
  end

  defp bad(:schedule, _ctx) do
    for schedule <- [nil, "read_contract", %{}, 7], do: {schedule, {:error, :not_found}}
  end

  defp bad(:count, _ctx) do
    for count <- [-1, "3", 1.5, nil, 1_001, 2 ** 70],
        do: {count, {:error, {:invalid_option, :count}}}
  end

  defp bad(:opts, _ctx) do
    for opts <- @not_options, do: {opts, {:error, {:invalid_option, :opts}}}
  end

  defp good(:id, ctx), do: ctx.id
  defp good(:ids, ctx), do: [ctx.id]
  defp good(:step, _ctx), do: :ask
  defp good(:name, _ctx), do: "read_contract"
  defp good(:schedule, ctx), do: ctx.schedule
  defp good(:count, _ctx), do: 2
  defp good(:opts, _ctx), do: []

  # Both forms, neither allowed anything but its contract.
  defp call({module, name, _kinds} = read, args) do
    result =
      try do
        apply(module, name, args)
      rescue
        error ->
          flunk("""
          #{ReadFunctions.label(read)} raised from its tuple form, given #{inspect(args)}
          #{Exception.format(:error, error, __STACKTRACE__)}
          """)
      end

    banged =
      try do
        {:ok, apply(module, ReadFunctions.bang(name), args)}
      rescue
        error in ArgumentError -> {:raised, Exception.message(error)}
      end

    case {result, banged} do
      {{:ok, _value}, {:ok, _same}} ->
        result

      {{:error, _reason}, {:raised, message}} ->
        assert message != ""
        result

      other ->
        flunk("""
        #{ReadFunctions.label(read)} and its ! twin disagree, given #{inspect(args)}
        #{inspect(other, pretty: true)}
        """)
    end
  end

  test "every read function is listed in Durable.ReadFunctions" do
    listed = MapSet.new(ReadFunctions.all(), fn {module, name, _args} -> {module, name} end)

    twinned =
      for module <- ReadFunctions.modules(),
          {name, arity} <- module.__info__(:functions),
          String.ends_with?(Atom.to_string(name), "!"),
          base = name |> Atom.to_string() |> String.trim_trailing("!") |> String.to_atom(),
          function_exported?(module, base, arity),
          into: MapSet.new(),
          do: {module, base}

    assert twinned == listed

    # A module that only reads has nothing without a twin.
    untwinned =
      for module <- ReadFunctions.read_only_modules(),
          {name, _arity} <- module.__info__(:functions),
          not String.ends_with?(Atom.to_string(name), "!"),
          name != :executions_query,
          {module, name} not in listed,
          do: {module, name}

    assert untwinned == []
  end

  for {module, name, kinds} = read <- ReadFunctions.all() do
    describe ReadFunctions.label(read) do
      test "answers, in both forms", ctx do
        read = unquote(Macro.escape(read))
        assert {:ok, _result} = call(read, Enum.map(unquote(kinds), &good(&1, ctx)))
      end

      test "with each argument wrong in turn says which, and never raises", ctx do
        read = unquote(Macro.escape(read))
        kinds = unquote(kinds)

        for {kind, at} <- Enum.with_index(kinds), {value, expected} <- bad(kind, ctx) do
          args = kinds |> Enum.map(&good(&1, ctx)) |> List.replace_at(at, value)

          assert call(read, args) == expected,
                 "#{ReadFunctions.label(read)} given #{inspect(args)}"
        end
      end

      if :opts in kinds do
        test "with every kind of bad option is ok or names one of them", ctx do
          read = unquote(Macro.escape(read))
          positional = unquote(kinds) |> List.delete(:opts) |> Enum.map(&good(&1, ctx))

          for options <- unquote(Macro.escape(@bad_options)) do
            case call(read, positional ++ [options]) do
              {:ok, _result} -> :ok
              {:error, {:too_many_buckets, _count}} -> :ok
              {:error, {:invalid_option, key}} -> assert key in Keyword.keys(options)
            end
          end
        end

        test "raises for an instance that isn't started, in both forms", ctx do
          positional = unquote(kinds) |> List.delete(:opts) |> Enum.map(&good(&1, ctx))
          args = positional ++ [[durable: ReadContractNoSuchInstance]]

          for name <- [unquote(name), ReadFunctions.bang(unquote(name))] do
            assert_raise ArgumentError, ~r/ReadContractNoSuchInstance not found/, fn ->
              apply(unquote(module), name, args)
            end
          end
        end
      end
    end
  end

  describe "an option the function takes" do
    # Each option reaches at least one function that refuses it: a typo in the
    # table above would otherwise pass as "ignored".
    test "is refused by some function when it is wrong", ctx do
      refused =
        for {module, name, kinds} <- ReadFunctions.all(),
            :opts in kinds,
            options <- @bad_options,
            positional = kinds |> List.delete(:opts) |> Enum.map(&good(&1, ctx)),
            {:error, {:invalid_option, key}} <- [apply(module, name, positional ++ [options])],
            into: MapSet.new(),
            do: key

      given = @bad_options |> Enum.flat_map(&Keyword.keys/1) |> Enum.uniq()
      assert Enum.reject(given, &(&1 in refused)) == [:no_such_option]
    end
  end
end
