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

defmodule Audit5ExecVault do
  @moduledoc false
  use Durable
  use Durable.Context
  alias Durable.IntegrationProbe, as: Probe

  # The card goes to the vault and only its token is returned. What the step
  # leaves of the payment is what it did to the context.
  workflow "audit5_exec_vault" do
    step :vault_card, fn _payment ->
      Probe.note(:vaulted)
      # Taken out for good.
      delete_context(:card_number)
      # Taken out and put back: as it was, and changed.
      delete_context(:order_id)
      put_context(:order_id, "o-1")
      delete_context(:currency)
      put_context(:currency, "EUR")
      # A key inside another.
      update_context(:card, &Map.delete(&1, "cvc"))
      # Taken out of the context, and returned.
      delete_context(:amount)
      {:ok, %{"card_token" => "tok_1", "amount" => 1200}}
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

    # The row held what the step returned and what it put in the context, not
    # what it deleted from it, so the run that took the result from the row
    # (`finished_before_lost/5`) put the card number back.
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

    test "keeps the keys it deleted off the step's output" do
      kill_at!([:durable, :step, :stop], :tokenize_card)
      start_durable!(%{default: 1})

      {:ok, id} =
        Durable.start(Audit5ExecTokenize, %{"order_id" => "o-1", "card_number" => "4242"})

      await_status(id, :completed)

      {:ok, run} = Durable.get_execution(id, include_steps: true)
      tokenized = Enum.find(run.steps, &(&1.step_name == "tokenize_card"))
      assert tokenized.output == %{"order_id" => "o-1", "card_token" => "tok_1"}
    end
  end

  describe "a step that deletes from the context" do
    @payment %{
      "order_id" => "o-1",
      "currency" => "USD",
      "amount" => 1200,
      "card_number" => "4242424242424242",
      "card" => %{"last4" => "4242", "cvc" => "123"}
    }

    @left %{
      "order_id" => "o-1",
      "currency" => "EUR",
      "amount" => 1200,
      "card" => %{"last4" => "4242"},
      "card_token" => "tok_1"
    }

    test "leaves the next step what its body left" do
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit5ExecVault, @payment)
      run = await_status(id, :completed)

      assert Probe.fetch(:charge_got) == @left
      assert run.context == @left
      assert dropped_markers(run) == []
    end

    test "leaves the same when its task is killed after its row was written" do
      kill_at!([:durable, :step, :stop], :vault_card)
      start_durable!(%{default: 1})

      {:ok, id} = Durable.start(Audit5ExecVault, @payment)
      run = await_status(id, :completed)

      assert Probe.hits(:killed) == 1
      assert Probe.hits(:vaulted) == 1
      assert Probe.fetch(:charge_got) == @left
      assert run.context == @left
      assert dropped_markers(run) == []
    end
  end

  # What the engine keeps of an attempt's deleted keys until the run saves.
  defp dropped_markers(run),
    do: Enum.filter(Map.keys(run.engine_state), &String.starts_with?(&1, "__dropped:"))
end
