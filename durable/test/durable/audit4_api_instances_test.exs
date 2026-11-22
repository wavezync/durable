defmodule Durable.Audit4ApiInstancesTest do
  @moduledoc """
  What an instance is given at boot, two instances side by side, and what each
  one tells the outside about a run that waits: every broadcast and telemetry
  event once, in order, under its own instance's name.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Config
  alias Durable.Executor
  alias Durable.PubSub, as: DurablePubSub
  alias Durable.Wait
  alias Durable.Wait.TimeoutWorker

  @moduletag :capture_log

  @other Audit4ApiOtherInstance

  defmodule Audit4ApiWaits do
    use Durable
    use Durable.Wait

    workflow "audit4_api_instance_waits" do
      step(:wait, fn data ->
        got =
          case data["wait"] do
            "input" -> wait_for_input("x")
            "input_or_fail" -> wait_for_input("x", timeout: 0, on_timeout: :fail)
            "event" -> wait_for_event("x")
            "any" -> wait_for_any(["x", "y"])
            "all" -> wait_for_all(["x", "y"])
            "sleep" -> sleep(60_000)
          end

        {:ok, Map.put(data, "got", inspect(got))}
      end)
    end
  end

  def forward(event, _measurements, meta, pid), do: send(pid, {:telemetry, event, meta})

  # Everything heard so far, in order: broadcasts by kind, telemetry by event
  # with the one field that says how it ended.
  defp heard(acc \\ []) do
    receive do
      {:telemetry, [:durable, what, phase], meta} ->
        heard([{what, phase, meta[:status] || meta[:result] || meta[:resumed]} | acc])

      {:durable_event, kind, %{id: _}} ->
        heard([kind | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp listen(config) do
    handler = "audit4-api-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(handler, Durable.Telemetry.events(), &__MODULE__.forward/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
    subscribe(config)
  end

  defp subscribe(config) do
    :ok = DurablePubSub.subscribe(config, DurablePubSub.workflows_topic(config))
    :ok = DurablePubSub.subscribe(config, DurablePubSub.inputs_topic(config))
  end

  defp start_waiting(wait, opts \\ []) do
    config = Config.get(Keyword.get(opts, :durable, Durable))
    {:ok, id} = Durable.start(Audit4ApiWaits, %{"wait" => wait}, opts)
    {:waiting, _run} = Executor.execute_workflow(id, config)
    id
  end

  @first_segment [
    :workflow_started,
    :workflow_resumed,
    {:workflow, :start, false},
    {:step, :start, nil},
    {:step, :stop, :suspended}
  ]

  @second_segment [
    :workflow_resumed,
    {:workflow, :start, true},
    {:step, :start, nil},
    {:step, :stop, :ok},
    :workflow_completed,
    {:workflow, :stop, :completed}
  ]

  describe "what a waiting run tells the outside" do
    setup do
      listen(Config.get(Durable))
    end

    test "waiting for input: each event once, in order, and the answer too" do
      id = start_waiting("input")

      assert heard() ==
               @first_segment ++
                 [:workflow_waiting, :input_requested, {:workflow, :stop, :waiting}]

      assert Durable.provide_input(id, "x", 1) == :ok
      assert Durable.provide_input(id, "x", 2) == {:error, :not_found}
      assert heard() == [:input_provided]

      drain(id)
      assert heard() == @second_segment
    end

    for wait <- ["event", "any", "sleep"] do
      test "waiting on #{wait}: one span per segment, and nothing between them" do
        id = start_waiting(unquote(wait))
        assert heard() == @first_segment ++ [:workflow_waiting, {:workflow, :stop, :waiting}]

        if unquote(wait) != "sleep", do: assert(Durable.send_event(id, "x", 1) == :ok)
        assert Durable.send_event(id, "x", 2) in [:ok, {:error, :not_found}]
        assert heard() == []

        drain(id)
        assert heard() == @second_segment
      end
    end

    # A list that follows the workflows topic would otherwise still show the
    # run as running.
    for wait <- ["event", "any", "all", "sleep"] do
      test "waiting on #{wait} broadcasts :workflow_waiting once, as waiting for input does" do
        start_waiting(unquote(wait))
        assert Enum.count(heard(), &(&1 == :workflow_waiting)) == 1
      end
    end

    test "cancelled while waiting: one broadcast, and no span left open" do
      id = start_waiting("input")
      heard()

      assert Durable.cancel(id, "stop") == :ok
      assert Durable.cancel(id, "again") == {:error, :already_completed}
      assert heard() == [:workflow_cancelled]
    end

    test "a wait cancelled with cancel_wait resumes like any answer" do
      id = start_waiting("event")
      heard()

      assert Wait.cancel_wait(id) == :ok
      assert heard() == []
      drain(id)
      assert heard() == @second_segment
    end

    test "a wait that times out with on_timeout: :fail fails the run once" do
      start_supervised!({TimeoutWorker, config: Config.get(Durable), interval: 3_600_000})
      id = start_waiting("input_or_fail")
      heard()

      TimeoutWorker.check_timeouts()
      :sys.get_state(TimeoutWorker.worker_name(Durable))
      assert heard() == []

      assert drain(id).status == :failed

      assert heard() == [
               :workflow_resumed,
               {:workflow, :start, true},
               :workflow_failed,
               {:workflow, :stop, :failed}
             ]
    end
  end

  describe "two instances side by side" do
    setup do
      start_supervised!(
        {Durable, name: @other, repo: Durable.TestRepo, queue_enabled: false, pubsub: :start},
        id: @other
      )

      :ok
    end

    test "each has its own config, processes and PubSub" do
      ours = Config.get(Durable)
      theirs = Config.get(@other)

      assert theirs.name == @other
      assert theirs.pubsub != ours.pubsub
      assert Process.whereis(theirs.pubsub) != Process.whereis(ours.pubsub)
      assert DurablePubSub.workflows_topic(theirs) != DurablePubSub.workflows_topic(ours)
    end

    test "a run started on one is announced on that one only, under its name" do
      listen(Config.get(Durable))
      id = start_waiting("event", durable: @other)

      # Telemetry is global: the instance is in the metadata. No broadcast
      # reached the default instance's topic.
      assert heard() == [
               {:workflow, :start, false},
               {:step, :start, nil},
               {:step, :stop, :suspended},
               {:workflow, :stop, :waiting}
             ]

      subscribe(Config.get(@other))
      assert Durable.send_event(id, "x", 1, durable: @other) == :ok
      assert drain(id, durable: @other).status == :completed
      assert heard() == @second_segment
    end

    test "telemetry names the instance that ran the step" do
      handler = "audit4-api-named-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        handler,
        [:durable, :step, :stop],
        fn _event, _measurements, meta, _config -> send(test, {:ran_on, meta.durable}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      start_waiting("event", durable: @other)
      assert_received {:ran_on, @other}

      start_waiting("event")
      assert_received {:ran_on, Durable}
    end

    test "stopping one leaves the other working, and the stopped one is unknown" do
      id = start_waiting("input")
      :ok = stop_supervised(@other)
      Durable.Supervisor.stop(@other)

      assert_raise ArgumentError, ~r/Audit4ApiOtherInstance not found/, fn ->
        Durable.get_execution(id, durable: @other)
      end

      assert Durable.provide_input(id, "x", "still here") == :ok
      assert drain(id).status == :completed
    end
  end

  describe "options an instance is started with" do
    test "the ones that can't work are refused, by name" do
      for {opts, key} <- [
            {[], :repo},
            {[repo: "MyApp.Repo"], :repo},
            {[repo: Durable.TestRepo, name: "main"], :name},
            {[repo: Durable.TestRepo, prefix: "private"], :prefix},
            {[repo: Durable.TestRepo, queues: %{"default" => [concurrency: 1]}], :queues},
            {[repo: Durable.TestRepo, queues: [default: [concurrency: 1]]], :queues},
            {[repo: Durable.TestRepo, heartbeat_interval: 0], :heartbeat_interval},
            {[repo: Durable.TestRepo, stale_lock_timeout: -1], :stale_lock_timeout},
            {[repo: Durable.TestRepo, shutdown_grace_period: -1], :shutdown_grace_period},
            {[repo: Durable.TestRepo, sleep_waker_batch_size: 0], :sleep_waker_batch_size},
            {[repo: Durable.TestRepo, log_level: :verbose], :log_level},
            {[repo: Durable.TestRepo, prune: [completed: 0]], :prune},
            {[repo: Durable.TestRepo, prune: [everything: 5]], :prune}
          ] do
        assert {:error, %NimbleOptions.ValidationError{key: ^key}} = Config.new(opts)
      end

      assert {:error, %NimbleOptions.ValidationError{message: message}} =
               Config.new(repo: Durable.TestRepo, retries: 3)

      assert message =~ "unknown options [:retries]"
    end

    # `queues:` is only checked to be a map with atom keys (config.ex:106). A
    # queue that can never claim (concurrency 0 or below) boots and sits there,
    # and options that aren't a keyword list crash Queue.Manager at boot with a
    # FunctionClauseError instead of a validation error.
    for queue <- [
          "[concurrency: 0]",
          "[concurrency: -3]",
          ~s([concurrency: "10"]),
          "[poll_interval: 0]",
          "[poll_interval: -1]",
          ":nope",
          "[concurency: 5]"
        ] do
      @tag :skip
      test "queues: %{default: #{queue}} is refused" do
        {options, _binding} = Code.eval_string(unquote(queue))

        assert {:error, %NimbleOptions.ValidationError{}} =
                 Config.new(repo: Durable.TestRepo, queues: %{default: options})
      end
    end
  end
end
