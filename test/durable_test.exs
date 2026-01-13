defmodule DurableTest do
  use ExUnit.Case

  describe "DSL" do
    test "workflow module compiles with use Durable" do
      defmodule TestWorkflow do
        use Durable
        use Durable.Helpers

        workflow "test_workflow" do
          step(:first, fn data ->
            {:ok, assign(data, :value, 1)}
          end)

          step(:second, fn data ->
            value = data[:value]
            {:ok, assign(data, :result, value + 1)}
          end)
        end
      end

      assert TestWorkflow.__workflows__() == ["test_workflow"]
      assert {:ok, definition} = TestWorkflow.__workflow_definition__("test_workflow")
      assert definition.name == "test_workflow"
      assert length(definition.steps) == 2
    end

    test "step with options compiles correctly" do
      defmodule RetryWorkflow do
        use Durable

        workflow "retry_test" do
          step(:with_retry, [retry: [max_attempts: 3, backoff: :exponential]], fn _data ->
            {:ok, :ok}
          end)
        end
      end

      {:ok, definition} = RetryWorkflow.__workflow_definition__("retry_test")
      [step] = definition.steps

      assert step.name == :with_retry
      assert step.opts[:retry][:max_attempts] == 3
      assert step.opts[:retry][:backoff] == :exponential
    end

    test "time helpers expand correctly" do
      import Durable.DSL.TimeHelpers

      assert seconds(30) == 30_000
      assert minutes(5) == 300_000
      assert hours(2) == 7_200_000
      assert days(1) == 86_400_000
    end
  end

  describe "Context" do
    test "context operations work" do
      # Initialize context
      Durable.Context.init_context(%{input_key: "value"}, "test-workflow-id")

      # Test input
      assert Durable.Context.input() == %{input_key: "value"}
      assert Durable.Context.workflow_id() == "test-workflow-id"

      # Test put/get
      Durable.Context.put_context(:key1, "value1")
      assert Durable.Context.get_context(:key1) == "value1"
      assert Durable.Context.get_context(:missing, "default") == "default"

      # Test update
      Durable.Context.put_context(:counter, 0)
      Durable.Context.update_context(:counter, &(&1 + 1))
      assert Durable.Context.get_context(:counter) == 1

      # Test has_context?
      assert Durable.Context.has_context?(:key1)
      refute Durable.Context.has_context?(:nonexistent)

      # Test delete
      Durable.Context.delete_context(:key1)
      refute Durable.Context.has_context?(:key1)

      # Test append
      Durable.Context.put_context(:list, [1])
      Durable.Context.append_context(:list, 2)
      assert Durable.Context.get_context(:list) == [1, 2]

      # Test increment
      Durable.Context.put_context(:num, 5)
      Durable.Context.increment_context(:num, 3)
      assert Durable.Context.get_context(:num) == 8

      # Cleanup
      Durable.Context.cleanup()
    end
  end

  describe "Backoff" do
    alias Durable.Executor.Backoff

    test "exponential backoff calculates correctly" do
      assert Backoff.calculate(:exponential, 1, %{base: 1000}) == 2000
      assert Backoff.calculate(:exponential, 2, %{base: 1000}) == 4000
      assert Backoff.calculate(:exponential, 3, %{base: 1000}) == 8000
    end

    test "linear backoff calculates correctly" do
      assert Backoff.calculate(:linear, 1, %{base: 1000}) == 1000
      assert Backoff.calculate(:linear, 2, %{base: 1000}) == 2000
      assert Backoff.calculate(:linear, 3, %{base: 1000}) == 3000
    end

    test "constant backoff returns same value" do
      assert Backoff.calculate(:constant, 1, %{base: 1000}) == 1000
      assert Backoff.calculate(:constant, 5, %{base: 1000}) == 1000
      assert Backoff.calculate(:constant, 10, %{base: 1000}) == 1000
    end

    test "backoff respects max_backoff" do
      assert Backoff.calculate(:exponential, 20, %{base: 1000, max_backoff: 5000}) == 5000
    end

    test "handles attempt 0 edge case" do
      # Attempt 0: exponential = 2^0 * base = base, linear = 0 * base = 0
      assert Backoff.calculate(:exponential, 0, %{base: 1000}) == 1000
      assert Backoff.calculate(:linear, 0, %{base: 1000}) == 0
      assert Backoff.calculate(:constant, 0, %{base: 1000}) == 1000
    end
  end
end
