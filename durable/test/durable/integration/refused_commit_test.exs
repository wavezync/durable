defmodule RefusedCommitParcel do
  @moduledoc false
  use Durable
  alias Durable.IntegrationProbe, as: Probe

  workflow "refused_commit_parcel" do
    step :refused_commit_pack, fn parcel ->
      Probe.note(:packed)
      {:ok, parcel}
    end
  end
end

defmodule Durable.Integration.RefusedCommitTest do
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  # The first attempt's COMMIT is refused with an error that isn't transient
  # (a deferred check, here; the same for any error the database answers a
  # COMMIT with): the row never lands, and the start event is out.
  defp refuse_first_commit! do
    IntegrationRepo.query!("CREATE SEQUENCE durable.refused_commits")

    IntegrationRepo.query!("""
    CREATE FUNCTION durable.refuse_commit() RETURNS trigger AS $$
    BEGIN
      IF NEW.step_name = 'refused_commit_pack' AND nextval('durable.refused_commits') = 1 THEN
        RAISE EXCEPTION 'parcel row refused' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NULL;
    END $$ LANGUAGE plpgsql
    """)

    IntegrationRepo.query!("""
    CREATE CONSTRAINT TRIGGER refuse_commit AFTER INSERT ON durable.step_executions
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION durable.refuse_commit()
    """)

    on_exit(fn ->
      IntegrationRepo.query!("DROP TRIGGER refuse_commit ON durable.step_executions")
      IntegrationRepo.query!("DROP FUNCTION durable.refuse_commit()")
      IntegrationRepo.query!("DROP SEQUENCE durable.refused_commits")
    end)
  end

  def note_attempt([:durable, :step, phase], _measurements, meta, test) do
    send(test, {:attempt, if(phase == :start, do: :start, else: :end), meta.step_execution_id})
  end

  defp attempt_events do
    receive do
      {:attempt, kind, id} -> [{kind, id} | attempt_events()]
    after
      0 -> []
    end
  end

  # Nothing is killed and nothing is transient: begin_attempt raises with the
  # start out, outside the step's span, and the nack closes nothing.
  test "an attempt whose COMMIT the database refuses has an end for its start" do
    refuse_first_commit!()
    handler = "refused-commit-#{System.unique_integer([:positive])}"
    phases = for phase <- [:start, :stop, :exception], do: [:durable, :step, phase]
    :telemetry.attach_many(handler, phases, &__MODULE__.note_attempt/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    start_durable!(%{default: 1})

    {:ok, id} = Durable.start(RefusedCommitParcel, %{"parcel" => 1})
    assert_eventually(fn -> get(id).status in [:completed, :failed] end, 5_000)
    Process.sleep(200)

    events = attempt_events()
    started = for {:start, attempt} <- events, do: attempt
    ended = for {:end, attempt} <- events, do: attempt

    assert started != []
    assert {started -- ended, ended -- started} == {[], []}
  end
end
