defmodule Durable.Audit4ApiTimelineTest do
  @moduledoc """
  `Stats.timeline/1` returns every bucket of its window, empty or not. Asked
  for a window of years cut into seconds, that is hundreds of millions of maps:
  it has to say no, not try.
  """
  use Durable.DataCase, async: false

  alias Durable.Stats

  @until ~U[2026-06-01 00:00:00Z]

  @tag timeout: 10_000
  test "a window of 26 years in one-second buckets is refused at once" do
    assert {:error, {:too_many_buckets, count}} =
             Stats.timeline(since: ~U[2000-01-01 00:00:00Z], until: @until, bucket_seconds: 1)

    assert count == DateTime.diff(@until, ~U[2000-01-01 00:00:00Z], :second)
  end

  test "ten thousand buckets are returned, and one more is refused" do
    since = DateTime.add(@until, -10_000, :second)
    buckets = Stats.timeline(since: since, until: @until, bucket_seconds: 1)

    assert length(buckets) == 10_000
    assert hd(buckets).at == since

    assert Stats.timeline(
             since: DateTime.add(since, -1, :second),
             until: @until,
             bucket_seconds: 1
           ) == {:error, {:too_many_buckets, 10_001}}
  end

  test "the default bucket size never asks for too many, however long the window" do
    buckets = Stats.timeline(since: ~U[1970-01-01 00:00:00Z], until: @until)
    assert length(buckets) in 48..49
  end
end
