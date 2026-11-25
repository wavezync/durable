defmodule Durable.LaneOptionsTest do
  @moduledoc "`default:` and `timeout:` on a lane of a named parallel block."
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Storage.Schemas.{StepExecution, WorkflowExecution}
  alias Durable.Wait.TimeoutWorker

  @moduletag :capture_log

  defmodule Seen do
    def note(event), do: :persistent_term.put(__MODULE__, [event | all()])
    def all, do: Enum.reverse(:persistent_term.get(__MODULE__, []))
    def clear, do: :persistent_term.erase(__MODULE__)
  end

  # A loan application: the credit report decides it, the rest only help.
  defmodule Loan do
    use Durable
    use Durable.Helpers
    use Durable.Wait

    defp credit(application), do: {:ok, assign(application, :score, 710)}

    defp decide(application, lookups) do
      Seen.note({:decide, lookups})
      {:ok, application}
    end

    workflow "device_default" do
      parallel :lookups do
        step :credit, fn application -> credit(application) end

        step :device, [optional: true, default: %{trust: "unknown"}], fn application ->
          if application["device_check"] == "down",
            do: {:fail, "device check is down"},
            else: {:ok, assign(application, :trust, "high")}
        end
      end

      step :decide, fn %{"lookups" => lookups} = application -> decide(application, lookups) end

      # The run stops here and is picked up again from what was stored.
      step :sign, fn %{"lookups" => lookups} = application ->
        wait_for_input("signature")
        Seen.note({:sign, lookups})
        {:ok, application}
      end
    end

    workflow "slow_social" do
      parallel :lookups do
        step :credit, fn application -> credit(application) end

        lane :social, optional: true, default: %{profiles: 0}, timeout: 60 do
          step :find_profiles, [retry: [max_attempts: 5, base: 1]], fn _application ->
            Seen.note(:find_profiles)
            Process.sleep(40)
            {:error, "social search is slow"}
          end

          step :rate, fn application ->
            Seen.note(:rate)
            {:ok, application}
          end
        end
      end

      step :decide, fn %{"lookups" => lookups} = application -> decide(application, lookups) end
    end

    workflow "needed_lane_times_out" do
      parallel :lookups do
        lane :employer, timeout: 30 do
          step :call_employer, fn application ->
            Seen.note(:call_employer)
            unless :employer_answers in Seen.all(), do: Process.sleep(500)
            {:ok, assign(application, :employed, true)}
          end
        end
      end

      step :decide, fn %{"lookups" => lookups} = application -> decide(application, lookups) end
    end

    workflow "lane_waits" do
      parallel :lookups do
        step :credit, fn application -> credit(application) end

        lane :reference, optional: true, timeout: minutes(10) do
          step :ask_referee, fn application ->
            answer = wait_for_input("referee")
            {:ok, assign(application, :referee, answer)}
          end
        end
      end

      step :decide, fn %{"lookups" => lookups} = application -> decide(application, lookups) end
    end
  end

  setup do
    Seen.clear()
    on_exit(&Seen.clear/0)
  end

  defp lanes_of(run) do
    Durable.TestRepo.all(
      from(w in WorkflowExecution,
        where: w.parent_workflow_id == ^run.id,
        order_by: w.inserted_at
      )
    )
  end

  describe "default:" do
    test "is what the next step gets for an optional lane that failed, as stored data" do
      run = run_workflow(Loan, %{"device_check" => "down"}, workflow: "device_default")

      assert run.status == :waiting

      assert [{:decide, %{"credit" => %{"score" => 710}, "device" => %{"trust" => "unknown"}}}] =
               Seen.all()

      # The same after the run is read back from the database.
      :ok = Durable.provide_input(run.id, "signature", %{})
      assert drain(run).status == :completed
      assert {:sign, %{"device" => %{"trust" => "unknown"}}} = List.last(Seen.all())
    end

    test "is not used when the lane finishes" do
      run_workflow(Loan, %{}, workflow: "device_default")
      assert [{:decide, %{"device" => %{"trust" => "high"}}}] = Seen.all()
    end

    test "needs optional: true" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule Durable.LaneOptionsTest.NotOptional do
            use Durable
            workflow "w" do
              parallel :lookups do
                step(:device, [default: %{}], fn d -> {:ok, d} end)
              end
            end
          end
          """)
        end

      assert error.description =~ "give it optional: true as well"
    end
  end

  describe "timeout: on a lane" do
    test "covers every step and retry in it, and the lane fails once it's past" do
      {micros, run} = :timer.tc(fn -> run_workflow(Loan, %{}, workflow: "slow_social") end)

      assert run.status == :completed
      assert micros < 400_000
      # Five attempts of 40ms don't fit in 60ms, and the next step never starts.
      # On a slow machine the time can run out before the first.
      assert Enum.count(Seen.all(), &(&1 == :find_profiles)) in 0..2
      assert :rate not in Seen.all()
      assert {:decide, %{"social" => %{"profiles" => 0}}} = List.last(Seen.all())

      social =
        Enum.find(lanes_of(run), &(&1.engine_state["__parallel_step"] == "lookups__social"))

      assert social.status == :failed
      assert social.error["type"] == "timeout"
      assert social.error["message"] =~ "lane social passed its"
    end

    test "fails the block when the lane isn't optional, and a retry gives it the time again" do
      run = run_workflow(Loan, %{}, workflow: "needed_lane_times_out")

      assert run.status == :failed

      assert run.error["message"] ==
               "lane employer passed its timeout during lookups__employer__call_employer"

      [lane] = lanes_of(run)
      first_deadline = lane.deadline_at

      Seen.note(:employer_answers)
      before_retry = Durable.Clock.utc_now()
      {:ok, _} = Durable.retry(run.id)
      after_retry = Durable.Clock.utc_now()
      [lane] = lanes_of(run)
      assert DateTime.after?(lane.deadline_at, first_deadline)

      # Its 30 ms count from the retry, however long the retry took.
      refute DateTime.before?(lane.deadline_at, DateTime.add(before_retry, 30, :millisecond))
      refute DateTime.after?(lane.deadline_at, DateTime.add(after_retry, 30, :millisecond))

      assert drain(run).status == :completed
      assert {:decide, %{"employer" => %{"employed" => true}}} = List.last(Seen.all())
    end

    test "ends a lane that is waiting, and names the lane" do
      run = run_workflow(Loan, %{}, workflow: "lane_waits")
      assert run.status == :waiting
      lane = Enum.find(lanes_of(run), &(&1.status == :waiting))
      assert DateTime.diff(lane.deadline_at, DateTime.utc_now(), :second) in 590..600

      past = DateTime.add(DateTime.utc_now(), -1, :second)

      Durable.TestRepo.update_all(from(w in WorkflowExecution, where: w.id == ^lane.id),
        set: [deadline_at: past]
      )

      start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
      TimeoutWorker.check_timeouts(Durable)
      :sys.get_state(TimeoutWorker.worker_name(Durable))

      assert drain(run).status == :completed
      assert {:decide, %{"reference" => nil}} = List.last(Seen.all())

      lane = Durable.TestRepo.get!(WorkflowExecution, lane.id)

      assert lane.error["message"] ==
               "lane reference passed its 10m timeout before lookups__reference__ask_referee"

      assert Durable.TestRepo.aggregate(
               from(s in StepExecution,
                 where: s.workflow_id == ^lane.id and s.status == :completed
               ),
               :count
             ) == 0
    end

    test "is a positive number of milliseconds" do
      assert_raise ArgumentError, ~r/has timeout: "soon"/, fn ->
        Code.compile_string("""
        defmodule Durable.LaneOptionsTest.BadTimeout do
          use Durable
          workflow "w" do
            parallel :lookups do
              lane :slow, timeout: "soon" do
                step(:a, fn d -> {:ok, d} end)
              end
            end
          end
        end
        """)
      end
    end
  end
end
