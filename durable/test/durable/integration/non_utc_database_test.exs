defmodule Durable.Integration.NonUtcDatabaseTest do
  @moduledoc """
  A Postgres whose `TimeZone` isn't UTC. The timestamp columns hold UTC, so
  everything that compares them with the database's clock has to say so.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  alias Durable.Queue.StaleJobRecovery
  alias Durable.Wait.SleepWaker

  defmodule ZoneRepo do
    use Ecto.Repo, otp_app: :durable, adapter: Ecto.Adapters.Postgres
  end

  defmodule Slow do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "tz_slow" do
      step(:work, fn data ->
        Probe.note(:body)
        Probe.wait_for(:release)
        {:ok, data}
      end)
    end
  end

  defmodule Retries do
    use Durable
    alias Durable.IntegrationProbe, as: Probe

    workflow "tz_retries" do
      step(
        :work,
        [retry: [max_attempts: 2, backoff: :constant, base: 200, jitter: false]],
        fn data ->
          if Probe.note(:body) == 1, do: {:error, "again"}, else: {:ok, data}
        end
      )
    end
  end

  defmodule LongSleep do
    use Durable
    use Durable.Wait

    workflow "tz_long_sleep" do
      step(:nap, fn data ->
        sleep(:timer.hours(1))
        {:ok, data}
      end)
    end
  end

  # The session's zone, set per connection so it can't leak into other tests.
  defp start_in_zone!(zone, opts \\ []) do
    config =
      :durable
      |> Application.fetch_env!(IntegrationRepo)
      |> Keyword.put(:parameters, TimeZone: zone)

    Application.put_env(:durable, ZoneRepo, config)
    start_supervised!(ZoneRepo)
    assert ZoneRepo.query!("SHOW TimeZone").rows == [[zone]]

    Durable.DataCase.start_supervised_durable!(
      [repo: ZoneRepo, queues: queue_opts(%{default: 1})] ++ opts
    )
  end

  test "a fresh claim isn't stale to the sweep, behind UTC" do
    start_in_zone!("America/New_York", heartbeat_interval: 60_000)

    {:ok, id} = Durable.start(Slow, %{})
    assert_eventually(fn -> Probe.hits(:body) == 1 end)

    assert StaleJobRecovery.recover_now(Durable) == {:ok, 0}
    assert get(id).status == :running

    :ok = Probe.set(:release)
  end

  test "a 200 ms retry takes about 200 ms, behind UTC" do
    start_in_zone!("America/New_York")

    {:ok, id} = Durable.start(Retries, %{})
    await_status(id, :completed, 3_000)
    assert Probe.hits(:body) == 2
  end

  test "an hour's sleep doesn't end early, ahead of UTC" do
    start_in_zone!("Asia/Colombo")

    {:ok, id} = Durable.start(LongSleep, %{})
    await_status(id, :waiting)

    SleepWaker.wake_now(Durable)
    Process.sleep(200)

    assert get(id).status == :waiting
  end
end
