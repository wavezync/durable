defmodule Durable.Audit4FollowUpTest do
  @moduledoc """
  What the 2.0 docs pass found the old docs wrong about: the code didn't do
  what they said.
  """
  use Durable.DataCase, async: false

  import Durable.Testing

  @moduletag :capture_log

  defmodule Seen do
    @moduledoc false
    def put(key, value), do: :persistent_term.put({__MODULE__, key}, value)
    def get(key), do: :persistent_term.get({__MODULE__, key}, :nothing)
  end

  defmodule Signup do
    @moduledoc false
    use Durable
    use Durable.Context
    use Durable.Wait

    workflow "audit4_fu_welcome" do
      step :greet, fn data ->
        Seen.put(:input_at_greet, input())
        {:ok, data}
      end

      step :await_confirmation, fn data ->
        wait_for_event("email_confirmed")
        {:ok, data}
      end

      step :finish, fn data ->
        Seen.put(:input_at_finish, input())
        {:ok, data}
      end
    end

    # The user's id is copied under an atom key, as the old README did.
    workflow "audit4_fu_shadow" do
      step :load_user, fn data ->
        {:ok, Map.put(data, :user_id, data["user_id"])}
      end

      step :await_confirmation, fn data ->
        wait_for_event("email_confirmed")
        {:ok, data}
      end

      step :send_welcome, fn data ->
        Seen.put(:shadowed, {data[:user_id], data["user_id"]})
        {:ok, data}
      end
    end

    # The same, read from the lanes of a block and after a step is retried.
    workflow "audit4_fu_shadow_lanes" do
      step :load_user, fn data ->
        {:ok, Map.put(data, :user_id, data["user_id"])}
      end

      parallel :lookups do
        step :plan, fn data ->
          Seen.put(:lane_plan, {data[:user_id], data["user_id"]})
          {:ok, %{name: "pro"}}
        end

        step :region, fn data ->
          Seen.put(:lane_region, {data[:user_id], data["user_id"]})
          {:ok, %{name: "eu"}}
        end
      end

      step :send_welcome, [retry: [max_attempts: 2, base: 0]], fn data ->
        seen = {data[:user_id], data["user_id"]}

        if Seen.get(:welcome_tried) == :nothing do
          Seen.put(:welcome_tried, seen)
          {:error, "mail server busy"}
        else
          Seen.put(:welcome_retried, seen)
          {:ok, data}
        end
      end
    end

    workflow "audit4_fu_second" do
      step :only, fn data -> {:ok, Map.put(data, "ran", "second")} end
    end
  end

  defmodule Paperwork do
    @moduledoc false
    use Durable
    use Durable.Helpers
    use Durable.Wait

    workflow "audit4_fu_route" do
      step :classify, fn doc -> {:ok, assign(doc, :kind, :invoice)} end

      step :await_scan, fn doc ->
        wait_for_event("scanned")
        {:ok, doc}
      end

      branch on: fn doc -> doc.kind end do
        :invoice ->
          step :book_invoice, fn doc -> {:ok, assign(doc, :routed, "invoice")} end

        _ ->
          step :file_away, fn doc -> {:ok, assign(doc, :routed, "default")} end
      end
    end

    # Two rounds of independent lookups, one straight after the other.
    workflow "audit4_fu_two_blocks" do
      parallel :sources, on_error: :collect do
        step :registry, fn _doc -> {:ok, %{found: true}} end
        step :archive, fn _doc -> {:error, "archive is closed"} end
      end

      parallel :checks do
        step :signature, fn _doc -> {:ok, %{valid: true}} end
        step :stamp, fn _doc -> {:ok, %{valid: true}} end
      end
    end
  end

  describe "input/0" do
    test "is the run's input in a step, before and after the run is reloaded" do
      run = run_workflow(Signup, %{"email" => "ada@example.com"}, workflow: "audit4_fu_welcome")
      assert run.status == :waiting
      assert Seen.get(:input_at_greet) == %{"email" => "ada@example.com"}

      :ok = Durable.send_event(run.id, "email_confirmed", %{})
      assert drain(run).status == :completed
      assert Seen.get(:input_at_finish) == %{"email" => "ada@example.com"}
    end
  end

  describe "a key given as a string and added as an atom" do
    test "is still there under both after the run is reloaded" do
      run = run_workflow(Signup, %{"user_id" => "u-7"}, workflow: "audit4_fu_shadow")
      assert run.status == :waiting

      :ok = Durable.send_event(run.id, "email_confirmed", %{})
      assert drain(run).status == :completed
      assert Seen.get(:shadowed) == {"u-7", "u-7"}
    end
  end

  describe "a key under both shapes, in a block's lanes and in a retried step" do
    test "is there under both in each" do
      run = run_workflow(Signup, %{"user_id" => "u-7"}, workflow: "audit4_fu_shadow_lanes")
      run = drain(run)
      assert run.status == :completed, inspect(run.error)

      for seen <- [:lane_plan, :lane_region, :welcome_tried, :welcome_retried] do
        assert {seen, Seen.get(seen)} == {seen, {"u-7", "u-7"}}
      end
    end
  end

  describe "branch on:" do
    test "an atom clause matches the atom a step stored, after the run is reloaded" do
      run = run_workflow(Paperwork, %{}, workflow: "audit4_fu_route")
      assert run.status == :waiting

      :ok = Durable.send_event(run.id, "scanned", %{})
      run = drain(run)
      assert run.status == :completed
      assert run.context["routed"] == "invoice"
    end
  end

  describe "two parallel blocks in a row" do
    test "the second runs when the first collects its errors" do
      run = run_workflow(Paperwork, %{}, workflow: "audit4_fu_two_blocks")
      assert run.status == :completed, inspect(run.error)
      assert %{"signature" => _, "stamp" => _} = run.context["checks"]
    end
  end

  describe "a module with several workflows" do
    test "starts the first one defined when none is named" do
      {:ok, workflow} = Signup.__default_workflow__()
      assert workflow.name == "audit4_fu_welcome"
    end
  end

  describe "a step written with a do block" do
    test "is a compile error that says how to write it" do
      error =
        assert_raise CompileError, fn ->
          Code.eval_string("""
          defmodule Durable.Audit4FollowUpTest.DoBlock do
            use Durable

            workflow "audit4_fu_do_block" do
              step :charge do
                :ok
              end
            end
          end
          """)
        end

      assert Exception.message(error) =~ "fn"
    end
  end
end
