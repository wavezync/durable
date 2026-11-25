defmodule ConnectionLostEndShip do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "connection_lost_end_ship" do
    step :connection_lost_ship, [retry: [max_attempts: 3]], fn parcel ->
      Probe.note(:shipped)
      {:ok, parcel}
    end
  end
end

defmodule Durable.Integration.ConnectionLostEndTest do
  use Durable.IntegrationCase, async: false

  alias Durable.Queue.Manager

  @moduletag :capture_log

  # The first write of the step's result is given up on, as a statement
  # timeout would be (rule 32): the run goes back on its queue, the attempt
  # closed as a lost worker's.
  defp give_up_first_result! do
    IntegrationRepo.query!("CREATE SEQUENCE durable.connection_lost_results")

    IntegrationRepo.query!("""
    CREATE FUNCTION durable.connection_lost_result() RETURNS trigger AS $$
    BEGIN
      IF NEW.step_name = 'connection_lost_ship' AND NEW.status = 'completed'
         AND nextval('durable.connection_lost_results') = 1 THEN
        RAISE EXCEPTION 'canceling statement due to statement timeout'
          USING ERRCODE = 'query_canceled';
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    IntegrationRepo.query!("""
    CREATE TRIGGER connection_lost_result BEFORE UPDATE ON durable.step_executions
    FOR EACH ROW EXECUTE FUNCTION durable.connection_lost_result()
    """)

    on_exit(fn ->
      IntegrationRepo.query!("DROP TRIGGER connection_lost_result ON durable.step_executions")
      IntegrationRepo.query!("DROP FUNCTION durable.connection_lost_result()")
      IntegrationRepo.query!("DROP SEQUENCE durable.connection_lost_results")
    end)
  end

  # Holds whoever closes the lost attempt, once it has put the run back and
  # before it has sent the attempt's end, for a few heartbeats.
  def hold_closer(_event, _measurements, %{source: "step_executions"} = meta, _config) do
    if meta.query =~ ~r/^UPDATE/ and inspect(meta.params) =~ "worker_lost",
      do: Process.put(:connection_lost_closed, true)
  end

  def hold_closer(_event, _measurements, %{source: "workflow_executions"} = meta, _config) do
    if Process.get(:connection_lost_closed) == true and meta.query =~ ~r/^UPDATE/ do
      Process.delete(:connection_lost_closed)
      Probe.note(:held)
      Probe.wait_for(:go)
    end
  end

  def hold_closer(_event, _measurements, _meta, _config), do: :ok

  def note_attempt([:durable, :step, phase], _measurements, meta, test) do
    send(test, {:attempt, if(phase == :start, do: :start, else: :end), meta.step_execution_id})
  end

  defp attempt_events(events \\ [], tries \\ 30) do
    Process.sleep(100)
    events = drain(events)
    started = for {:start, id} <- events, do: id
    ended = for {:end, id} <- events, do: id

    if Enum.sort(started) != Enum.sort(ended) and tries > 0,
      do: attempt_events(events, tries - 1),
      else: {started, ended}
  end

  defp drain(acc) do
    receive do
      {:attempt, kind, id} -> drain([{kind, id} | acc])
    after
      0 -> acc
    end
  end

  # The worker's task put the run back and was then to send the lost
  # attempt's end. Its worker's next heartbeat found the claim gone and killed
  # it first: the attempt was closed, its end never sent.
  test "an attempt closed after its connection was lost has its end sent" do
    give_up_first_result!()
    handler = "connection-lost-end-#{System.unique_integer([:positive])}"
    phases = for phase <- [:start, :stop, :exception], do: [:durable, :step, phase]
    :telemetry.attach_many(handler, phases, &__MODULE__.note_attempt/4, self())
    query = [:durable, :integration_repo, :query]
    :telemetry.attach("#{handler}-hold", query, &__MODULE__.hold_closer/4, nil)

    on_exit(fn ->
      :telemetry.detach(handler)
      :telemetry.detach("#{handler}-hold")
    end)

    start_durable!(%{default: 1}, heartbeat_interval: 100)
    {:ok, id} = Durable.start(ConnectionLostEndShip, %{"parcel" => 1})

    assert_eventually(fn -> Probe.hits(:held) == 1 end, 5_000)
    Process.sleep(600)
    Probe.set(:go)

    await_status(id, :completed)
    {started, ended} = attempt_events()

    assert length(started) == 2
    assert {started -- ended, ended -- started} == {[], []}
  end

  # The worker puts the run back while still answering its poller: one
  # restarted meanwhile adopts it in init. Done in the worker's own
  # handle_info, the adopt waited out its 5 s and the worker was left out.
  test "a poller restarted while a worker puts a run back adopts it at once" do
    give_up_first_result!()
    handler = "connection-lost-adopt-#{System.unique_integer([:positive])}"
    query = [:durable, :integration_repo, :query]
    :telemetry.attach(handler, query, &__MODULE__.hold_closer/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)

    start_durable!(%{default: 1}, heartbeat_interval: 100)
    {:ok, id} = Durable.start(ConnectionLostEndShip, %{"parcel" => 1})
    assert_eventually(fn -> Probe.hits(:held) == 1 end, 5_000)

    poller = Process.whereis(Durable.Queue.Poller.Default)
    started = System.monotonic_time(:millisecond)
    Process.exit(poller, :kill)

    assert_eventually(fn ->
      Process.whereis(Durable.Queue.Poller.Default) not in [nil, poller]
    end)

    status = Manager.status(Durable, :default)

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert status.active_jobs == 1

    Probe.set(:go)
    await_status(id, :completed)
  end
end
