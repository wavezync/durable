defmodule Durable.FuzzBlocks do
  @moduledoc false
  # An order whose lanes, nested block, child workflow and `into:` block are
  # driven by a script, for the blocks chaos fuzz (audit 6). In test/support so
  # a second node has the code.

  alias Durable.FuzzWorkflows, as: F
  alias Durable.IntegrationProbe, as: Probe

  # The kid a lane calls: a label printed in two steps.
  defmodule Kid do
    @moduledoc false
    use Durable

    alias Durable.FuzzBlocks, as: B

    workflow "fuzz_blocks_kid" do
      step :k1, fn d -> B.act(:k1, d) end
      step :k2, fn d -> B.act(:k2, d) end
    end
  end

  defmodule Body do
    @moduledoc false
    alias Durable.FuzzBlocks, as: B
    alias Durable.FuzzWorkflows, as: F

    # The same order for a workflow that rolls back and one that halts.
    defmacro steps do
      quote do
        step :first, [compensate: :undo_first], fn d -> B.act(:first, d) end

        parallel :fan do
          lane :one do
            step :o1, [retry: [max_attempts: 3, backoff: :constant, base: 1]], fn d ->
              B.act(:o1, d)
            end

            branch :pick, fn d -> F.named_decide(:pick, d) end do
              :m ->
                step :m1, fn d -> B.act(:m1, d) end

              :n ->
                step :n1, [queue: :q_a], fn d -> B.act(:n1, d) end
            end

            step :o2, fn d -> B.act(:o2, d) end
          end

          lane :two do
            step :t1, [queue: :q_b], fn d -> B.act(:t1, d) end
            step :t2, fn d -> B.call_kid(:t2, d) end
          end

          lane :three do
            parallel :deep do
              step :d1, [retry: [max_attempts: 3, backoff: :constant, base: 1]], fn d ->
                B.act(:d1, d)
              end

              lane :db do
                step :d2, fn d -> B.act(:d2, d) end
                step :d3, fn d -> B.act(:d3, d) end
              end
            end

            step :t3, fn d -> F.named_join(:t3, :deep, [:d1, :db], d) end
          end
        end

        step :charge,
             [compensate: :undo_charge, retry: [max_attempts: 3, backoff: :constant, base: 1]],
             fn d ->
               B.slow(:charge, d)
               F.named_join(:charge, :fan, [:one, :two, :three], d)
             end

        parallel :checks, into: fn d, lanes -> B.into(d, lanes) end do
          step :x1, fn d -> B.act(:x1, d) end
          step :x2, [queue: :q_a], fn d -> B.act(:x2, d) end
        end

        step :last, fn d -> B.act(:last, d) end

        compensate :undo_first, fn d -> B.undo(:first, d) end
        compensate :undo_charge, fn d -> B.undo(:charge, d) end
      end
    end
  end

  defmodule Order do
    @moduledoc false
    use Durable

    require Durable.FuzzBlocks.Body, as: Body

    workflow "fuzz_blocks_order", on_failure: :rollback do
      Body.steps()
    end

    workflow "fuzz_blocks_order_halt" do
      Body.steps()
    end
  end

  @doc "A step: waits its script's while, then does what the script says."
  def act(step, data) do
    slow(step, data)
    F.named(step, data)
  end

  # A window for an operator or a kill to land in the middle of the step.
  def slow(step, data) do
    case Probe.fetch(F.case_of(data)).slow[step] do
      nil -> :ok
      ms -> Process.sleep(ms)
    end
  end

  def call_kid(step, data) do
    case Durable.Orchestration.call_workflow(Kid, %{"case" => F.case_of(data)}, ref: :kid) do
      {:ok, _label} -> act(step, data)
      {:error, _reason} -> {:fail, "the kid didn't finish"}
    end
  end

  # Goes on only if every check passed, noting what it was handed.
  def into(data, lanes) do
    Probe.note({F.case_of(data), :into})

    handed = Map.new(lanes, fn {lane, {how, _}} -> {lane, how} end)

    if handed == %{"x1" => :ok, "x2" => :ok},
      do: {:ok, Map.put(data, "checked", true)},
      else: {:error, "a check failed: #{inspect(handed)}"}
  end

  def undo(step, data) do
    Probe.note({F.case_of(data), :undo, step})
    {:ok, data}
  end
end
