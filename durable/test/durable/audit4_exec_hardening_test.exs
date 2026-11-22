defmodule Durable.Audit4ExecHardeningTest do
  @moduledoc """
  Audit 4, executor: what held up. Keys against every way a run ends, jumps
  out of an arm, an operator retrying a lane's own run, a cancel reaching three
  workflows down, and what an undo is handed.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  alias Durable.Storage.Schemas.{PendingInput, WorkflowExecution}
  alias Durable.TestRepo, as: Repo

  @moduletag :capture_log

  defmodule Audit4ExecSeen do
    @moduledoc false
    def note(event), do: :persistent_term.put(__MODULE__, all() ++ [event])
    def all, do: :persistent_term.get(__MODULE__, [])
    def clear, do: :persistent_term.erase(__MODULE__)
  end

  defmodule Audit4ExecLoan do
    @moduledoc false
    use Durable
    use Durable.Wait

    def reserve(loan), do: {:ok, Map.put(loan, "id", "L-7")}

    # What the applicant's file says happens at the bank.
    def pay_out(loan) do
      case loan["bank"] do
        "refuses" ->
          {:fail, "the bank refused the transfer"}

        "asks" ->
          wait_for_input("bank_approval")
          {:ok, loan}

        _pays ->
          {:ok, loan}
      end
    end

    def release(loan) do
      Audit4ExecSeen.note({:released, loan["id"]})
      if loan["ledger"] == "down", do: {:error, "the ledger is down"}, else: {:ok, loan}
    end

    # One loan per applicant, by key. The three differ only in when the key is free.
    workflow "audit4_loan_after_close", reuse: :after_close do
      step(:reserve_funds, [compensate: :release_funds], fn loan ->
        Audit4ExecLoan.reserve(loan)
      end)

      step(:pay_out, fn loan -> Audit4ExecLoan.pay_out(loan) end)
      compensate(:release_funds, fn loan -> Audit4ExecLoan.release(loan) end)
    end

    workflow "audit4_loan_after_failure", reuse: :after_failure do
      step(:reserve_funds, [compensate: :release_funds], fn loan ->
        Audit4ExecLoan.reserve(loan)
      end)

      step(:pay_out, fn loan -> Audit4ExecLoan.pay_out(loan) end)
      compensate(:release_funds, fn loan -> Audit4ExecLoan.release(loan) end)
    end

    workflow "audit4_loan_never", reuse: :never do
      step(:reserve_funds, [compensate: :release_funds], fn loan ->
        Audit4ExecLoan.reserve(loan)
      end)

      step(:pay_out, fn loan -> Audit4ExecLoan.pay_out(loan) end)
      compensate(:release_funds, fn loan -> Audit4ExecLoan.release(loan) end)
    end

    workflow "audit4_loan_rolls_back", on_failure: :rollback do
      step(:reserve_funds, [compensate: :release_funds], fn loan ->
        Audit4ExecLoan.reserve(loan)
      end)

      step(:pay_out, fn loan -> Audit4ExecLoan.pay_out(loan) end)
      compensate(:release_funds, fn loan -> Audit4ExecLoan.release(loan) end)
    end
  end

  defmodule Audit4ExecClaim do
    @moduledoc false
    use Durable
    use Durable.Helpers

    workflow "audit4_claim_jumps" do
      branch :risk, fn claim -> {:review, claim} end do
        :review ->
          step(:ask_assessor, fn claim ->
            {:goto, String.to_existing_atom(claim["then"]), assign(claim, :asked, true)}
          end)

          step(:record_answer, fn claim -> {:ok, assign(claim, :recorded, true)} end)

        :blocked ->
          step(:refuse, fn claim -> {:ok, assign(claim, :refused, true)} end)
      end

      step(:close, fn claim -> {:ok, assign(claim, :closed, true)} end)
    end

    # Two lookups side by side. The credit bureau is down until it's fixed.
    workflow "audit4_claim_lookups" do
      parallel :lookups do
        lane :credit do
          step(:query, fn claim ->
            if :bureau_back in Audit4ExecSeen.all(),
              do: {:ok, assign(claim, :score, 710)},
              else: {:fail, "the bureau is down"}
          end)
        end

        lane :fraud do
          step(:query, fn claim ->
            Audit4ExecSeen.note(:fraud_queried)
            {:ok, assign(claim, :fraud, 0.02)}
          end)
        end
      end

      step(:decide, fn claim -> {:ok, assign(claim, :decided, true)} end)
    end
  end

  defmodule Audit4ExecSignature do
    @moduledoc false
    use Durable
    use Durable.Wait

    workflow "audit4_signature" do
      step(:await_signature, fn contract ->
        wait_for_input("signature")
        {:ok, contract}
      end)
    end
  end

  defmodule Audit4ExecContract do
    @moduledoc false
    use Durable
    use Durable.Orchestration

    workflow "audit4_contract" do
      step(:sign, fn contract ->
        with {:ok, _signed} <- call_workflow(Audit4ExecSignature, %{}), do: {:ok, contract}
      end)
    end
  end

  defmodule Audit4ExecSale do
    @moduledoc false
    use Durable
    use Durable.Orchestration

    workflow "audit4_sale" do
      step(:hold_car, [compensate: :release_car], fn sale -> {:ok, sale} end)

      step(:contract, fn sale ->
        with {:ok, _contract} <- call_workflow(Audit4ExecContract, %{}), do: {:ok, sale}
      end)

      compensate(:release_car, fn sale ->
        Audit4ExecSeen.note(:car_released)
        {:ok, sale}
      end)
    end
  end

  setup do
    Audit4ExecSeen.clear()
    on_exit(&Audit4ExecSeen.clear/0)
  end

  defp reload(%{id: id}), do: Repo.get!(WorkflowExecution, id)

  defp tree(ids) do
    more =
      Repo.all(
        from(w in WorkflowExecution,
          where: w.parent_workflow_id in ^ids and w.id not in ^ids,
          select: w.id
        )
      )

    if more == [], do: ids, else: tree(ids ++ more)
  end

  defp under(run) do
    ids = tree([run.id]) -- [run.id]
    Repo.all(from(w in WorkflowExecution, where: w.id in ^ids, order_by: w.inserted_at))
  end

  # ===========================================================================
  # Keys against every way a run ends
  # ===========================================================================

  defp apply_for(key, input, reuse, opts \\ []) do
    Durable.start(
      Audit4ExecLoan,
      input,
      [workflow: "audit4_loan_#{reuse}", key: key, return: :details] ++ opts
    )
  end

  # A run with the key that ended `status`.
  defp ended(:completed, key, reuse), do: loan(key, %{}, reuse)
  defp ended(:failed, key, reuse), do: loan(key, %{"bank" => "refuses"}, reuse)

  defp ended(:cancelled, key, reuse) do
    run = loan(key, %{"bank" => "asks"}, reuse)
    :ok = Durable.cancel(run.id, "the applicant withdrew")
    reload(run)
  end

  defp ended(:compensated, key, reuse), do: rolled_back(key, %{"bank" => "refuses"}, reuse)

  defp ended(:compensation_failed, key, reuse),
    do: rolled_back(key, %{"bank" => "refuses", "ledger" => "down"}, reuse)

  defp loan(key, input, reuse) do
    {:ok, %{id: id, created: true}} = apply_for(key, input, reuse)
    drain(id)
  end

  defp rolled_back(key, input, reuse) do
    run = loan(key, input, reuse)
    {:ok, _} = Durable.rollback(run.id)
    drain(run)
  end

  @frees %{
    after_close: [:completed, :failed, :cancelled, :compensated, :compensation_failed],
    after_failure: [:failed, :cancelled, :compensated, :compensation_failed],
    never: []
  }

  for {reuse, frees} <- @frees,
      status <- [:completed, :failed, :cancelled, :compensated, :compensation_failed] do
    if status in frees do
      test "reuse: #{reuse}: a start takes the key from a run that ended #{status}" do
        key = "applicant-#{System.unique_integer([:positive])}"
        old = ended(unquote(status), key, unquote(reuse))
        assert old.status == unquote(status)

        assert {:ok, %{id: new, created: true}} =
                 apply_for(key, %{"bank" => "asks"}, unquote(reuse))

        assert new != old.id
        assert %{holds_key: true, status: :pending} = Repo.get!(WorkflowExecution, new)
        refute reload(old).holds_key

        # The key has moved on, so the old run can't be reopened beside the new one.
        if unquote(status) == :failed do
          assert Durable.retry(old.id) == {:error, {:key_taken, new}}
          assert reload(old).status == :failed
        end

        assert Durable.rerun(old.id) == {:error, {:key_taken, new}}
      end
    else
      test "reuse: #{reuse}: a run that ended #{status} keeps its key" do
        key = "applicant-#{System.unique_integer([:positive])}"
        old = ended(unquote(status), key, unquote(reuse))
        assert %{status: unquote(status), holds_key: true} = old
        id = old.id

        assert {:ok, %{id: ^id, created: false}} = apply_for(key, %{}, unquote(reuse))

        assert {:error, {:key_taken, ^id}} =
                 apply_for(key, %{}, unquote(reuse), on_duplicate: :error)

        # Only an open holder can be replaced.
        assert {:error, {:key_taken, ^id}} =
                 apply_for(key, %{}, unquote(reuse), on_duplicate: :cancel_existing)

        assert Durable.rerun(id) == {:error, {:key_taken, id}}
        assert %{status: unquote(status), holds_key: true} = reload(old)
      end
    end
  end

  test "a released key is free under reuse: :never, and its old run can take it back by a retry" do
    key = "applicant-#{System.unique_integer([:positive])}"
    old = ended(:failed, key, :never)
    assert :ok = Durable.release_key(old.id)

    assert {:ok, %{id: new, created: true}} = apply_for(key, %{}, :never)
    assert drain(new).status == :completed

    # The new holder completed, and under :never it keeps the key for good.
    assert Durable.retry(old.id) == {:error, {:key_taken, new}}
    assert reload(old).status == :failed
  end

  # ===========================================================================
  # Jumps
  # ===========================================================================

  describe "a step inside an arm that jumps" do
    defp claim(then),
      do: run_workflow(Audit4ExecClaim, %{"then" => then}, workflow: "audit4_claim_jumps")

    test "can skip the rest of its arm" do
      run = claim("close")

      assert run.status == :completed
      assert %{"asked" => true, "closed" => true} = run.context
      refute run.context["recorded"]
      refute run.context["refused"]
    end

    test "can go on to a later step of its own arm" do
      run = claim("risk__review__record_answer")

      assert run.status == :completed
      assert %{"asked" => true, "recorded" => true, "closed" => true} = run.context
      refute run.context["refused"]
    end

    test "can't land in another arm" do
      run = claim("risk__blocked__refuse")

      assert %{status: :failed, error: %{"type" => "decision_error"}} = run
      assert run.error["message"] =~ "not found in remaining steps"
    end

    test "can't go back to its own decider" do
      run = claim("risk")

      assert %{status: :failed, error: %{"type" => "decision_error"}} = run
      assert run.error["message"] =~ "Cannot jump backwards"
    end
  end

  # ===========================================================================
  # An operator on a lane's own run
  # ===========================================================================

  test "a failed lane retried by its own id finishes, and the block's retry then needs no lane again" do
    run = run_workflow(Audit4ExecClaim, %{}, workflow: "audit4_claim_lookups")
    assert run.status == :failed

    [credit] = Enum.filter(under(run), &(&1.status == :failed))
    Audit4ExecSeen.note(:bureau_back)

    assert {:ok, _} = Durable.retry(credit.id)
    assert drain(credit.id).status == :completed
    # The block already failed: a lane finishing late doesn't reopen it.
    assert reload(run).status == :failed

    assert {:ok, _} = Durable.retry(run.id)
    run = drain(run)

    assert run.status == :completed

    assert %{"credit" => %{"score" => 710}, "fraud" => %{"fraud" => 0.02}} =
             run.context["lookups"]

    assert run.context["decided"]
    assert Enum.count(Audit4ExecSeen.all(), &(&1 == :fraud_queried)) == 1
  end

  # ===========================================================================
  # A cancel three workflows down
  # ===========================================================================

  describe "a run cancelled while a child of its child waits" do
    defp sale do
      run = run_workflow(Audit4ExecSale, %{})
      assert run.status == :waiting
      assert [%{status: :waiting}, %{status: :waiting}] = under(run)
      run
    end

    defp open_inputs(run) do
      Repo.all(
        from(p in PendingInput, where: p.workflow_id in ^tree([run.id]) and p.status == :pending)
      )
    end

    test "stops every run under it and closes the input the last one asked for" do
      run = sale()
      assert [_signature] = open_inputs(run)

      :ok = Durable.cancel(run.id, "the buyer walked away")

      assert reload(run).status == :cancelled
      assert Enum.map(under(run), & &1.status) == [:cancelled, :cancelled]
      assert open_inputs(run) == []
      assert Audit4ExecSeen.all() == []
    end

    test "with rollback: true undoes its own steps once the runs under it have stopped" do
      run = sale()
      :ok = Durable.cancel(run.id, "the buyer walked away", rollback: true)

      # The runs under it stopped a moment ago, so the undo is queued, not run.
      queued = reload(run)
      assert queued.status == :pending
      assert Audit4ExecSeen.all() == []

      run = drain(run)

      assert run.status == :compensated
      assert run.error["message"] == "the buyer walked away"
      assert Enum.map(under(run), & &1.status) == [:cancelled, :cancelled]
      assert Audit4ExecSeen.all() == [:car_released]
      assert Durable.retry(run.id) == {:error, :rolled_back}
    end
  end

  # ===========================================================================
  # What an undo is handed
  # ===========================================================================

  describe "an undo is handed the run's data with the keys its steps used" do
    test "when the run rolls back as a step fails" do
      run =
        run_workflow(Audit4ExecLoan, %{"bank" => "refuses"}, workflow: "audit4_loan_rolls_back")

      assert run.status == :compensated
      assert Audit4ExecSeen.all() == [{:released, "L-7"}]
    end

    test "when a failed run is rolled back by hand, on another claim" do
      run =
        run_workflow(Audit4ExecLoan, %{"bank" => "refuses"}, workflow: "audit4_loan_after_close")

      assert run.status == :failed
      assert Audit4ExecSeen.all() == []

      {:ok, _} = Durable.rollback(run.id)

      assert drain(run).status == :compensated
      assert Audit4ExecSeen.all() == [{:released, "L-7"}]
    end

    test "when a waiting run is cancelled with rollback: true" do
      run = run_workflow(Audit4ExecLoan, %{"bank" => "asks"}, workflow: "audit4_loan_after_close")
      assert run.status == :waiting

      :ok = Durable.cancel(run.id, "withdrawn", rollback: true)

      assert drain(run).status == :compensated
      assert Audit4ExecSeen.all() == [{:released, "L-7"}]
    end
  end
end
