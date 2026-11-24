defmodule ClockSkewIdle do
  @moduledoc false
  use Durable

  workflow "clock_skew_idle" do
    step :work, fn data -> {:ok, data} end
  end
end

defmodule Durable.Integration.ClockSkewTest do
  @moduledoc """
  A node whose clock reads wrong, as one does before its first sync or beside
  an instance on another database server (`Durable.Clock`): a lock's age is
  still the database's to tell, as the claim tells it. The swarm in
  test/skew/ runs real nodes with skewed clocks.
  """
  use Durable.IntegrationCase, async: false

  alias Durable.Clock
  alias Durable.Config
  alias Durable.Queue.Adapters.Postgres

  @stale_s 3

  setup do
    saved = :persistent_term.get({Clock, :offset}, nil)
    on_exit(fn -> Clock.put_offset(saved) end)
    Durable.DataCase.start_supervised_durable!(repo: IntegrationRepo, queue_enabled: false)
    %{config: Config.get(Durable)}
  end

  # This node's clock reads `ms` off the database's.
  defp skew!(ms) do
    %{rows: [[db]]} =
      IntegrationRepo.query!("SELECT (extract(epoch FROM clock_timestamp()) * 1000000)::bigint")

    Clock.put_offset(db - System.monotonic_time(:microsecond) + ms * 1_000)
  end

  # Claimed as a poller claims, by the database's clock.
  defp claimed!(config) do
    {:ok, _id} = Durable.start(ClockSkewIdle, %{})
    [job] = Postgres.fetch_jobs(config, "default", 1, "node-a")
    job
  end

  defp lock_age_ms(id) do
    %{rows: [[ms]]} =
      IntegrationRepo.query!(
        "SELECT (extract(epoch FROM (NOW() AT TIME ZONE 'UTC') - locked_at) * 1000)::int " <>
          "FROM durable.workflow_executions WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    ms
  end

  test "a sweep on a node whose clock is ahead leaves a live lock alone", %{config: config} do
    job = claimed!(config)
    skew!((@stale_s + 10) * 1_000)

    assert {:ok, 0} = Postgres.recover_stale_locks(config, @stale_s)
    assert %{status: :running, lock_token: token} = get(job.id)
    assert token == job.lock_token
  end

  test "a sweep on a node whose clock is behind still takes a stale lock", %{config: config} do
    job = claimed!(config)

    IntegrationRepo.query!(
      "UPDATE durable.workflow_executions SET locked_at = locked_at - INTERVAL '#{@stale_s + 1} seconds' WHERE id = $1",
      [Ecto.UUID.dump!(job.id)]
    )

    skew!(-3_600_000)

    assert {:ok, 1} = Postgres.recover_stale_locks(config, @stale_s)
    assert get(job.id).status == :pending
  end

  # As `Executor.cancel_run/3` leaves a run cancelled with `rollback: true`: on
  # its queue, with its worker's lock and no token, until that worker lets go.
  test "a sweep on a node whose clock is ahead keeps a live undo's lock", %{config: config} do
    job = claimed!(config)

    IntegrationRepo.update_all(from(w in WorkflowExecution, where: w.id == ^job.id),
      set: [status: :pending, lock_token: nil]
    )

    skew!((@stale_s + 10) * 1_000)

    assert {:ok, 0} = Postgres.recover_stale_locks(config, @stale_s)
    assert get(job.id).locked_by == "node-a"
  end

  test "a heartbeat on a node whose clock is behind stamps the database's time", %{config: config} do
    job = claimed!(config)
    skew!(-3_600_000)

    assert :ok = Postgres.heartbeat(config, job.id, job.lock_token)
    assert abs(lock_age_ms(job.id)) < 1_000
  end
end
