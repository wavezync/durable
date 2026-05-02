defmodule Durable.TelemetryHandler do
  @moduledoc """
  Attaches a telemetry handler that forwards Durable events to the calling test
  process as `{:event, suffix, measurements, metadata}` messages.

  Each test gets an independent handler keyed by a unique name so handlers from
  async-adjacent tests don't cross-talk. The handler is detached automatically
  on test exit.

  ## Usage

      Durable.TelemetryHandler.attach_events()

      # run code that emits [:durable, :queue, :job_completed]

      assert_receive {:event, :job_completed, %{duration_ms: _}, %{status: :completed}}
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @default_events [
    [:durable, :queue, :job_completed],
    [:durable, :queue, :heartbeat],
    [:durable, :queue, :stale_recovered],
    [:durable, :queue, :zombie_recovered],
    [:durable, :queue, :ack_failed]
  ]

  @doc """
  Attaches a handler for `events` and returns `:ok`.

  Defaults to the full queue event list. Pass a subset to keep the mailbox lean.
  The handler forwards each event to `test_pid` as
  `{:event, last_segment, measurements, metadata}`.
  """
  def attach_events(events \\ @default_events, test_pid \\ self()) do
    handler_id = "durable-telemetry-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(handler_id, events, &__MODULE__.handle/4, test_pid)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  @doc false
  def handle(event, measurements, metadata, test_pid) do
    suffix = List.last(event)
    send(test_pid, {:event, suffix, measurements, metadata})
  end
end
