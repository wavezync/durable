defmodule DurableDashboard.NamedBlocksWorkflow do
  @moduledoc """
  Named branches and lanes, nested in each other, for the graph tests: an
  empty arm, two arms holding a step of the same name, a branch inside an arm,
  a lane that ends on a branch and a parallel block inside a lane.
  """
  use Durable

  workflow "named_blocks" do
    step :first, fn d -> {:ok, d} end

    branch :risk, fn d -> {:clear, d} end do
      :clear ->
        pass()

      :review ->
        step :ask, fn d -> {:ok, d} end

        branch :inner, fn d -> {:x, d} end do
          :x -> step :x1, fn d -> {:ok, d} end
          :y -> pass()
        end

      :blocked ->
        step :ask, fn d -> {:ok, d} end
    end

    parallel :fulfil do
      lane :ship do
        step :pack, fn d -> {:ok, d} end

        branch :where, fn d -> {:home, d} end do
          :home -> step :courier, fn d -> {:ok, d} end
          :abroad -> step :freight, fn d -> {:ok, d} end
        end
      end

      lane :papers do
        parallel :docs do
          step :invoice, fn d -> {:ok, d} end
          step :receipt, fn d -> {:ok, d} end
        end

        step :file, fn d -> {:ok, d} end
      end

      step :points, fn d -> {:ok, d} end
    end

    step :close, fn d -> {:ok, d} end
  end

  # A block that collects, with a lane that ends on a block of its own.
  workflow "lookups" do
    parallel :lookups, on_error: :collect do
      step :credit, fn d -> {:ok, d} end

      lane :sanctions do
        step :query, fn d -> {:ok, d} end

        parallel :lists do
          step :eu, fn d -> {:ok, d} end
          step :un, fn d -> {:ok, d} end
        end
      end
    end

    step :decide, fn d -> {:ok, d} end
  end

  # A block that fails fast, with a lane it can do without.
  workflow "enrich" do
    parallel :lookups do
      step :credit, fn d -> {:ok, d} end
      step :device, [optional: true], fn d -> {:ok, d} end
    end

    step :decide, fn d -> {:ok, d} end
  end
end
