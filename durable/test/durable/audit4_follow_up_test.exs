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

    # A step writes atoms, at depth and as values. Every step after it reads
    # the same string-keyed data, however the run got to it.
    workflow "audit4_fu_string_keys" do
      step :load_user, fn data ->
        profile = %{plan: :pro, limits: %{seats: 3, ratio: 1.0}, tags: [%{name: :vip}]}
        {:ok, Map.put(data, :profile, profile)}
      end

      step :same_pass, fn data ->
        Seen.put(:same_pass, data)
        {:ok, data}
      end

      parallel :lookups do
        step :plan, fn data ->
          Seen.put(:lane_plan, data)
          {:ok, %{name: "pro"}}
        end

        step :region, fn data ->
          Seen.put(:lane_region, data)
          {:ok, %{name: "eu"}}
        end
      end

      step :send_welcome, [retry: [max_attempts: 2, base: 0]], fn data ->
        if Seen.get(:welcome_tried) == :nothing do
          Seen.put(:welcome_tried, data)
          {:error, "mail server busy"}
        else
          Seen.put(:welcome_retried, data)
          {:ok, data}
        end
      end

      step :await_confirmation, fn data ->
        wait_for_event("email_confirmed")
        {:ok, data}
      end

      step :after_reload, fn data ->
        Seen.put(:after_reload, data)
        {:ok, data}
      end
    end

    # What a step returns that JSON has no word for.
    workflow "audit4_fu_values" do
      step :write, fn data ->
        {:ok,
         Map.merge(data, %{
           status: :approved,
           pair: {:ok, 1},
           at: ~U[2026-11-23 10:00:00Z],
           range: 1..3
         })}
      end

      step :same_pass, fn data ->
        Seen.put(:values_same_pass, data)
        {:ok, data}
      end

      step :await_confirmation, fn data ->
        wait_for_event("email_confirmed")
        {:ok, data}
      end

      step :after_reload, fn data ->
        Seen.put(:values_after_reload, Map.delete(data, "email_confirmed"))
        {:ok, data}
      end
    end

    # A step writes an atom over a key the data already has as a string.
    workflow "audit4_fu_overwrite" do
      step :reprice, fn order -> {:ok, Map.put(order, :total, 99)} end

      step :charge, fn order ->
        Seen.put(:charged, order)
        {:ok, order}
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

      branch on: fn doc -> doc["kind"] end do
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

  describe "a step's data" do
    test "has string keys at every depth, the same in every step however the run got there" do
      run = run_workflow(Signup, %{"user_id" => "u-7"}, workflow: "audit4_fu_string_keys")
      run = drain(run)
      assert run.status == :waiting, inspect(run.error)

      :ok = Durable.send_event(run.id, "email_confirmed", %{})
      assert drain(run).status == :completed

      written = %{
        "user_id" => "u-7",
        "profile" => %{
          "plan" => "pro",
          "limits" => %{"seats" => 3, "ratio" => 1.0},
          "tags" => [%{"name" => "vip"}]
        }
      }

      joined =
        Map.put(written, "lookups", %{
          "plan" => %{"name" => "pro"},
          "region" => %{"name" => "eu"}
        })

      # `===`: a float stays a float.
      for seen <- [:same_pass, :lane_plan, :lane_region] do
        assert {seen, Seen.get(seen)} === {seen, written}
      end

      for seen <- [:welcome_tried, :welcome_retried] do
        assert {seen, Seen.get(seen)} === {seen, joined}
      end

      # The event's answer is in the data under its name.
      assert Seen.get(:after_reload) === Map.put(joined, "email_confirmed", %{})
    end
  end

  describe "a value a step returns" do
    test "is read as it is stored, the same in the next step and after a reload" do
      run = run_workflow(Signup, %{}, workflow: "audit4_fu_values")
      assert run.status == :waiting, inspect(run.error)

      :ok = Durable.send_event(run.id, "email_confirmed", %{})
      assert drain(run).status == :completed

      assert %{
               "status" => "approved",
               "pair" => ["ok", 1],
               "at" => "2026-11-23T10:00:00Z",
               "range" => %{"first" => 1, "last" => 3, "step" => 1}
             } = Seen.get(:values_same_pass)

      assert Seen.get(:values_after_reload) === Seen.get(:values_same_pass)
    end
  end

  describe "a key written as an atom over the stored string" do
    test "is stored once, with what the step wrote" do
      run = run_workflow(Signup, %{"total" => 12}, workflow: "audit4_fu_overwrite")
      assert run.status == :completed
      assert Seen.get(:charged) == %{"total" => 99}
      assert run.context == %{"total" => 99}
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
