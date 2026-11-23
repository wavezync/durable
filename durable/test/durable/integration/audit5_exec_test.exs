defmodule Audit5ExecTokenize do
  @moduledoc false
  use Durable
  use Durable.Context
  use Durable.Helpers
  alias Durable.IntegrationProbe, as: Probe

  # The card number is swapped for a token and must not be kept past it.
  workflow "audit5_exec_tokenize" do
    step :tokenize_card, fn payment ->
      Probe.note(:tokenized)
      delete_context(:card_number)
      {:ok, payment |> delete(:card_number) |> assign(:card_token, "tok_1")}
    end

    step :charge, fn payment ->
      Probe.put(:charge_got, payment)
      {:ok, payment}
    end
  end
end

defmodule Audit5ExecUnderwrite do
  @moduledoc false
  use Durable
  use Durable.Helpers
  alias Durable.IntegrationProbe, as: Probe

  # A loan application is scored once (the bureau charges per call) and the
  # kind of decision it needs is kept with it.
  workflow "audit5_exec_underwrite" do
    step :score, fn application ->
      Probe.note(:scored)
      {:ok, application |> assign(:score, 710) |> assign(:decision_type, "automatic")}
    end

    step :notify, fn application ->
      Probe.put(:notify_got, application)
      {:ok, application}
    end
  end
end

defmodule Audit5ExecExpress do
  @moduledoc false
  use Durable
  use Durable.Helpers
  alias Durable.IntegrationProbe, as: Probe

  # An express order skips the warehouse hold.
  workflow "audit5_exec_express" do
    step :route, fn order -> {:goto, :ship, assign(order, :route, "express")} end

    step :hold, fn order ->
      Probe.note(:held)
      {:ok, order}
    end

    step :ship, fn order ->
      Probe.put(:ship_got, order)
      {:ok, order}
    end
  end
end

defmodule Durable.Integration.Audit5ExecTest do
  @moduledoc """
  Audit 5, executor: a step's result when its worker is lost at the worst
  moment.
  """
  use Durable.IntegrationCase, async: false

  @moduletag :capture_log

  def kill_once(_event, _measurements, %{step: step}, step) do
    if Probe.note(:killed) == 1, do: Process.exit(self(), :kill)
  end

  def kill_once(_event, _measurements, _meta, _step), do: :ok

  defp kill_at!(event, step) do
    handler = "audit5-exec-kill-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, event, &__MODULE__.kill_once/4, step)
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "a step that takes a key out of its data and the context doesn't hand it on" do
    start_durable!(%{default: 1})

    {:ok, id} = Durable.start(Audit5ExecTokenize, %{"order_id" => "o-1", "card_number" => "4242"})
    run = await_status(id, :completed)

    assert %{"card_token" => "tok_1"} = Probe.fetch(:charge_got)
    refute Map.has_key?(Probe.fetch(:charge_got), "card_number")
    refute Map.has_key?(run.context, "card_number")
  end

  describe "a task killed after its step's row was written, before the run saved it" do
    test "doesn't run a step again whose data has a key called decision_type" do
      kill_at!([:durable, :step, :stop], :score)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit5ExecUnderwrite, %{"applicant" => "ada"})
      await_status(id, :completed)

      assert Probe.hits(:killed) == 1
      assert Probe.hits(:scored) == 1
      assert %{"score" => 710, "decision_type" => "automatic"} = Probe.fetch(:notify_got)
    end

    test "still makes the jump a step that jumped asked for" do
      kill_at!([:durable, :step, :stop], :route)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit5ExecExpress, %{"order_id" => "o-9"})
      await_status(id, :completed)

      assert Probe.hits(:held) == 0
      assert Probe.fetch(:ship_got) == %{"order_id" => "o-9", "route" => "express"}
    end

    # Open: the row holds what the step returned and what it put in the
    # context, not what it deleted from it, so the run that takes the result
    # from the row (`finished_before_lost/5`) puts the card number back.
    @tag :skip
    test "doesn't hand the next step a key the step took out of its data" do
      kill_at!([:durable, :step, :stop], :tokenize_card)
      start_durable!(%{default: 1})

      {:ok, id} =
        Durable.start(Audit5ExecTokenize, %{"order_id" => "o-1", "card_number" => "4242"})

      run = await_status(id, :completed)

      assert Probe.hits(:killed) == 1
      assert Probe.hits(:tokenized) == 1
      assert %{"card_token" => "tok_1"} = Probe.fetch(:charge_got)
      refute Map.has_key?(Probe.fetch(:charge_got), "card_number")
      refute Map.has_key?(run.context, "card_number")
    end
  end
end
