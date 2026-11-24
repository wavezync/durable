defmodule Durable.ClockTest do
  # The offset is the node's, so nothing else may read it while this changes it.
  use Durable.DataCase, async: false

  alias Durable.Clock
  alias Durable.Config

  setup do
    on_exit(fn -> Clock.sync(Config.get(Durable)) end)
  end

  defp db_now do
    %{rows: [[us]]} =
      Durable.TestRepo.query!("SELECT (extract(epoch FROM clock_timestamp()) * 1000000)::bigint")

    DateTime.from_unix!(us, :microsecond)
  end

  # An offset that makes the clock read `ms` ahead of this node's own.
  defp ahead_of_this_node(ms) do
    System.os_time(:microsecond) - System.monotonic_time(:microsecond) + ms * 1_000
  end

  test "the offset is the middle of the shortest round trip" do
    samples = [
      {0, 1_000_500, 1_000},
      {2_000, 1_002_300, 2_100},
      {5_000, 900_000, 9_000}
    ]

    assert Clock.offset(samples) == 1_002_300 - 2_050
  end

  test "the clock reads the monotonic clock plus the offset, or this node's own without one" do
    Clock.put_offset(ahead_of_this_node(3_600_000))

    assert_in_delta DateTime.diff(Clock.utc_now(), DateTime.utc_now(), :millisecond),
                    3_600_000,
                    1_000

    assert {_, 6} = Clock.utc_now().microsecond

    Clock.put_offset(nil)
    assert_in_delta DateTime.diff(Clock.utc_now(), DateTime.utc_now(), :millisecond), 0, 1_000
  end

  test "the skew is how far this node's own clock is ahead of the database's" do
    Clock.put_offset(ahead_of_this_node(3_600_000))
    assert_in_delta Clock.skew_ms(), -3_600_000, 1_000

    Clock.put_offset(nil)
    assert Clock.skew_ms() == 0
  end

  test "a sync sets the clock to the database's, however far off it was" do
    Clock.put_offset(ahead_of_this_node(3_600_000))

    assert is_integer(Clock.sync(Config.get(Durable)))
    assert_in_delta DateTime.diff(Clock.utc_now(), db_now(), :microsecond), 0, 50_000
  end

  test "a sync that can't read the database leaves the clock as it was" do
    Clock.put_offset(ahead_of_this_node(3_600_000))
    unreachable = %{Config.get(Durable) | repo: Durable.IntegrationRepo}

    assert Clock.sync(unreachable) == :error

    assert_in_delta DateTime.diff(Clock.utc_now(), DateTime.utc_now(), :millisecond),
                    3_600_000,
                    1_000
  end

  # What a module calls is in its beam's import table, so a doc example
  # doesn't count. Telemetry's span start carries the system time by
  # convention.
  test "nothing in lib reads this node's own clock but Durable.Clock" do
    own_clock = [
      {DateTime, :utc_now},
      {NaiveDateTime, :utc_now},
      {System, :os_time},
      {System, :system_time},
      {:os, :system_time},
      {:erlang, :system_time}
    ]

    readers =
      for mod <- Application.spec(:durable, :modules),
          to_string(mod.module_info(:compile)[:source]) =~ "/durable/lib/",
          {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(mod), [:imports]),
          {called, fun, _arity} <- imports,
          {called, fun} in own_clock,
          {mod, called} not in [{Durable.Clock, DateTime}, {Durable.Telemetry, :erlang}],
          uniq: true,
          do: {mod, called, fun}

    assert readers == []
  end

  test "every schema's timestamps come from Durable.Clock" do
    stamped =
      for mod <- Application.spec(:durable, :modules),
          function_exported?(mod, :__schema__, 1),
          {fields, mfa} <- mod.__schema__(:autogenerate),
          :inserted_at in fields or :updated_at in fields,
          do: {mod, mfa}

    assert stamped != []
    assert Enum.reject(stamped, &match?({_, {Durable.Clock, :utc_now, []}}, &1)) == []
  end

  test "a node sets the clock as it starts" do
    Clock.put_offset(ahead_of_this_node(3_600_000))

    start_supervised!(
      {Durable, name: ClockTestDurable, repo: Durable.TestRepo, queue_enabled: false},
      id: :clock_test_durable
    )

    assert_in_delta DateTime.diff(Clock.utc_now(), db_now(), :microsecond), 0, 50_000
  end
end
