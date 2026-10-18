defmodule Durable.ActivityTest do
  @moduledoc """
  Queue history (the per-minute sampler) and the operational activity log.
  """
  use Durable.DataCase, async: false

  alias Durable.Activity
  alias Durable.Config
  alias Durable.Queue.Sampler
  alias Durable.Stats
  alias Durable.Storage.Schemas.{QueueSample, WorkflowExecution}

  defp config, do: Config.get(Durable)

  defp run!(status, attrs \\ %{}) do
    config().repo.insert!(
      struct(
        WorkflowExecution,
        Map.merge(
          %{workflow_module: "Elixir.Unused", workflow_name: "unused", status: status},
          attrs
        )
      )
    )
  end

  test "the sampler writes one row per queue per minute, however often it runs" do
    run!(:pending)
    run!(:pending, %{scheduled_at: DateTime.add(DateTime.utc_now(), 3_600, :second)})
    run!(:running)
    run!(:waiting, %{queue: "emails"})

    Sampler.sample(config())
    Sampler.sample(config())

    history = Stats.queue_history()
    assert [%{ready: 1, scheduled: 1, running: 1, waiting: 0}] = history["default"]
    assert [%{waiting: 1}] = history["emails"]
    assert config().repo.aggregate(QueueSample, :count) == 2
  end

  test "pausing and resuming a queue is recorded with who did it" do
    :ok = Durable.pause_queue(:default, by: "ops@example.com")
    :ok = Durable.resume_queue(:default)

    assert [
             %{kind: "queue_resumed", queue: "default", details: %{}},
             %{kind: "queue_paused", queue: "default", details: %{"by" => "ops@example.com"}}
           ] = Activity.list()
  end

  test "recording never raises, even for details that can't be stored as JSON" do
    assert :ok = Activity.record(config(), "worker_fenced", details: %{pid: self()})
    assert [%{kind: "worker_fenced", details: %{"pid" => "#PID<" <> _}}] = Activity.list()
  end

  test "pruning records how many runs it deleted" do
    old = DateTime.add(DateTime.utc_now(), -10_000, :second)
    run!(:completed, %{completed_at: old, updated_at: old})

    Durable.Pruner.prune(%{config() | prune: [completed: 1_000]})

    assert [%{kind: "pruned", count: 1, details: %{"completed" => 1}}] = Activity.list()
  end
end
